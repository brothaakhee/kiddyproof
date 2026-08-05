import XCTest
@testable import CanalSim

// The Swift counterpart of the reference's CI gate (test/smoke.mjs): structural
// invariants for the whole organism. Deliberately LOOSE, for the reason the
// original states — pinning down divergence angles, petal counts or leaf
// proportions in a test would quietly turn an emergent result into an imposed
// one, which is the exact failure this project exists to avoid.
//
// What is asserted: the chemistry stays finite, a plant branches, flowers, sets
// fruit from ovules it placed itself, and then finishes.
final class PlantTests: XCTestCase {

    private func lifeCycle() -> Plant {
        var prm = AuxinParams()
        prm.T = 40; prm.D = 6; prm.mu = 0.3; prm.rho = 0.6; prm.b = 3
        var mo = MeristemOptions()
        mo.R = 10; mo.rCZ = 2.4; mo.rPZ = 6.8; mo.G = 0.0042
        var sp = SpeciesOptions()
        sp.leafLibrary = 3; sp.maxAxes = 8; sp.branching = 0.55
        let p = Plant(prm, mo, sp, seed: 21)
        for _ in 0..<5000 { p.step(1) }
        return p
    }

    func testPlantBranchesFlowersAndSetsFruit() {
        let p = lifeCycle()

        XCTAssertGreaterThan(p.axes.count, 1, "plant never branched")
        XCTAssertTrue(p.florigen.isFinite, "florigen went numeric")

        let flowers = p.axes.filter { $0.floral }
        XCTAssertGreaterThan(flowers.count, 0, "plant never flowered")

        let petals = p.axes.reduce(0) { $0 + $1.organs.filter { $0.petal }.count }
        XCTAssertGreaterThan(petals, 0, "no petals were initiated")

        let fruits = p.axes.compactMap { $0.fruit }
        XCTAssertGreaterThan(fruits.count, 0, "no fruit set")

        for a in p.axes {
            XCTAssertTrue(a.length.isFinite, "an axis length went numeric")
            for pt in a.pts {
                XCTAssertTrue(pt.x.isFinite && pt.y.isFinite && pt.z.isFinite,
                              "a stem point went numeric")
            }
        }
        // Leaves must be real canalised blades, not placeholders.
        let withBlades = p.axes.flatMap { $0.organs }.filter { $0.leaf != nil }
        XCTAssertGreaterThan(withBlades.count, 0, "no organ ever received a blade")
        for org in withBlades where !org.petal {
            guard let l = org.leaf else { continue }
            XCTAssertTrue(l.margin.mature, "a blade was handed out before its outline closed")
            XCTAssertGreaterThan(l.veins.count, 0, "a blade has no vein network")
        }
    }

    // A specimen that has run out of growing points dismantles itself. How fast
    // and in what order is not asserted — only that it happens and never reverses.
    func testSpecimenFinishes() {
        let p = lifeCycle()
        var spentAt: Int? = nil
        var sen: Float = 0
        var wentBackwards = false
        for s in 5001...20000 {
            p.step(1)
            if spentAt == nil && p.spent() { spentAt = s }
            let v = p.senescence()
            if v < sen - 1e-6 { wentBackwards = true }
            sen = v
            if p.dead() { break }
        }
        XCTAssertNotNil(spentAt, "a growing point never gave up")
        XCTAssertTrue(sen.isFinite && sen >= 0 && sen <= 1, "senescence is not a fraction")
        XCTAssertGreaterThan(sen, 0, "a spent specimen never began to senesce")
        XCTAssertFalse(wentBackwards, "senescence ran backwards")
        let shed = p.axes.reduce(0) { $0 + $1.organs.filter { $0.shed }.count }
        XCTAssertGreaterThan(shed, 0, "no blades were shed")
        XCTAssertTrue([.senescing, .dead].contains(p.stage()),
                      "stage never reached senescing or dead: \(p.stage())")
    }

    // Ovules are convergence points on the ovary wall — placed, not counted.
    func testFruitSetsSeedAcrossSeeds() {
        for seed in [UInt32(3), 17, 41, 88] {
            let f = Fruit(AuxinParams(), FruitOptions(), seed: seed)
            var s = 0
            while !f.mature && s < 4000 { f.step(1); s += 1 }
            for _ in 0..<400 { f.step(1) }   // let the ripening wave finish

            XCTAssertTrue(f.mature, "seed \(seed): fruit never matured")
            XCTAssertGreaterThan(f.seeds.count, 0, "seed \(seed): no ovules placed")
            for i in 0..<f.n {
                XCTAssertTrue(f.rad[i].isFinite, "seed \(seed): a radius went numeric")
                XCTAssertGreaterThan(f.rad[i], 0, "seed \(seed): the surface collapsed")
            }
            // the lobing is a readout of where the seeds landed, so it must exist
            XCTAssertGreaterThan(f.stats().lobing, 0.01, "seed \(seed): fruit is a perfect sphere")
        }
    }
}
