import Foundation
import simd

// ---------------------------------------------------------------------------
// SPECIES — the parameter sets and palettes from the reference's own table
// (src/70_app.js). A species is a set of RATE CONSTANTS, never a shape: nothing
// in here states a width, a tooth count, a petal count or a branching pattern.
// Those all fall out of the chemistry the constants drive.
//
// The reference ships eight. Three are ported: the two shown in the post the
// scene is measured against, plus the generic plant.
// ---------------------------------------------------------------------------

public struct Species {
    public var name: String
    public var prm: AuxinParams
    public var mo: MeristemOptions
    public var sp: SpeciesOptions
    public var pal: Palette
    public var petal: Palette
    public var inner: [Palette]

    // The lamina is pulled down so the vasculature is the brightest thing in the
    // plant: a leaf should read as light held inside tissue.
    static let laminaMul: Float = 0.86
    static let innerSteps = 5

    init(name: String, prm: AuxinParams, mo: MeristemOptions, sp: SpeciesOptions,
         pal base: Palette, petal0: SIMD3<Float>, petal1: SIMD3<Float>,
         petalVein: SIMD3<Float>) {
        self.name = name
        self.prm = prm
        self.mo = mo
        self.sp = sp
        var p = base
        let m = Species.laminaMul
        p.blade0 *= m
        p.blade1 *= m
        self.pal = p

        // petals share every rendering rule with leaves; only the colours differ
        var pe = p
        pe.blade0 = petal0 * m
        pe.blade1 = petal1 * m
        pe.vein = petalVein
        pe.veinTint = petal1 * 0.25
        self.petal = pe

        // Inner floral organs grade from the petal colour toward the species'
        // own vein colour — its bright accent — so an inner organ reads as
        // catching light rather than as a leaf that failed to open. Graded on
        // `q`, not switched on identity: q is continuous, and nothing here
        // should know how many whorls there are.
        var steps: [Palette] = []
        for i in 0..<Species.innerSteps {
            let t = 0.30 + 0.62 * (Float(i) / Float(Species.innerSteps - 1))
            let tv = SIMD3<Float>(repeating: t)
            var q = pe
            q.blade0 = simd_mix(pe.blade0, p.vein * (m * 0.55), tv)
            q.blade1 = simd_mix(pe.blade1, p.vein * m, tv)
            q.glow = pe.glow * (1 + 0.5 * t)
            steps.append(q)
        }
        self.inner = steps
    }

    // Which palette an organ is drawn in. Continuous in `q`, so nothing counts whorls.
    public func paletteFor(_ org: Organ) -> Palette {
        if org.petal { return petal }
        guard org.floral else { return pal }
        let t = (org.q - sp.petalQ) / max(1e-3, 1 - sp.petalQ)
        let i = Int(canalClamp((t * Float(Species.innerSteps - 1)).rounded(), 0, Float(Species.innerSteps - 1)))
        return inner[i]
    }

    // The fruit's own chemistry is drawn from the species seed, so two specimens
    // of one species do not set identical fruit.
    static func fruitOpts(seed: UInt32) -> FruitOptions {
        var r = Mulberry32(seed: seed ^ 0x51ed270b)
        var f = FruitOptions()
        f.T = canalLerp(14, 34, r.next())
        f.D = canalLerp(1.8, 4.2, r.next())
        return f
    }
}

public enum SpeciesTable {

    public static let names = ["Sulphur Rosette", "Ember Creeper", "Common Frond"]

    public static func make(_ name: String, seed: UInt32) -> Species {
        switch name {
        case "Sulphur Rosette": return sulphurRosette(seed: seed)
        case "Ember Creeper":   return emberCreeper(seed: seed)
        default:                return commonFrond(seed: seed)
        }
    }

    // A rosette run slow: no branching, tiny internodes, so seventy-odd blades
    // pile into one whorl instead of climbing.
    static func sulphurRosette(seed: UInt32) -> Species {
        var prm = AuxinParams()
        prm.T = 42; prm.D = 6.8; prm.mu = 0.30; prm.rho = 0.60; prm.b = 3.2
        var mo = MeristemOptions()
        mo.R = 10; mo.rCZ = 2.4; mo.rPZ = 6.8; mo.G = 0.0034
        var sp = SpeciesOptions()
        sp.elongation = 0.0016; sp.internode = 0.0011; sp.internodeSpan = 1.4
        sp.minInternode = 0.015; sp.organLen = 2.6; sp.organTilt = 1.34; sp.droop = 0.18
        sp.maxOrgans = 78; sp.organBudget = 84
        sp.branching = 0.0; sp.maxAxes = 1; sp.nutation = 0.006; sp.nutAmp = 0.05
        sp.wander = 0.10; sp.florigenThresh = 46; sp.floralOrgans = 12; sp.organRoll = 0.20
        sp.marginBias.ay = 0.78; sp.marginBias.g1 = 1.20; sp.marginBias.gExp = 1.15
        sp.fruitOpts = Species.fruitOpts(seed: seed)

        var pal = Palette()
        pal.blade0 = [0.10, 0.13, 0.02]; pal.blade1 = [0.26, 0.32, 0.04]
        pal.veinTint = [0.26, 0.30, 0.02]; pal.vein = [0.85, 1.0, 0.25]
        pal.stem0 = [0.18, 0.22, 0.05];   pal.stem1 = [0.40, 0.48, 0.10]
        pal.cell0 = [0.14, 0.17, 0.04];   pal.cell1 = [0.90, 1.0, 0.40]
        pal.fog = [0.028, 0.032, 0.011];  pal.fogD = 0.072
        pal.key = simd_normalize([0.30, 0.80, 0.52]); pal.keyCol = [0.92, 1.0, 0.70]
        pal.ambTop = [0.14, 0.17, 0.07];  pal.ambBot = [0.03, 0.035, 0.014]
        pal.glow = 0.95
        pal.pin = [0.85, 1.0, 0.45];      pal.spark = [1.0, 1.0, 0.75]
        pal.fruit0 = [0.16, 0.19, 0.04];  pal.fruit1 = [0.95, 0.95, 0.20]
        applyGrade(&pal)

        return Species(name: "Sulphur Rosette", prm: prm, mo: mo, sp: sp, pal: pal,
                       petal0: [0.34, 0.38, 0.10], petal1: [0.95, 1.0, 0.45],
                       petalVein: [1.0, 1.0, 0.70])
    }

    // A vine: long internodes, hard circumnutation, flowers early and often.
    static func emberCreeper(seed: UInt32) -> Species {
        var prm = AuxinParams()
        prm.T = 38; prm.D = 6.8; prm.mu = 0.30; prm.rho = 0.60; prm.b = 2.9
        var mo = MeristemOptions()
        mo.R = 10.5; mo.rCZ = 2.6; mo.rPZ = 7.0; mo.G = 0.0038
        var sp = SpeciesOptions()
        sp.elongation = 0.0058; sp.internode = 0.0090; sp.internodeSpan = 3.6
        sp.organLen = 3.6; sp.organTilt = 1.16; sp.droop = 0.62; sp.maxOrgans = 30
        sp.branching = 0.22; sp.maxAxes = 3; sp.wander = 0.55; sp.nutation = 0.030
        sp.nutAmp = 0.52; sp.tropism = 0.030; sp.florigenThresh = 8; sp.maxFlowers = 8
        sp.fruitScale = 0.78
        sp.marginBias.ay = 1.35; sp.marginBias.g1 = 0.85; sp.marginBias.D = 1.25
        sp.fruitOpts = Species.fruitOpts(seed: seed)

        var pal = Palette()
        pal.blade0 = [0.26, 0.05, 0.06]; pal.blade1 = [0.58, 0.11, 0.12]
        pal.veinTint = [0.32, 0.04, 0.03]; pal.vein = [1.0, 0.42, 0.24]
        pal.stem0 = [0.16, 0.06, 0.05];  pal.stem1 = [0.34, 0.14, 0.10]
        pal.cell0 = [0.18, 0.04, 0.04];  pal.cell1 = [1.0, 0.45, 0.30]
        pal.fog = [0.035, 0.012, 0.012]; pal.fogD = 0.075
        pal.key = simd_normalize([0.38, 0.72, 0.50]); pal.keyCol = [1.0, 0.72, 0.62]
        pal.ambTop = [0.18, 0.08, 0.08];  pal.ambBot = [0.04, 0.016, 0.016]
        pal.glow = 1.0
        pal.pin = [1.0, 0.55, 0.40];      pal.spark = [1.0, 0.85, 0.70]
        pal.fruit0 = [0.20, 0.04, 0.05];  pal.fruit1 = [1.0, 0.24, 0.16]
        applyGrade(&pal)

        return Species(name: "Ember Creeper", prm: prm, mo: mo, sp: sp, pal: pal,
                       petal0: [0.42, 0.08, 0.10], petal1: [1.0, 0.50, 0.42],
                       petalVein: [1.0, 0.80, 0.70])
    }

    // The generic plant: the module defaults, with nothing overridden.
    static func commonFrond(seed: UInt32) -> Species {
        var sp = SpeciesOptions()
        sp.fruitOpts = Species.fruitOpts(seed: seed)
        var pal = Palette()
        applyGrade(&pal)
        return Species(name: "Common Frond", prm: AuxinParams(), mo: MeristemOptions(),
                       sp: sp, pal: pal,
                       petal0: [0.30, 0.24, 0.42], petal1: [0.72, 0.55, 0.95],
                       petalVein: [1.0, 0.85, 1.0])
    }

    // BASE_PAL's grade half, shared by every species.
    private static func applyGrade(_ p: inout Palette) {
        p.bloom = 0.38; p.bloomThresh = 1.15; p.exposure = 1.04
        p.grain = 0.024; p.vignette = 0.60; p.sway = 1.0; p.dof = 0.80
    }
}
