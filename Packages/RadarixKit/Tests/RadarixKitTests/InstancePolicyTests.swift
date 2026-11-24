import Testing
@testable import RadarixKit

struct InstancePolicyTests {
    private let bundleID = "dev.noix.radarix"

    @Test func yieldsToAnotherInstanceWithSameBundleID() {
        // A development build and the installed copy share the bundle id: either yields to the other.
        let running: [(bundleID: String?, pid: Int32)] = [(bundleID, 200), (bundleID, 100)]
        #expect(InstancePolicy.shouldYield(selfPID: 200, running: running, bundleID: bundleID) == 100)
        #expect(InstancePolicy.shouldYield(selfPID: 100, running: running, bundleID: bundleID) == 200)
    }

    @Test func ignoresItselfAndOtherApps() {
        let running: [(bundleID: String?, pid: Int32)] = [
            (bundleID, 300),
            ("dev.noix.radarix.widget", 301),
            ("com.example.other", 302),
            (nil, 303),
        ]
        #expect(InstancePolicy.shouldYield(selfPID: 300, running: running, bundleID: bundleID) == nil)
        #expect(InstancePolicy.shouldYield(selfPID: 300, running: [], bundleID: bundleID) == nil)
    }

    @Test func accessoryOnlyWhenMenuBarOnlyAndNoWindows() {
        #expect(InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 0))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 1))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 3))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: false, openWindowCount: 0))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: false, openWindowCount: 2))
    }
}
