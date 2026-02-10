import Foundation
import AppKit

/// Reads the Fleet URL and device token from orbit configuration,
/// then opens the self-service portal in the user's default browser.
final class FleetService {
    private let tokenFile: String

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

    // MARK: - Public

    /// Reads config, builds the self-service URL, and opens it in the default browser.
    func openInBrowser() {
        guard let fleetURL = readFleetURL() else {
            showError("Fleet URL not found.\n\nChecked:\n• \(Self.managedPrefsPlistPath) (key: FleetURL)\n• \(Self.orbitPlistPath) (key: EnvironmentVariables > ORBIT_FLEET_URL)")
            return
        }

        guard fleetURL.lowercased().hasPrefix("https://") else {
            showError("Fleet URL must use HTTPS. Found: \(fleetURL)")
            return
        }

        let baseURL = fleetURL.hasSuffix("/") ? String(fleetURL.dropLast()) : fleetURL

        guard let token = readToken(),
              let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/device/\(encoded)/self-service") else {
            showError("Device token not found or could not be read at \(tokenFile).\nEnsure orbit is enrolled and the identifier file exists.")
            return
        }

        NSWorkspace.shared.open(url)
    }

    // MARK: - File Reading

    /// Reads the Fleet URL from managed preferences (MDM) first,
    /// falling back to the orbit LaunchDaemon plist (non-MDM).
    private func readFleetURL() -> String? {
        if let url = readManagedPrefsFleetURL() {
            return url
        }
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
        let alert = NSAlert()
        alert.messageText = "Fleet Desktop"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}
