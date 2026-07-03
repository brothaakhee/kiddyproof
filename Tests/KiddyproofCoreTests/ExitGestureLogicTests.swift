import XCTest
@testable import KiddyproofCore

final class ExitGestureLogicTests: XCTestCase {
    func testDeliberateChordHoldFires() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 0), 0)
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 1.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 3.0), 1.0)
    }

    func testDeliberateCornerHoldFires() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        _ = g.progress(chordHeld: false, cornerHeld: true, now: 10)
        XCTAssertEqual(g.progress(chordHeld: false, cornerHeld: true, now: 13), 1.0)
    }

    func testReleaseResetsTheChannel() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        _ = g.progress(chordHeld: true, cornerHeld: false, now: 0)
        _ = g.progress(chordHeld: true, cornerHeld: false, now: 2.9)
        _ = g.progress(chordHeld: false, cornerHeld: false, now: 3.0)   // released!
        // Holding again must start over, not resume.
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 3.1), 0)
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 5.0), 0.633, accuracy: 0.01)
    }

    func testChannelsAreIndependent() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        _ = g.progress(chordHeld: true, cornerHeld: false, now: 0)
        // Corner starts later; chord released at 2s. Progress must track the max but
        // the corner channel keeps its own clock.
        _ = g.progress(chordHeld: true, cornerHeld: true, now: 1.0)
        let p = g.progress(chordHeld: false, cornerHeld: true, now: 2.0)
        XCTAssertEqual(p, 1.0 / 3.0, accuracy: 0.001)   // corner held 1s of 3s
        XCTAssertEqual(g.progress(chordHeld: false, cornerHeld: true, now: 4.0), 1.0)
    }

    // The product claim: random mashing cannot exit. Simulate a toddler with a
    // deterministic PRNG flipping inputs every 50-300ms for 60 seconds — a continuous
    // 3s hold of either channel must never occur.
    func testRandomMashingNeverFires() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        var seed: UInt64 = 0x5EED
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        var now: TimeInterval = 0
        var maxProgress = 0.0
        while now < 60 {
            let chord = rand() < 0.3    // toddlers hit modifier clusters surprisingly often
            let corner = rand() < 0.2
            maxProgress = max(maxProgress, g.progress(chordHeld: chord, cornerHeld: corner, now: now))
            now += 0.05 + rand() * 0.25
        }
        XCTAssertLessThan(maxProgress, 1.0, "random mashing produced a full 3s hold")
    }

    func testResetClearsHolds() {
        var g = ExitGestureLogic(holdSeconds: 3.0)
        _ = g.progress(chordHeld: true, cornerHeld: false, now: 0)
        _ = g.progress(chordHeld: true, cornerHeld: false, now: 2.9)
        g.reset()
        XCTAssertEqual(g.progress(chordHeld: true, cornerHeld: false, now: 3.0), 0)
    }
}
