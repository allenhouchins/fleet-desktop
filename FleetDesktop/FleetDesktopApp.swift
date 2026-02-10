import AppKit

@main
struct FleetDesktopMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fleetService = FleetService()
    private var launchedViaURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for URL events before checking launch reason
        let em = NSAppleEventManager.shared()
        em.setEventHandler(self,
                           andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                           forEventClass: AEEventClass(kInternetEventClass),
                           andEventID: AEEventID(kAEGetURL))

        // Defer the default open so URL events received at launch have time to arrive
        DispatchQueue.main.async { [self] in
            if !launchedViaURL {
                fleetService.openInBrowser()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        launchedViaURL = true
        fleetService.openInBrowser()
        NSApp.terminate(nil)
    }
}
