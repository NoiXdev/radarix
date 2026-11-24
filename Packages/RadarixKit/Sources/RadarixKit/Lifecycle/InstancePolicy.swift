import Foundation

/// The app's lifecycle decisions, free of AppKit: whether a launch hands over to another running
/// instance, and whether the Dock icon shows.
public enum InstancePolicy {
    /// The process id of the running instance with `bundleID` this launch hands over to, or nil
    /// when this one stays. `running` is the user session's running applications, this process
    /// included. Copies at different paths (a development build and the installed app) share the
    /// bundle id, so either yields to the other.
    ///
    /// Only the older copy wins: an earlier launch date, or on equal or missing dates the lower
    /// process id. Two copies started together so leave exactly one running.
    public static func shouldYield(
        selfPID: Int32, selfLaunchDate: Date?, running: [(bundleID: String?, pid: Int32, launchDate: Date?)],
        bundleID: String
    ) -> Int32? {
        running
            .filter { $0.bundleID == bundleID && $0.pid != selfPID }
            .filter { precedes(($0.pid, $0.launchDate), (selfPID, selfLaunchDate)) }
            .min { precedes(($0.pid, $0.launchDate), ($1.pid, $1.launchDate)) }?
            .pid
    }

    /// True when the app should leave the Dock and live in the menu bar only: the setting is on
    /// and no Radarix window is open.
    public static func activationIsAccessory(menuBarOnly: Bool, openWindowCount: Int) -> Bool {
        menuBarOnly && openWindowCount == 0
    }

    /// Whether instance `a` started before `b`. The process id breaks the tie when the dates are
    /// equal or one is missing; process ids wrap, so they decide only then.
    private static func precedes(_ a: (pid: Int32, date: Date?), _ b: (pid: Int32, date: Date?)) -> Bool {
        if let dateA = a.date, let dateB = b.date, dateA != dateB { return dateA < dateB }
        return a.pid < b.pid
    }
}
