import Foundation
import Testing
@testable import EZSwitch

@Suite("Automatic update policy")
struct AutomaticUpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let interval: TimeInterval = 24 * 60 * 60

    @Test
    func firstLaunchChecks() {
        #expect(AutomaticUpdatePolicy.shouldCheck(
            lastCheckedAt: nil,
            lastCheckedVersion: nil,
            currentVersion: "0.1.4",
            now: now
        ))
    }

    @Test
    func withinIntervalSkips() {
        #expect(!AutomaticUpdatePolicy.shouldCheck(
            lastCheckedAt: now.addingTimeInterval(-(interval - 1)),
            lastCheckedVersion: "0.1.4",
            currentVersion: "0.1.4",
            now: now
        ))
    }

    @Test
    func afterIntervalChecks() {
        #expect(AutomaticUpdatePolicy.shouldCheck(
            lastCheckedAt: now.addingTimeInterval(-(interval + 1)),
            lastCheckedVersion: "0.1.4",
            currentVersion: "0.1.4",
            now: now
        ))
    }

    @Test
    func appVersionChangeChecks() {
        #expect(AutomaticUpdatePolicy.shouldCheck(
            lastCheckedAt: now.addingTimeInterval(-1),
            lastCheckedVersion: "0.1.3",
            currentVersion: "0.1.4",
            now: now
        ))
    }

    @Test
    func futureTimestampChecks() {
        #expect(AutomaticUpdatePolicy.shouldCheck(
            lastCheckedAt: now.addingTimeInterval(interval),
            lastCheckedVersion: "0.1.4",
            currentVersion: "0.1.4",
            now: now
        ))
    }
}
