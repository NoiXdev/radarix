import AppKit
import UserNotifications

/// Owns the app model and keeps Radarix running, and syncing, with no window open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launching finishes, so a click that launched Radarix is delivered.
        UNUserNotificationCenter.current().delegate = model.notifications
        // The launch event is only available until launching finishes.
        let event = NSAppleEventManager.shared().currentAppleEvent
        model.launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
