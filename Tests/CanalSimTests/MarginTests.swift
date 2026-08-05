import XCTest
@testable import CanalSim

// Fidelity tests for the margin port (src/25_margin.js).
//
// The reference implementation is JavaScript: it stores state in Float32Array but
// evaluates every expression in float64 and rounds on store, while this port is
// float32 throughout. Over ~1400 steps of a pattern-forming system that drift is
// real, so these tests do NOT chase bit-equality. They assert the STRUCTURE the
// model is supposed to produce, against numbers taken from running the reference:
//
//   $ SEED=3 node test/margin.mjs '{}'
//   {"steps":1401,"pts":618,"teeth":41,"aspect":0.47,"len":4.66}
//
// If the port had silently degraded into "a shape someone drew", these are the
// numbers that would stop matching: no teeth, or an aspect ratio that no longer
// falls out of the outgrowth.
final class MarginTests: XCTestCase {

    private func grow(seed: UInt32) -> Margin {
        let m = Margin(AuxinParams(), MarginOptions(), seed: seed)
        var s = 0
        while !m.mature && s < 4000 { m.step(1); s += 1 }
        XCTAssertTrue(m.mature, "margin never matured")
        XCTAssertEqual(s, 1401, "maturity is a pure step count and must match exactly")
        return m
    }

    // The headline claim: teeth are not drawn, they are however many convergence
    // points fit along the chain. Reference: 41 for seed 3.
    func testTeethEmergeFromConvergencePoints() {
        let m = grow(seed: 3)
        XCTAssertGreaterThan(m.teeth.count, 20, "no serration — the margin is not patterning")
        XCTAssertLessThan(m.teeth.count, 70, "the chain has shattered into noise, not teeth")

        // Convergence points are auxin maxima, so they must be spread along the
        // blade rather than piled at one end.
        let us = m.teeth.map { $0.u }
        XCTAssertLessThan(us.min()!, 0.35)
        XCTAssertGreaterThan(us.max()!, 0.65)

        // Teeth sit on the margin, both sides of the midrib.
        XCTAssertTrue(m.teeth.contains { $0.v < 0 }, "no teeth on the left half")
        XCTAssertTrue(m.teeth.contains { $0.v > 0 }, "no teeth on the right half")
    }

    // The chain resamples as it stretches: more margin, more room for teeth.
    // Reference: 618 points from a 17-point seed chain.
    func testChainResamplesAsItGrows() {
        let m = grow(seed: 3)
        XCTAssertGreaterThan(m.F.n, 400, "the margin barely lengthened")
        XCTAssertLessThanOrEqual(m.F.n, MarginOptions().maxPts)
    }

    // Slenderness is an outcome of ax/ay outgrowth, not a constant.
    // Reference: aspect 0.47, length 4.66.
    func testSilhouetteProportionsFallOutOfOutgrowth() {
        let m = grow(seed: 3)
        XCTAssertEqual(m.aspect, 0.47, accuracy: 0.12, "leaf slenderness drifted")
        XCTAssertEqual(m.length, 4.66, accuracy: 1.2, "leaf length drifted")

        // The baked half-widths must describe a closed blade: zero at both ends,
        // widest somewhere in the middle.
        XCTAssertEqual(m.half(0, -1), 0, accuracy: 1e-6)
        XCTAssertEqual(m.half(1, 1), 0, accuracy: 1e-6)
        let mid = max(m.half(0.5, -1), m.half(0.5, 1))
        XCTAssertGreaterThan(mid, 0.1, "the blade has no width at its middle")
    }

    // A species seed must reproduce its plant exactly, or the close-up replay
    // would end on an outline the leaf in front of you does not have.
    func testSameSeedReproducesTheSameOutline() {
        let a = grow(seed: 11), b = grow(seed: 11)
        XCTAssertEqual(a.teeth.count, b.teeth.count)
        XCTAssertEqual(a.F.n, b.F.n)
        for (x, y) in zip(a.teeth, b.teeth) {
            XCTAssertEqual(x.u, y.u)
            XCTAssertEqual(x.v, y.v)
        }
    }

    // Different seeds are different plants, not the same one twice.
    func testDifferentSeedsGrowDifferentOutlines() {
        let a = grow(seed: 3), b = grow(seed: 29)
        XCTAssertNotEqual(a.length, b.length)
    }
}
