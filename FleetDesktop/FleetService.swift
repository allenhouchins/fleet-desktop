import Foundation
import AppKit

/// Core service that reads the Fleet URL and device token from orbit,
/// then opens the self-service portal in a browser window.
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
    private var baseURL: String?

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

    /// Characters to trim from file contents (leading/trailing only).
    private static let trimCharacters = CharacterSet(charactersIn: "\n\r ")

    /// Path to the managed preferences plist (MDM-managed machines).
    private static let managedPrefsPlistPath = "/Library/Managed Preferences/com.fleetdm.fleetd.config.plist"

    /// Path to the orbit LaunchDaemon plist (fallback for non-MDM machines).
    private static let orbitPlistPath = "/Library/LaunchDaemons/com.fleetdm.orbit.plist"

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

    // MARK: - Private

    /// Builds the self-service URL from the base URL and current token.
    /// The token is percent-encoded to handle any special characters safely.
    private func selfServiceURL() -> URL? {
        let token: String? = stateQueue.sync { _currentToken }
        guard let baseURL = baseURL,
              let tok = token,
              let encoded = tok.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(baseURL)/device/\(encoded)/self-service")
    }

    /// Reads config, creates the BrowserWindow, loads the URL, shows the window,
    /// and starts the refresh timer.
    private func setup() {
        guard resolveConfig() else {
            stateQueue.sync { _isSettingUp = false }
            return
        }
        guard let url = selfServiceURL() else {
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
            showError("Fleet URL not found.\n\nChecked:\n• \(Self.managedPrefsPlistPath) (key: FleetURL)\n• \(Self.orbitPlistPath) (key: EnvironmentVariables > ORBIT_FLEET_URL)")
            return false
        }

        baseURL = fleetURL.hasSuffix("/") ? String(fleetURL.dropLast()) : fleetURL

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
        guard let url = selfServiceURL() else { return }

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
            if let url = selfServiceURL(), let browser = browserWindow {
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

    /// Reads the Fleet URL from managed preferences (MDM) first,
    /// falling back to the orbit LaunchDaemon plist (non-MDM).
    private func readFleetURL() -> String? {
        // 1. MDM-managed machines: check managed preferences
        if let url = readManagedPrefsFleetURL() {
            return url
        }
        // 2. Fallback: orbit LaunchDaemon plist
        return readOrbitPlistFleetURL()
    }

    private func readManagedPrefsFleetURL() -> String? {
        guard let plist = NSDictionary(contentsOfFile: Self.managedPrefsPlistPath),
              let url = plist["FleetURL"] as? String else {
            return nil
        }
        let trimmed = url.trimmingCharacters(in: Self.trimCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readOrbitPlistFleetURL() -> String? {
        guard let plist = NSDictionary(contentsOfFile: Self.orbitPlistPath),
              let envVars = plist["EnvironmentVariables"] as? [String: Any],
              let url = envVars["ORBIT_FLEET_URL"] as? String else {
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
