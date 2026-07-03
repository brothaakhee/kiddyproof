import XCTest
@testable import KiddyproofCore

final class WatchdogCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let grace: TimeInterval = 3.5

    // MARK: Protocol parsing

    func testParse() {
        XCTAssertEqual(WatchdogCore.parse("ARM 120"), .arm(maxSeconds: 120))
        XCTAssertEqual(WatchdogCore.parse("ARM"), .arm(maxSeconds: 120))       // default
        XCTAssertEqual(WatchdogCore.parse("ARM garbage"), .arm(maxSeconds: 120))
        XCTAssertEqual(WatchdogCore.parse("PING"), .ping)
        XCTAssertEqual(WatchdogCore.parse("DISARM"), .disarm)
        XCTAssertEqual(WatchdogCore.parse(""), .unknown)
        XCTAssertEqual(WatchdogCore.parse("EXPLODE"), .unknown)
    }

    // MARK: Enforcement

    func testNotEnforcingNeverKills() {
        let e = WatchdogCore.Enforcement(now: t0)
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(9999), heartbeatGrace: grace), .ok)
    }

    func testHeartbeatLossKills() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 120), now: t0)
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(3.0), heartbeatGrace: grace), .ok)
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(3.6), heartbeatGrace: grace), .killHeartbeatLost)
    }

    func testPingRefreshesHeartbeat() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 120), now: t0)
        e.apply(.ping, now: t0.addingTimeInterval(3.0))
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(6.0), heartbeatGrace: grace), .ok)
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(6.6), heartbeatGrace: grace), .killHeartbeatLost)
    }

    func testDeadlineKillsEvenWithFreshPings() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 10), now: t0)
        e.apply(.ping, now: t0.addingTimeInterval(9.9))
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(10.0), heartbeatGrace: grace), .killDeadline)
    }

    func testDisarmStopsEnforcement() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 10), now: t0)
        e.apply(.disarm, now: t0.addingTimeInterval(1))
        // Long silence AND past the old deadline: both must be ignored after DISARM.
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(1000), heartbeatGrace: grace), .ok)
    }

    func testRearmAfterDisarmStartsFresh() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 10), now: t0)
        e.apply(.disarm, now: t0.addingTimeInterval(5))
        let t1 = t0.addingTimeInterval(60)
        e.apply(.arm(maxSeconds: 10), now: t1)
        XCTAssertEqual(e.verdict(now: t1.addingTimeInterval(1), heartbeatGrace: grace), .ok)
        e.apply(.ping, now: t1.addingTimeInterval(9))   // keep the heartbeat fresh…
        XCTAssertEqual(e.verdict(now: t1.addingTimeInterval(10), heartbeatGrace: grace), .killDeadline)
    }

    func testUnknownCommandIsInert() {
        var e = WatchdogCore.Enforcement(now: t0)
        e.apply(.arm(maxSeconds: 120), now: t0)
        e.apply(.unknown, now: t0.addingTimeInterval(1))
        // Unknown must NOT refresh the heartbeat (only PING may).
        XCTAssertEqual(e.verdict(now: t0.addingTimeInterval(4), heartbeatGrace: grace), .killHeartbeatLost)
    }
}
