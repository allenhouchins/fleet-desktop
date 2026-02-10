# Fleet Desktop

Fleet Desktop is a lightweight native macOS app that opens the [Fleet](https://fleetdm.com) self-service portal in the user's default browser. It reads the Fleet URL and device token from [orbit](https://fleetdm.com/docs/get-started/anatomy#orbit) configuration files and launches the appropriate self-service URL.

## Features

- **Native macOS app** built with Swift and AppKit
- **Universal binary** supporting Apple Silicon (arm64) and Intel (x86_64)
- **Browser launcher** — reads Fleet config and opens the self-service portal in the user's default browser
- **URL scheme handler** — registers the `fleet://` URL scheme so other apps can trigger it
- **Error alerts** — displays a native alert if the Fleet URL or device token can't be found
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
2. **Reads the device token** from `/opt/orbit/identifier` (managed by orbit)
3. **Opens the self-service portal** at `{FleetURL}/device/{token}/self-service` in the user's default browser
4. **Quits immediately** after opening the URL (or after displaying an error)

The app also registers a `fleet://` URL scheme. When launched via a URL event, it performs the same steps — opens the self-service portal and quits.

## Development

### Project Structure

```
fleet-desktop/
├── FleetDesktop/
│   ├── FleetDesktopApp.swift   # App delegate, main entry point, URL scheme handler
│   ├── FleetService.swift      # Config reading, token reading, browser launch
│   ├── Info.plist              # App bundle metadata
│   └── AppIcon.icns            # App icon
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
| `/opt/orbit/identifier` | Device authentication token |

## CI/CD

There are two GitHub Actions workflows:

### Build (`.github/workflows/build.yml`)

Runs automatically on every push and on pull requests (doc-only changes are skipped).

1. Compiles a universal binary (arm64 + x86_64)
2. Code signs the app with a Developer ID Application certificate
3. Packages into a `.pkg` installer
4. Signs the `.pkg` with a Developer ID Installer certificate
5. Notarizes with Apple and staples the ticket
6. Uploads the signed `.pkg` as a workflow artifact (retained for 30 days)

### Build and Release (`.github/workflows/build-and-release.yml`)

Manually triggered via `workflow_dispatch`. Performs all the same build, sign, and notarize steps as the Build workflow, then creates a GitHub Release with the `.pkg` attached. Skips release creation if the version tag already exists.

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
3. Go to **Actions > Build and Release > Run workflow** to create a GitHub Release

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
