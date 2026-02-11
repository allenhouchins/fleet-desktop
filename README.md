# Fleet Desktop

Fleet Desktop is a native macOS application that provides end users with a self-service portal for [Fleet](https://fleetdm.com). It integrates with Fleet's [orbit](https://fleetdm.com/docs/get-started/anatomy#orbit) agent to give users direct access to device management features without needing to open a browser.

## Features

- **Native macOS app** built with Swift and AppKit
- **Universal binary** supporting Apple Silicon (arm64) and Intel (x86_64)
- **Self-service portal** embedded in a native window via WKWebView
- **Automatic token refresh** handles hourly token rotation transparently
- **Loading screen** with Fleet logo while the portal loads
- **File download support** for `.mobileconfig` profiles and other files served by Fleet
- **Dark/light mode** respects the user's system appearance
- **Code signed and notarized** for secure distribution via `.pkg` installer

## Requirements

- macOS 13.0 (Ventura) or later
- Fleet's orbit agent installed and enrolled
- The Fleet URL must be available via managed preferences (MDM) or the orbit LaunchDaemon plist
- The orbit identifier file must exist at `/opt/orbit/identifier`

## Installation

### From Releases

1. Download the latest `fleet_desktop-v*.pkg` from the [Releases](https://github.com/fleetdm/fleet-desktop/releases) page
2. Double-click the `.pkg` file to run the installer
3. Follow the installation wizard

The installer places the app in `/Applications` with `root:admin` ownership and `755` permissions. On upgrades, the installer gracefully quits Fleet Desktop before installing and automatically relaunches it afterward.

### Via Fleet (Software)

Upload the `.pkg` to Fleet as a software installer. Fleet Desktop will appear in the software catalog for deployment.

## How It Works

1. **Reads the Fleet URL** from managed preferences or the orbit LaunchDaemon plist (see [Configuration Sources](#configuration-sources))
2. **Reads the device token** from `/opt/orbit/identifier` (managed by orbit, rotates hourly)
3. **Opens the self-service portal** at `{FleetURL}/device/{token}/self-service` in an embedded browser window

### Token Rotation

The device token in `/opt/orbit/identifier` rotates every hour. Fleet Desktop handles this automatically:

- A background timer checks the identifier file every 60 seconds (paused when the window is closed)
- On HTTP 401/403 errors or error page detection, the app immediately checks for a new token and retries (up to 3 attempts with 5-second delays)
- Token refreshes are invisible to the user — the page silently reloads with the new token

### File Downloads

When Fleet serves downloadable content (e.g., MDM enrollment profiles):

- `.mobileconfig` files are downloaded and automatically opened for installation
- All other file types (`.pkg`, `.dmg`, `.zip`, etc.) are saved to `~/Downloads`

### Security

- App Transport Security (ATS) is enforced — only HTTPS connections are allowed
- External links are restricted to `https`, `http`, and `mailto` schemes
- Device tokens are percent-encoded and not exposed in error messages
- Downloaded files are only auto-opened if they are `.mobileconfig` profiles
- The WebView uses a non-persistent data store (no cookies or cache persist between sessions)
- Mutable state is protected by a serial dispatch queue for thread safety

## Development

### Project Structure

```
fleet-desktop/
├── FleetDesktop/
│   ├── FleetDesktopApp.swift   # App delegate, main menu, entry point
│   ├── FleetService.swift      # Config reading, token management, refresh timer
│   ├── BrowserWindow.swift     # WKWebView window, loading overlay, downloads
│   ├── Info.plist              # App bundle metadata
│   ├── AppIcon.icns            # App icon
│   └── fleet-logo.png          # Fleet logo for loading screen
├── build.sh                    # Compiles universal binary
├── build-pkg.sh                # Creates signed .pkg installer
├── LICENSE                     # MIT License
└── .github/workflows/
    ├── build.yml               # CI: build, sign, notarize, upload artifact
    └── build-and-release.yml   # Release: manual trigger, creates GitHub Release
```

### Building Locally

```bash
# Build the app
./build.sh

# Run
open "build/Fleet Desktop.app"

# Build the .pkg installer
./build-pkg.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ORBIT_ROOT_DIR` | `/opt/orbit` | Override the orbit directory (changes where the identifier file is read from) |

### Configuration Sources

The Fleet URL is resolved in the following order (first match wins):

| Priority | File | Key | Scenario |
|----------|------|-----|----------|
| 1 | `/Library/Managed Preferences/com.fleetdm.fleetd.config.plist` | `FleetURL` | MDM-managed machines |
| 2 | `/Library/LaunchDaemons/com.fleetdm.orbit.plist` | `EnvironmentVariables > ORBIT_FLEET_URL` | Non-MDM machines |

| File | Purpose |
|------|---------|
| `/opt/orbit/identifier` | Device authentication token (rotates hourly) |

## CI/CD

There are two GitHub Actions workflows:

### Build (`.github/workflows/build.yml`)

Runs automatically on every push to `main` and on pull requests (doc-only changes are skipped). This lets contributors verify and test their changes.

1. Compiles a universal binary (arm64 + x86_64)
2. Code signs the app with a Developer ID Application certificate
3. Packages into a `.pkg` installer with a custom distribution XML
4. Signs the `.pkg` with a Developer ID Installer certificate
5. Notarizes with Apple and staples the ticket
6. Uploads the signed `.pkg` as a workflow artifact (retained for 30 days)

### Build and Release (`.github/workflows/build-and-release.yml`)

Manually triggered via `workflow_dispatch`. Performs all the same build, sign, and notarize steps as the Build workflow, then creates a GitHub Release with the `.pkg` attached.

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate (.p12) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the application certificate |
| `APPLE_INSTALLER_CERTIFICATE_BASE64` | Base64-encoded Developer ID Installer certificate (.p12) |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | Password for the installer certificate |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

### Releasing a New Version

1. Update `CFBundleShortVersionString` in `FleetDesktop/Info.plist`
2. Push to `main` (the Build workflow will run automatically to verify the build)
3. Go to **Actions → Build and Release → Run workflow** to create a GitHub Release

## Contributing

Contributions are welcome.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Open a Pull Request

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Support

- [Open an issue](https://github.com/fleetdm/fleet-desktop/issues) on GitHub
- [Fleet documentation](https://fleetdm.com/docs)
