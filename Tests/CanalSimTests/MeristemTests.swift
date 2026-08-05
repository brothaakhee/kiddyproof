import XCTest
@testable import CanalSim

// Fidelity tests for the meristem port (src/20_meristem.js), against the
// reference's own harness:
//
//   $ node test/phyllo.mjs
//   {"cells":366,"primordiaTotal":87,"live":5,"plastochron":37,
//    "auxin":{"mean":1.34,"max":11.37},
//    "divergence":{"mean":143.6,"sd":78.17,"n":60,"handed":"clockwise"}}
//
// Same caveat as MarginTests: float32-vs-float64 makes bit-equality impossible,
// so what is asserted is that the sheet still holds its own density, that organs
// still appear one at a time at a spacing nobody wrote down, and that the
// divergence angle lands near the golden angle rather than at 0 or 180.
final class MeristemTests: XCTestCase {

    private func grow(seed: UInt32 = 7, steps: Int = 2600) -> Meristem {
        let m = Meristem(AuxinParams(), MeristemOptions(), seed: seed)
        for _ in 0..<steps { m.step(1) }
        return m
    }

    // Division fills the gaps expansion opens: the sheet holds its density
    // instead of thinning out or exploding. Reference: 366 cells.
    func testSheetHoldsItsOwnDensity() {
        let m = grow()
        XCTAssertGreaterThan(m.F.n, 250, "the sheet thinned out — division is not keeping up")
        XCTAssertLessThan(m.F.n, 520, "the sheet is over-dividing")
        // every cell must still be inside the meristem's rim
        for i in 0..<m.F.n {
            let r = (m.F.x[i] * m.F.x[i] + m.F.y[i] * m.F.y[i]).squareRoot()
            XCTAssertLessThanOrEqual(r, m.o.R * 1.05, "a cell escaped past the rim")
        }
    }

    // Organs are auxin maxima that persisted, not scheduled events.
    // Reference: 87 emitted over 2600 steps, ~5 live at any moment.
    func testOrgansAreFoundedOneAtATime() {
        let m = grow()
        XCTAssertGreaterThan(m.emitted.count, 50, "the meristem is not founding organs")
        XCTAssertLessThan(m.emitted.count, 140, "maxima are shattering into noise")
        XCTAssertGreaterThan(m.primordia.count, 1, "no live primordia in the meristem")
        XCTAssertLessThan(m.primordia.count, 15, "the flank is jammed with maxima")
        XCTAssertGreaterThan(m.plastochron, 5, "organs are appearing with no interval at all")
    }

    // The divergence angle is measured, never written down. It should land in the
    // neighbourhood of the golden angle (137.5°) — the point is that nothing in
    // the source says so.
    func testDivergenceAngleIsNearGolden() {
        let m = grow()
        guard let st = m.divergenceStats(window: 60) else {
            return XCTFail("not enough organs to measure a divergence angle")
        }
        XCTAssertEqual(st.n, 60)
        XCTAssertGreaterThan(st.mean, 110, "divergence collapsed toward decussate/whorled")
        XCTAssertLessThan(st.mean, 175, "divergence collapsed toward distichous")
    }

    // Lateral inhibition is the depletion halo around each sink — so two organs
    // never occupy the same tissue.
    func testOrgansDoNotOverlap() {
        let m = grow()
        let live = m.primordia.filter { $0.emitted }
        for i in live.indices {
            for j in live.indices where j > i {
                let dx = live[i].x - live[j].x, dy = live[i].y - live[j].y
                XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), m.o.organR,
                                     "two primordia are sitting on the same cells")
            }
        }
    }

    // A species seed reproduces its meristem exactly.
    func testSameSeedReproducesTheSameSequence() {
        let a = grow(seed: 5, steps: 900), b = grow(seed: 5, steps: 900)
        XCTAssertEqual(a.F.n, b.F.n)
        XCTAssertEqual(a.emitted.count, b.emitted.count)
        XCTAssertEqual(a.divergence, b.divergence)
    }
}
