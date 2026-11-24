/// The app's lifecycle decisions, free of AppKit: whether a launch hands over to another running
/// instance, and whether the Dock icon shows.
public enum InstancePolicy {
    /// The process id of another running instance with `bundleID`, or nil when this one is the
    /// only one. `running` is the user session's running applications, this process included.
    /// Copies at different paths (a development build and the installed app) share the bundle id,
    /// so each yields to the other. With several, the lowest process id wins.
    public static func shouldYield(
        selfPID: Int32, running: [(bundleID: String?, pid: Int32)], bundleID: String
    ) -> Int32? {
        running
            .filter { $0.bundleID == bundleID && $0.pid != selfPID }
            .map(\.pid)
            .min()
    }

    /// True when the app should leave the Dock and live in the menu bar only: the setting is on
    /// and no Radarix window is open.
    public static func activationIsAccessory(menuBarOnly: Bool, openWindowCount: Int) -> Bool {
        menuBarOnly && openWindowCount == 0
    }
}
