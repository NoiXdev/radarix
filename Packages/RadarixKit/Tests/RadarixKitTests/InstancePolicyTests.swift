import Foundation
import Testing
@testable import RadarixKit

struct InstancePolicyTests {
    private let bundleID = "dev.noix.radarix"
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    @Test func yieldsToAnotherInstanceWithSameBundleID() {
        // A development build and the installed copy share the bundle id: the newer one yields.
        let running: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [(bundleID, 100, earlier), (bundleID, 200, later)]
        #expect(InstancePolicy.shouldYield(selfPID: 200, selfLaunchDate: later, running: running, bundleID: bundleID) == 100)
        #expect(InstancePolicy.shouldYield(selfPID: 100, selfLaunchDate: earlier, running: running, bundleID: bundleID) == nil)
    }

    @Test func newerCopyYieldsEvenWithLowerPID() {
        // Process ids wrap, so the launch date decides first.
        let running: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [(bundleID, 900, earlier), (bundleID, 50, later)]
        #expect(InstancePolicy.shouldYield(selfPID: 50, selfLaunchDate: later, running: running, bundleID: bundleID) == 900)
        #expect(InstancePolicy.shouldYield(selfPID: 900, selfLaunchDate: earlier, running: running, bundleID: bundleID) == nil)
    }

    @Test func equalDatesLeaveOnlyTheLowerPID() {
        // Two copies started together: exactly one survives.
        let running: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [(bundleID, 100, earlier), (bundleID, 200, earlier)]
        #expect(InstancePolicy.shouldYield(selfPID: 200, selfLaunchDate: earlier, running: running, bundleID: bundleID) == 100)
        #expect(InstancePolicy.shouldYield(selfPID: 100, selfLaunchDate: earlier, running: running, bundleID: bundleID) == nil)
    }

    @Test func missingDateFallsBackToPID() {
        let otherUndated: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [(bundleID, 100, nil), (bundleID, 200, earlier)]
        #expect(InstancePolicy.shouldYield(selfPID: 200, selfLaunchDate: earlier, running: otherUndated, bundleID: bundleID) == 100)
        #expect(InstancePolicy.shouldYield(selfPID: 100, selfLaunchDate: nil, running: otherUndated, bundleID: bundleID) == nil)
        let selfUndated: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [(bundleID, 100, later), (bundleID, 200, nil)]
        #expect(InstancePolicy.shouldYield(selfPID: 200, selfLaunchDate: nil, running: selfUndated, bundleID: bundleID) == 100)
        #expect(InstancePolicy.shouldYield(selfPID: 100, selfLaunchDate: later, running: selfUndated, bundleID: bundleID) == nil)
    }

    @Test func ignoresItselfAndOtherApps() {
        let running: [(bundleID: String?, pid: Int32, launchDate: Date?)] = [
            (bundleID, 300, later),
            ("dev.noix.radarix.widget", 301, earlier),
            ("com.example.other", 302, earlier),
            (nil, 303, earlier),
        ]
        #expect(InstancePolicy.shouldYield(selfPID: 300, selfLaunchDate: later, running: running, bundleID: bundleID) == nil)
        #expect(InstancePolicy.shouldYield(selfPID: 300, selfLaunchDate: later, running: [], bundleID: bundleID) == nil)
    }

    @Test func accessoryOnlyWhenMenuBarOnlyAndNoWindows() {
        #expect(InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 0))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 1))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: true, openWindowCount: 3))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: false, openWindowCount: 0))
        #expect(!InstancePolicy.activationIsAccessory(menuBarOnly: false, openWindowCount: 2))
    }
}
