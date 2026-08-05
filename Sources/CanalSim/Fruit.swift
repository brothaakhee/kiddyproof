import Foundation
import simd

// ---------------------------------------------------------------------------
// THE FRUIT — port of src/35_fruit.js.
//
// The leaf margin was a ring of cells that pushed outward wherever auxin had
// converged. This is the same idea closed into a surface.
//
//   1. PLACEMENT. Auxin runs over the ovary wall in up-the-gradient mode and
//      breaks into convergence points, exactly as on a meristem or a leaf
//      margin. Those points are the ovules. How many there are, and how they
//      sit, is whatever the geometry allowed — nobody counts them.
//
//   2. SWELLING. Those ovules become seeds, and seeds are auxin sources. Auxin
//      spreads through the wall and the wall grows in proportion. Where seeds
//      cluster the fruit bulges; between them it stays pinched. The lobing of
//      the fruit is a readout of where the seeds landed.
//
// Then it ripens as an autocatalytic front: the ripening signal triggers its own
// production, so it crosses the fruit as a travelling wave rather than fading in
// everywhere at once.
//
// The one simplification: growth is radial from the centre, so a fruit is always
// star-shaped about its core — which almost every real fruit is, and it removes
// any possibility of the surface folding through itself as it lobes.
// ---------------------------------------------------------------------------

public struct FruitOptions {
    public init() {}
    public var subdiv = 3            // icosphere refinement; 3 gives 642 wall cells
    public var patternFor: Float = 520  // frames spent deciding where the ovules go
    public var growFor: Float = 1500    // frames of swelling
    public var r0: Float = 0.10      // ovary radius at fertilisation
    public var seedRho: Float = 0.85 // auxin made by each seed
    public var wallMu: Float = 0.46
    public var gWall: Float = 0.00016   // baseline swelling of the whole wall
    public var gAux: Float = 0.00052    // extra swelling where seeds delivered auxin
    public var gExp: Float = 1.8     // how sharply the wall answers to auxin
    public var smooth: Float = 0.020 // the wall resists creasing (applied every step)
    public var seedThresh: Float = 1.45 // auxin over the mean needed to become an ovule
    public var ripenRate: Float = 0.022 // autocatalytic gain of the ripening front
    public var ripenDiff: Float = 0.13
    public var ripenAt: Float = 0.72 // fraction of swelling done before ripening starts
    // the wall's own chemistry while it is deciding where the seeds go
    public var T: Float = 22
    public var D: Float = 2.6
    public var b: Float = 3.0
    public var rho: Float = 0.5
    public var mu: Float = 0.34
}

public enum FruitPhase { case pattern, grow, ripe }

// A geodesic sphere: the ovary wall's cells and the edges between them.
func icosphere(_ subdiv: Int) -> (verts: [SIMD3<Float>], faces: [(Int, Int, Int)]) {
    let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
    var verts: [SIMD3<Float>] = [
        [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
        [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
        [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
    ].map { simd_normalize($0) }
    var faces: [(Int, Int, Int)] = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
        (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
        (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]
    for _ in 0..<subdiv {
        var mid = [Int: Int]()
        var nf: [(Int, Int, Int)] = []
        func midpoint(_ a: Int, _ b: Int) -> Int {
            let k = a < b ? a * 100000 + b : b * 100000 + a
            if let m = mid[k] { return m }
            let p = simd_normalize((verts[a] + verts[b]) * 0.5)
            let m = verts.count
            verts.append(p)
            mid[k] = m
            return m
        }
        for f in faces {
            let a = midpoint(f.0, f.1), b = midpoint(f.1, f.2), c = midpoint(f.2, f.0)
            nf.append((f.0, a, c)); nf.append((f.1, b, a))
            nf.append((f.2, c, b)); nf.append((a, b, c))
        }
        faces = nf
    }
    return (verts, faces)
}

public final class Fruit {
    public let o: FruitOptions
    private var rnd: Mulberry32
    private var prm: AuxinParams
    public let n: Int
    public let faces: [(Int, Int, Int)]
    public let F: CellField

    public private(set) var dir: [SIMD3<Float>]
    public private(set) var rad: [Float]
    public private(set) var pos: [SIMD3<Float>]
    public private(set) var nrm: [SIMD3<Float>]
    public private(set) var ripe: [Float]
    public private(set) var seeds: [Int] = []

    public private(set) var phase: FruitPhase = .pattern
    public private(set) var age: Float = 0
    public private(set) var ripening = false
    public private(set) var mature = false
    public private(set) var barren = false
    public private(set) var done = false

    private var g: [Float]
    private var rn: [Float]

    public init(_ base: AuxinParams, _ opts: FruitOptions = FruitOptions(), seed: UInt32 = 1) {
        o = opts
        rnd = Mulberry32(seed: seed)
        let (verts, fs) = icosphere(opts.subdiv)
        n = verts.count
        faces = fs
        dir = verts
        rad = [Float](repeating: 0, count: n)
        pos = [SIMD3<Float>](repeating: .zero, count: n)
        nrm = [SIMD3<Float>](repeating: .zero, count: n)
        ripe = [Float](repeating: 0, count: n)
        g = [Float](repeating: 0, count: n)
        rn = [Float](repeating: 0, count: n)
        var q = base
        q.T = opts.T; q.D = opts.D; q.b = opts.b; q.rho = 0; q.mu = 0
        prm = q
        F = CellField(cap: n)
        for i in 0..<n { rad[i] = opts.r0 * (0.97 + 0.06 * rnd.next()) }
        for _ in 0..<n { F.add(0, 0, 0.3 + 0.4 * rnd.next()) }
        // the wall's neighbour graph is the mesh's own edges
        var seen = Set<Int>()
        for f in fs {
            let tri = [(f.0, f.1), (f.1, f.2), (f.2, f.0)]
            for (a, b) in tri {
                let k = a < b ? a * 100000 + b : b * 100000 + a
                if seen.contains(k) { continue }
                seen.insert(k)
                F.link(min(a, b), max(a, b), 1)
            }
        }
        updatePositions()
    }

    // --- phase 1: where do the ovules go? -----------------------------------
    private func patternStep(_ dt: Float) {
        for i in 0..<n { F.rho[i] = o.rho; F.mu[i] = o.mu; F.comp[i] = 1 }
        for _ in 0..<prm.substeps { F.stepAuxin(prm, .grad) }
        age += dt
        if age < o.patternFor { return }

        var sum: Float = 0
        for i in 0..<n { sum += F.a[i] }
        let mean = sum / Float(n)
        seeds = []
        for i in 0..<n {
            if F.a[i] < mean * o.seedThresh { continue }
            let d = Int(F.deg[i]), off = i * MAXNB
            var isMax = true
            for k in 0..<d where F.a[Int(F.nbr[off + k])] > F.a[i] { isMax = false; break }
            if isMax { seeds.append(i) }
        }
        // an ovary with nothing in it does not set fruit
        if seeds.isEmpty { barren = true; mature = true; return }
        for i in 0..<n { F.a[i] = 0.05 }
        phase = .grow
        age = 0
    }

    // --- phase 2: the seeds feed the wall and the wall swells ---------------
    private func growStep(_ dt: Float) {
        for i in 0..<n { F.rho[i] = 0; F.mu[i] = o.wallMu; F.comp[i] = 1 }
        for s in seeds { F.rho[s] = o.seedRho }
        for _ in 0..<prm.substeps { F.stepAuxin(prm, .flux) }

        var sum: Float = 0
        for i in 0..<n { sum += F.a[i] }
        let mean = max(1e-4, sum / Float(n))

        for i in 0..<n {
            let drive = powf(max(0, F.a[i] / mean), o.gExp)
            g[i] = rad[i] + (o.gWall + o.gAux * drive) * dt
        }
        // the wall is a sheet, so it resists creasing between neighbours
        for i in 0..<n {
            let d = Int(F.deg[i]), off = i * MAXNB
            var s: Float = 0
            for k in 0..<d { s += g[Int(F.nbr[off + k])] }
            rad[i] = canalLerp(g[i], s / Float(max(1, d)), o.smooth)
        }
        updatePositions()

        age += dt
        if !ripening && age > o.growFor * o.ripenAt { startRipening() }
        if ripening { ripenStep(dt) }
        if age > o.growFor { phase = .ripe; mature = true }
    }

    // --- phase 3: ripening as a self-feeding wave ---------------------------
    private func startRipening() {
        ripening = true
        // it starts somewhere, and where it starts is arbitrary — in a real fruit
        // it is usually the end furthest from the stalk
        var best = 0
        var by: Float = -1e9
        for i in 0..<n {
            let y = pos[i].y + rnd.next() * 0.2
            if y > by { by = y; best = i }
        }
        ripe[best] = 0.35
    }

    private func ripenStep(_ dt: Float) {
        for i in 0..<n {
            let d = Int(F.deg[i]), off = i * MAXNB
            var lap: Float = 0
            for k in 0..<d { lap += ripe[Int(F.nbr[off + k])] - ripe[i] }
            // autocatalysis: the signal provokes its own production
            rn[i] = o.ripenRate * ripe[i] * (1 - ripe[i]) + o.ripenDiff * lap / Float(max(1, d))
        }
        for i in 0..<n { ripe[i] = canalClamp(ripe[i] + rn[i] * dt, 0, 1) }
    }

    public func step(_ dt: Float = 1) {
        if done { return }
        if mature && phase == .ripe {
            if !ripening { done = true; return }
            ripenStep(dt)
            // once the wave has crossed the whole fruit there is nothing left to do
            var s: Float = 0
            for i in 0..<n { s += ripe[i] }
            if s / Float(n) > 0.985 { done = true }
            return
        }
        if mature { return }
        if phase == .pattern { patternStep(dt) } else { growStep(dt) }
    }

    public func updatePositions() {
        for i in 0..<n { pos[i] = dir[i] * rad[i] }
        for i in 0..<n { nrm[i] = .zero }
        for f in faces {
            let a = pos[f.0], b = pos[f.1], c = pos[f.2]
            let fn = simd_cross(b - a, c - a)
            nrm[f.0] += fn; nrm[f.1] += fn; nrm[f.2] += fn
        }
        for i in 0..<n {
            let l = simd_length(nrm[i])
            nrm[i] = l > 0 ? nrm[i] / l : SIMD3<Float>(0, 1, 0)
        }
    }

    public struct Stats {
        public var phase: FruitPhase, cells: Int, seeds: Int
        public var rMin: Float, rMax: Float, rMean: Float, lobing: Float, ripe: Float
    }

    public func stats() -> Stats {
        var mn: Float = 1e9, mx: Float = -1e9, sum: Float = 0, rp: Float = 0
        for i in 0..<n {
            if rad[i] < mn { mn = rad[i] }
            if rad[i] > mx { mx = rad[i] }
            sum += rad[i]; rp += ripe[i]
        }
        let mean = sum / Float(n)
        return Stats(phase: phase, cells: n, seeds: seeds.count,
                     rMin: mn, rMax: mx, rMean: mean,
                     lobing: (mx - mn) / mean, ripe: rp / Float(n))
    }
}
