import XCTest
import simd
@testable import CanalSim

// What actually lands in the vertex buffers. The GPU is a black box from here, so
// when a plant renders the wrong colour this is what says whether the colour was
// already wrong before it got there.
final class GeomTests: XCTestCase {

    private func grownPlant(_ species: Species, steps: Int) -> Plant {
        let p = Plant(species.prm, species.mo, species.sp, seed: 7)
        for _ in 0..<steps { p.step(1) }
        return p
    }

    func testBladeColoursMatchTheSpeciesPalette() {
        let sp = SpeciesTable.make("Ember Creeper", seed: 7)
        let plant = grownPlant(sp, steps: 700)
        let B = Buffers()
        var cam = Camera()
        cam.eye = SIMD3<Float>(0, 4, 14); cam.target = SIMD3<Float>(0, 4, 0); cam.dist = 14
        buildPlantScene(B, plant, sp, cam, 700, viewportHeight: 1000)

        XCTAssertGreaterThan(B.triCount, 1000, "nothing was built")

        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var sum = SIMD3<Float>(repeating: 0)
        var emisMax: Float = 0
        for v in 0..<B.triCount {
            let i = v * 10
            let c = SIMD3<Float>(B.tri[i + 6], B.tri[i + 7], B.tri[i + 8])
            lo = simd_min(lo, c); hi = simd_max(hi, c); sum += c
            emisMax = max(emisMax, B.tri[i + 9])
        }
        let mean = sum / Float(B.triCount)
        print("tri colour  lo=\(lo) hi=\(hi) mean=\(mean) emisMax=\(emisMax)")

        // Ember Creeper is a RED plant: blade0/1 are (0.26,0.05,0.06)/(0.58,0.11,0.12)
        // and every stem and petiole colour is redder still. Nothing in it is blue.
        XCTAssertGreaterThan(mean.x, mean.y, "red is not the dominant channel")
        XCTAssertGreaterThan(mean.x, mean.z, "blue has overtaken red — wrong palette")
        XCTAssertLessThan(hi.z, 0.5, "a blue this strong exists nowhere in this species")
        // and nothing may be out of the 0…1 range the shader assumes
        XCTAssertGreaterThanOrEqual(lo.min(), 0)
        XCTAssertLessThanOrEqual(hi.max(), 1.2)
    }

    func testNormalsAreUnitLength() {
        let sp = SpeciesTable.make("Ember Creeper", seed: 7)
        let plant = grownPlant(sp, steps: 700)
        let B = Buffers()
        var cam = Camera()
        cam.eye = SIMD3<Float>(0, 4, 14); cam.target = SIMD3<Float>(0, 4, 0); cam.dist = 14
        buildPlantScene(B, plant, sp, cam, 700, viewportHeight: 1000)

        var bad = 0
        for v in 0..<B.triCount {
            let i = v * 10
            let n = SIMD3<Float>(B.tri[i + 3], B.tri[i + 4], B.tri[i + 5])
            let l = simd_length(n)
            if !l.isFinite || abs(l - 1) > 0.02 { bad += 1 }
        }
        XCTAssertEqual(bad, 0, "\(bad) of \(B.triCount) normals are not unit length — shading would be flat")
    }

    func testPositionsAreFinite() {
        let sp = SpeciesTable.make("Sulphur Rosette", seed: 3)
        let plant = grownPlant(sp, steps: 700)
        let B = Buffers()
        var cam = Camera()
        cam.eye = SIMD3<Float>(0, 4, 14); cam.target = SIMD3<Float>(0, 4, 0); cam.dist = 14
        buildPlantScene(B, plant, sp, cam, 700, viewportHeight: 1000)
        for v in 0..<B.triCount {
            let i = v * 10
            for k in 0..<3 {
                XCTAssertTrue(B.tri[i + k].isFinite, "a vertex position went numeric")
            }
        }
        for v in 0..<B.lineCount {
            let i = v * 7
            for k in 0..<3 {
                XCTAssertTrue(B.line[i + k].isFinite, "a ribbon vertex went numeric")
            }
        }
    }
}
