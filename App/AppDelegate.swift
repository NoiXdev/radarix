import AppKit
import UserNotifications

/// Owns the app model and keeps Radarix running, and syncing, with no window open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launching finishes, so a click that launched Radarix is delivered.
        UNUserNotificationCenter.current().delegate = model.notifications
        // The open-application event tells a launch at login apart. It is not yet current here,
        // so Radarix handles it itself.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenApplication(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A launch without an open-application event (for a link) is not one at login.
        model.setLaunchKind(atLogin: false)
        model.start()
    }

    @objc private func handleOpenApplication(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        model.setLaunchKind(
            atLogin: event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
