import Foundation
import AppKit

/// Core service that reads the Fleet URL from MDM managed preferences and
/// the device token from orbit, then opens the self-service portal in a
/// browser window. Only MDM-managed machines are supported.
///
/// The WebView is kept alive when the window is closed, so reopening is instant.
/// The token is checked every 60 seconds (timer paused when the window is closed)
/// and on navigation errors, to handle hourly rotation.
final class FleetService {
    private var browserWindow: BrowserWindow?

    private let tokenFile: String

    /// Serial queue protecting mutable state (currentToken, retryCount, isSettingUp).
    private let stateQueue = DispatchQueue(label: "com.fleetdm.fleet-desktop.state")

    /// The base Fleet URL (set once during setup, never changes afterward).
    /// Access only from stateQueue.
    private var _baseURL: String?

    /// Current device token (rotates hourly). Access only from stateQueue.
    private var _currentToken: String?

    /// Guards against concurrent setup calls (e.g., rapid Dock clicks during launch).
    /// Access only from stateQueue.
    private var _isSettingUp = false

    /// Timer that periodically checks for token rotation.
    private var refreshTimer: Timer?

    /// How often (in seconds) to check for a new token.
    private static let tokenRefreshInterval: TimeInterval = 60

    /// Delay before retrying a token refresh after a navigation error.
    private static let tokenRetryDelay: TimeInterval = 5

    /// Maximum number of consecutive retry attempts on navigation error.
    private static let maxRetryAttempts = 3

    /// Current retry count for navigation-error-triggered refreshes. Access only from stateQueue.
    private var _retryCount = 0

    /// Page requested via fleet:// URL before setup completed. Consumed by setup().
    /// Access only from stateQueue.
    private var _pendingPage: String?

    /// Whether a refetch was requested via fleet://refetch before setup completed.
    /// Access only from stateQueue.
    private var _pendingRefetch = false

    /// Characters to trim from file contents (leading/trailing only).
    private static let trimCharacters = CharacterSet(charactersIn: "\n\r ")

    /// Path to the managed preferences plist (MDM-managed machines).
    private static let managedPrefsPlistPath = "/Library/Managed Preferences/com.fleetdm.fleetd.config.plist"

    init() {
        let root = ProcessInfo.processInfo.environment["ORBIT_ROOT_DIR"] ?? "/opt/orbit"
        self.tokenFile = "\(root)/identifier"
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public

    /// Called when the user wants to see the window (app launch, Dock click, etc.).
    /// On first call, creates the WebView and shows the window.
    /// On subsequent calls, just brings the existing window forward.
    func run() {
        // If already set up, just show the window
        if let browser = browserWindow, browser.isAvailable {
            DispatchQueue.main.async {
                browser.show()
            }
            return
        }

        // Prevent concurrent setup calls (thread-safe check)
        let shouldSetup: Bool = stateQueue.sync {
            guard !_isSettingUp else { return false }
            _isSettingUp = true
            return true
        }
        guard shouldSetup else { return }

        // First time — resolve config and set up
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    /// Pages that can be opened via fleet:// URLs.
    /// Unrecognized URLs simply bring the app to the foreground.
    private static let validPages: Set<String> = ["self-service", "policies", "software"]

    /// Handles an incoming fleet:// URL by navigating to the corresponding page.
    /// e.g. fleet://self-service → self-service tab, fleet://policies → policies tab.
    /// fleet://refetch triggers a device refetch and opens the app.
    /// Unrecognized URLs just bring the app to the foreground.
    func handleFleetURL(_ url: URL) {
        let host = url.host?.lowercased()

        // fleet://refetch — fire the refetch POST and bring the app forward
        if host == "refetch" {
            let hasConfig: Bool = stateQueue.sync { _baseURL != nil }
            if hasConfig {
                performRefetch()
            } else {
                stateQueue.sync { _pendingRefetch = true }
            }
            run()
            return
        }

        let page: String? = {
            guard let host = host, Self.validPages.contains(host) else { return nil }
            return host
        }()

        // If the browser is already set up, navigate (or just show) the window
        if let browser = browserWindow, browser.isAvailable {
            if let page = page, let target = deviceURL(page: page) {
                DispatchQueue.main.async {
                    browser.reload(url: target)
                    browser.show()
                }
            } else {
                DispatchQueue.main.async {
                    browser.show()
                }
            }
            return
        }

        // Not yet set up — store the requested page (if valid) and run setup
        stateQueue.sync { _pendingPage = page }
        run()
    }

    /// Sends a POST to the Fleet refetch API endpoint for this device.
    /// Runs asynchronously; failures are logged but not surfaced to the user.
    private func performRefetch() {
        let (base, token): (String?, String?) = stateQueue.sync { (_baseURL, _currentToken) }
        guard let baseURL = base,
              let tok = token,
              let encoded = tok.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/v1/fleet/device/\(encoded)/refetch") else {
            NSLog("Fleet Desktop: Unable to construct refetch URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                NSLog("Fleet Desktop: Refetch failed: %@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                NSLog("Fleet Desktop: Refetch returned HTTP %d", http.statusCode)
            }
        }.resume()
    }

    // MARK: - Private

    /// Builds a device page URL from the base URL, current token, and page name.
    /// The token is percent-encoded to handle any special characters safely.
    /// Defaults to "self-service" if no page is specified.
    private func deviceURL(page: String = "self-service") -> URL? {
        let (base, token): (String?, String?) = stateQueue.sync { (_baseURL, _currentToken) }
        guard let baseURL = base,
              let tok = token,
              let encoded = tok.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let encodedPage = page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page
        return URL(string: "\(baseURL)/device/\(encoded)/\(encodedPage)")
    }

    /// Reads config, creates the BrowserWindow, loads the URL, shows the window,
    /// and starts the refresh timer.
    private func setup() {
        guard resolveConfig() else {
            stateQueue.sync { _isSettingUp = false }
            return
        }
        let (page, shouldRefetch): (String, Bool) = stateQueue.sync {
            let p = _pendingPage ?? "self-service"
            _pendingPage = nil
            let r = _pendingRefetch
            _pendingRefetch = false
            return (p, r)
        }
        if shouldRefetch {
            performRefetch()
        }
        guard let url = deviceURL(page: page) else {
            stateQueue.sync { _isSettingUp = false }
            showError("Unable to construct self-service URL. Check Fleet configuration.")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let browser = BrowserWindow()
            self.browserWindow = browser

            browser.onNavigationError = { [weak self] in
                self?.handleNavigationError()
            }
            browser.onWindowClose = { [weak self] in
                self?.stopRefreshTimer()
            }
            browser.onWindowShow = { [weak self] in
                self?.refreshTokenIfNeeded()
                self?.startRefreshTimer()
            }

            browser.preload(url: url)
            browser.show()
            self.startRefreshTimer()
            self.stateQueue.sync { self._isSettingUp = false }
        }
    }

    /// Reads the Fleet URL and device token. Returns true if successful.
    private func resolveConfig() -> Bool {
        guard let fleetURL = readFleetURL() else {
            showError("This app is currently only supported on MDM-enabled Macs. Please contact your administrator for assistance.")
            return false
        }

        stateQueue.sync { _baseURL = fleetURL.hasSuffix("/") ? String(fleetURL.dropLast()) : fleetURL }

        guard let token = readToken() else {
            showError("Device token not found or could not be read at \(tokenFile).\nEnsure orbit is enrolled and the identifier file exists.")
            return false
        }

        stateQueue.sync { _currentToken = token }
        return true
    }

    // MARK: - Token Refresh

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tokenRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTokenIfNeeded()
        }
        timer.tolerance = 5 // Allow system to coalesce for energy efficiency
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Re-reads the token file. If the token has changed, silently reloads the browser with the new URL.
    private func refreshTokenIfNeeded() {
        guard let newToken = readToken(), let browser = browserWindow else { return }

        let changed: Bool = stateQueue.sync {
            guard newToken != _currentToken else { return false }
            _currentToken = newToken
            _retryCount = 0
            return true
        }
        guard changed else { return }
        guard let url = deviceURL() else { return }

        DispatchQueue.main.async {
            browser.reload(url: url)
        }
    }

    /// Called when the browser encounters a navigation error (e.g., expired token).
    /// Attempts to refresh the token, with retry logic if the file hasn't changed yet.
    private func handleNavigationError() {
        let oldToken: String? = stateQueue.sync { _currentToken }

        // First, try an immediate refresh
        if let newToken = readToken(), newToken != oldToken {
            stateQueue.sync {
                _currentToken = newToken
                _retryCount = 0
            }
            if let url = deviceURL(), let browser = browserWindow {
                DispatchQueue.main.async { browser.reload(url: url) }
            }
            return
        }

        // Token hasn't changed yet — retry with delay (up to maxRetryAttempts)
        let shouldRetry: Bool = stateQueue.sync {
            guard _retryCount < Self.maxRetryAttempts else {
                _retryCount = 0
                return false
            }
            _retryCount += 1
            return true
        }
        guard shouldRetry else { return }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.tokenRetryDelay) { [weak self] in
            guard let self = self else { return }
            // Re-read token; if it changed, refreshTokenIfNeeded will reload
            self.refreshTokenIfNeeded()
        }
    }

    // MARK: - File Reading

    /// Reads the Fleet URL from managed preferences (MDM).
    /// Only MDM-managed machines are supported.
    private func readFleetURL() -> String? {
        guard let plist = NSDictionary(contentsOfFile: Self.managedPrefsPlistPath),
              let url = plist["FleetURL"] as? String else {
            return nil
        }
        let trimmed = url.trimmingCharacters(in: Self.trimCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readToken() -> String? {
        return readFileTrimmed(path: tokenFile)
    }

    private func readFileTrimmed(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: Self.trimCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Error Display

    private func showError(_ message: String) {
        let work = {
            let alert = NSAlert()
            alert.messageText = BrowserWindow.windowTitle
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync { work() }
        }
    }
}
