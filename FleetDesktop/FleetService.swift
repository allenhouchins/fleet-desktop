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

    /// Timer that periodically checks for token rotation and refreshes the Dock badge.
    /// Runs for the lifetime of the service (not stopped when the window closes) so the
    /// badge keeps updating even when the app is Dock-only.
    private var refreshTimer: Timer?

    /// Activity token that prevents App Nap from throttling the refresh timer when no
    /// window is visible. Held for the lifetime of the service.
    private var activityToken: NSObjectProtocol?

    /// How often (in seconds) to check for a new token and refresh the badge.
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

    /// Set when a `fleet://` open needs the browser UI as soon as setup completes (cold launch or still starting).
    /// Access only from stateQueue.
    private var _userRequestedFleetUI = false

    /// True after setup if we intentionally skipped the first window show (login item / `open -j`).
    /// Used to present once when the user foregrounds the app. Main thread only.
    private var deferredPresentationFromHeadlessLaunch = false

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
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    // MARK: - Public

    /// Called when the user wants to see the window (app launch, Dock click, etc.).
    /// On first call, creates the WebView; the window is shown unless launch was headless
    /// (`open -j`, hidden login item) and there was no `fleet://` cold open.
    /// On subsequent calls, brings the existing window forward.
    func run() {
        // If already set up, just show the window
        if let browser = browserWindow, browser.isAvailable {
            DispatchQueue.main.async { [weak self] in
                self?.deferredPresentationFromHeadlessLaunch = false
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

    /// Reloads the current page in the browser window (e.g., Cmd+R).
    func reloadCurrentPage() {
        guard let browser = browserWindow else { return }
        DispatchQueue.main.async {
            browser.reloadCurrent()
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
        let browserReady: Bool = stateQueue.sync {
            guard let b = browserWindow else { return false }
            return b.isAvailable
        }
        if !browserReady {
            stateQueue.sync { _userRequestedFleetUI = true }
        }

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
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                NSLog("Fleet Desktop: Refetch failed: %@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                NSLog("Fleet Desktop: Refetch returned HTTP %d", http.statusCode)
                return
            }
            // Refetch succeeded — poll the badge soon to catch policy changes
            // (e.g., an app install that causes a policy to pass).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                self?.fetchDesktopData()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                self?.fetchDesktopData()
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

    /// Reads config, creates the BrowserWindow, loads the URL, optionally shows the window,
    /// and starts the refresh timer.
    private func setup() {
        guard resolveConfig() else {
            stateQueue.sync { _isSettingUp = false }
            return
        }

        // Consume pending state on the main queue. handleFleetURL() always runs
        // on the main thread, so by the time this block executes, any fleet://
        // URL event that triggered the launch will have already set
        // _pendingPage / _pendingRefetch.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let (page, shouldRefetch): (String, Bool) = self.stateQueue.sync {
                let p = self._pendingPage ?? "self-service"
                self._pendingPage = nil
                let r = self._pendingRefetch
                self._pendingRefetch = false
                return (p, r)
            }
            if shouldRefetch {
                self.performRefetch()
            }
            guard let url = self.deviceURL(page: page) else {
                self.stateQueue.sync { self._isSettingUp = false }
                self.showError("Unable to construct self-service URL. Check Fleet configuration.")
                return
            }

            let browser = BrowserWindow()
            self.browserWindow = browser

            browser.onNavigationError = { [weak self] in
                self?.handleNavigationError()
            }
            browser.onWindowShow = { [weak self] in
                self?.refreshTokenIfNeeded()
            }

            browser.preload(url: url)
            self.startRefreshTimer()

            // Defer the show decision one turn so `NSApp.isActive` reflects hidden login / `open -j`.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let userWantsFleetWindow: Bool = self.stateQueue.sync {
                    let v = self._userRequestedFleetUI
                    self._userRequestedFleetUI = false
                    return v
                }
                let showNow = NSApp.isActive || userWantsFleetWindow
                if showNow {
                    browser.show()
                    self.deferredPresentationFromHeadlessLaunch = false
                } else {
                    self.deferredPresentationFromHeadlessLaunch = true
                }
                self.stateQueue.sync { self._isSettingUp = false }
            }
        }
    }

    /// After a headless launch, present the window the first time the user foregrounds the app
    /// (e.g. Cmd-Tab). Dock clicks use `applicationShouldHandleReopen` → `run()` instead.
    func onApplicationDidBecomeActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.deferredPresentationFromHeadlessLaunch, NSApp.isActive else { return }
            guard let browser = self.browserWindow, browser.isAvailable, !browser.isWindowVisible else {
                self.deferredPresentationFromHeadlessLaunch = false
                return
            }
            browser.show()
            self.deferredPresentationFromHeadlessLaunch = false
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

    /// Starts the refresh timer and declares an ongoing activity so App Nap
    /// doesn't throttle the timer when the window is closed. Called once at
    /// setup time; the timer runs for the lifetime of the service.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tokenRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTokenIfNeeded()
            self?.fetchDesktopData()
        }
        timer.tolerance = 5 // Allow system to coalesce for energy efficiency
        refreshTimer = timer

        // Prevent App Nap so the timer keeps firing (and the Dock badge stays
        // current) when the window is closed.
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Fleet Desktop badge polling"
            )
        }

        // Fetch the badge count immediately so the first update doesn't wait
        // for the full 60-second interval.
        fetchDesktopData()
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

    // MARK: - Badge Polling

    /// Fetches the desktop API endpoint and updates the Dock badge.
    private func fetchDesktopData() {
        let (base, token): (String?, String?) = stateQueue.sync { (_baseURL, _currentToken) }
        guard let baseURL = base,
              let tok = token,
              let encoded = tok.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/v1/fleet/device/\(encoded)/desktop") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                NSLog("Fleet Desktop: Badge poll failed: %@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode != 401 && http.statusCode != 403 {
                    NSLog("Fleet Desktop: Badge poll returned HTTP %d", http.statusCode)
                }
                return
            }
            guard let data = data else { return }
            self?.updateBadge(from: data)
        }.resume()
    }

    /// Parses the desktop API response and sets the Dock badge label.
    private func updateBadge(from data: Data) {
        struct DesktopResponse: Decodable {
            let failing_policies_count: Int
        }

        do {
            let response = try JSONDecoder().decode(DesktopResponse.self, from: data)
            let label: String? = response.failing_policies_count > 0
                ? "\(response.failing_policies_count)"
                : nil
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = label
            }
        } catch {
            NSLog("Fleet Desktop: Failed to decode desktop response: %@", error.localizedDescription)
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
