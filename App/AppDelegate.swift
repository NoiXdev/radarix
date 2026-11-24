import AppKit
import RadarixKit
import UserNotifications

/// Owns the app model and keeps Radarix running, and syncing, with no window open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var windows = WindowTracker { [model] in model.controller.settings.menuBarOnlyWhenClosed }
    /// Another instance of Radarix in this user session, which this launch hands over to.
    private var yieldingTo: NSRunningApplication?
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event tells a launch at login apart. It is not yet current here,
        // so Radarix handles it itself.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenApplication(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
        // Decided first: a launch that hands over neither syncs nor writes anything.
        if let other = Self.otherInstance() {
            yieldingTo = other
            model.yieldToOtherInstance()
            return
        }
        // Set before launching finishes, so a click that launched Radarix is delivered.
        UNUserNotificationCenter.current().delegate = model.notifications
        windows.observe()
        model.updateDockIcon = { [windows] in windows.update() }
        // No launch window comes, so under "menu bar only" the Dock icon never shows. A link
        // window brings it back as it appears.
        if model.controller.settings.startInBackground { windows.update() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A launch without an open-application event (for a link) is not one at login.
        model.setLaunchKind(atLogin: false)
        if let other = yieldingTo {
            handOver(to: other)
            return
        }
        model.start()
    }

    @objc private func handleOpenApplication(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        model.setLaunchKind(
            atLogin: event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click, or another copy of Radarix handing over: the main window comes to the front,
    /// or opens when none is open. "Start in the background" governs only the launch itself.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let main = windows.openWindow(of: .main) {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            model.open(.main)
        }
        return false
    }

    // MARK: One instance

    /// Another running Radarix in this user session, from any path. Each user session has its
    /// own list, so other users on this Mac are not affected.
    private static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard
            let pid = InstancePolicy.shouldYield(
                selfPID: ProcessInfo.processInfo.processIdentifier,
                selfLaunchDate: NSRunningApplication.current.launchDate,
                running: running.map {
                    (bundleID: $0.bundleIdentifier, pid: $0.processIdentifier, launchDate: $0.launchDate)
                },
                bundleID: bundleID)
        else { return nil }
        return running.first { $0.processIdentifier == pid }
    }

    /// Reopens `other`, as a Dock click would, then quits. A launch at login only quits: it
    /// must not bring up a window.
    private func handOver(to other: NSRunningApplication) {
        guard !model.launchedAtLogin, let url = other.bundleURL else {
            if !model.launchedAtLogin { other.activate() }
            terminate()
            return
        }
        // Quits once the reopen is sent, whether or not it succeeded: one instance runs either way.
        // A reopen that never answers still ends this copy after a few seconds.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in self.terminate() }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            terminate()
        }
    }

    /// Quits this copy, once, whichever of the handover's paths comes first.
    private func terminate() {
        guard !terminating else { return }
        terminating = true
        NSApp.terminate(nil)
    }
}
