import Foundation

// ---------------------------------------------------------------------------
// THE LEAF MARGIN — port of src/25_margin.js.
//
// The last thing in the original that was drawn rather than grown was the leaf
// silhouette — a width function. This replaces it.
//
// The margin is a chain of epidermal cells running from the petiole, around the
// tip, and back. The same auxin engine runs along that chain in up-the-gradient
// mode, so it breaks into evenly spaced convergence points on its own. Each
// convergence point drives outgrowth along the local outward normal: that is a
// tooth. Between them the margin barely moves: that is a sinus.
//
// The feedback that matters: as the leaf grows the margin gets longer, which
// makes room for more convergence points, which makes more teeth. Nobody decides
// how many lobes a leaf has. It is however many fit.
//
// Bilsborough et al. (2011) is the paper this follows.
// ---------------------------------------------------------------------------

public struct MarginOptions {
    public init() {}
    public var maxPts = 620
    public var seedPts = 17
    public var seedR: Float = 0.055
    public var dMax: Float = 0.030      // insert a cell when the margin stretches past this
    public var dMin: Float = 0.011      // merge cells that crowd closer than this
    public var baseGuard: Float = 0.10  // fraction of the chain nearest the petiole that is held
    public var g0: Float = 0.00030      // baseline outgrowth of the whole margin
    public var g1: Float = 0.00115      // extra outgrowth where auxin has converged
    public var gExp: Float = 2.2        // how sharply outgrowth answers to auxin
    public var ax: Float = 1.00         // proximodistal growth
    public var ay: Float = 0.62         // mediolateral growth — the leaf's slenderness
    public var smooth: Float = 0.16     // resistance of the margin to kinking
    public var tipBias: Float = 0.55    // extra drive toward the distal end early on
    public var mature: Float = 1400
    // the chain's own chemistry
    public var rho: Float = 0.24
    public var mu: Float = 0.30
    public var T: Float = 26
    public var D: Float = 7.0
    public var b: Float = 3.0
    public var sink: Float = 7.0
}

// A convergence point, in material (blade) coordinates.
public struct Tooth {
    public var u: Float
    public var v: Float
    public var a: Float
}

public final class Margin {
    public let o: MarginOptions
    private var rnd: Mulberry32
    private var prm: AuxinParams
    public let F: CellField
    private(set) var age: Float = 0
    private(set) var teeth: [Tooth] = []
    private(set) var mature = false

    // baked outline, valid once mature
    private(set) var length: Float = 0
    private(set) var aspect: Float = 0
    private var wl: [Float] = []
    private var wr: [Float] = []
    private let NS = 96

    private var nx: [Float]
    private var ny: [Float]

    init(_ base: AuxinParams, _ opts: MarginOptions = MarginOptions(), seed: UInt32 = 1) {
        o = opts
        rnd = Mulberry32(seed: seed)
        var q = base
        q.T = opts.T; q.D = opts.D; q.b = opts.b; q.rho = 0; q.mu = 0
        prm = q
        F = CellField(cap: opts.maxPts)
        nx = [Float](repeating: 0, count: opts.maxPts)
        ny = [Float](repeating: 0, count: opts.maxPts)
        seedChain()
    }

    private func seedChain() {
        for i in 0..<o.seedPts {
            let th = -Float.pi / 2 + Float.pi * Float(i) / Float(o.seedPts - 1)
            F.add(cos(th) * o.seedR * 1.25, sin(th) * o.seedR, 0.25 + rnd.next() * 0.25)
        }
        link()
    }

    public func link() {
        F.clearTopology()
        if F.n >= 2 { for i in 0..<(F.n - 1) { F.link(i, i + 1, 1) } }
    }

    // outward normal of a counter-clockwise chain is (dy, -dx)
    private func normalAt(_ i: Int) -> (Float, Float) {
        let n = F.n
        let a = max(0, i - 1), b = min(n - 1, i + 1)
        let dx = F.x[b] - F.x[a], dy = F.y[b] - F.y[a]
        let L = max(1e-6, (dx * dx + dy * dy).squareRoot())
        return (dy / L, -dx / L)
    }

    public func step(_ dt: Float = 1) {
        if mature { return }
        age += dt

        // --- chemistry along the chain ---------------------------------------
        let n = F.n
        guard n > 1 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += F.a[i] }
        let mean = sum / Float(max(1, n))
        for i in 0..<n {
            let s = Float(i) / Float(n - 1)
            F.rho[i] = o.rho
            F.mu[i] = o.mu
            F.comp[i] = 1
            // auxin drains out of both ends into the petiole
            let edge = min(s, 1 - s)
            if edge < 0.05 { F.mu[i] += o.sink * (1 - edge / 0.05) }
        }
        for _ in 0..<prm.substeps { F.stepAuxin(prm, .grad) }

        // --- outgrowth --------------------------------------------------------
        let early = 1 - canalSmoothstep(0, o.mature * 0.45, age)
        for i in 0..<n {
            let s = Float(i) / Float(n - 1)
            let guardW = canalSmoothstep(0, o.baseGuard, min(s, 1 - s))
            // early on the whole thing pushes distally; later it is auxin that decides
            let distal = 1 + o.tipBias * early * sin(s * .pi)
            let drive = powf(max(0, F.a[i] / max(1e-4, mean)), o.gExp)
            let rate = (o.g0 + o.g1 * drive) * guardW * distal * dt
            let (nrx, nry) = normalAt(i)
            nx[i] = nrx * rate * o.ax
            ny[i] = nry * rate * o.ay
        }
        for i in 0..<n { F.x[i] += nx[i]; F.y[i] += ny[i] }

        // --- the margin resists kinking ---------------------------------------
        let sm = o.smooth
        if n > 2 {
            for i in 1..<(n - 1) {
                nx[i] = sm * (F.x[i - 1] + F.x[i + 1] - 2 * F.x[i])
                ny[i] = sm * (F.y[i - 1] + F.y[i + 1] - 2 * F.y[i])
            }
            for i in 1..<(n - 1) { F.x[i] += nx[i]; F.y[i] += ny[i] }
        }

        resample()
        link()
        if age > o.mature { finish() }
    }

    // A growing margin needs more cells, and that lengthening is what lets new
    // convergence points appear — which is where extra teeth come from.
    private func resample() {
        var i = F.n - 2
        while i >= 0 {
            let dx = F.x[i + 1] - F.x[i], dy = F.y[i + 1] - F.y[i]
            let d = (dx * dx + dy * dy).squareRoot()
            if d > o.dMax && F.n < o.maxPts - 2 {
                insert(i, 0.5)
            } else if d < o.dMin && F.n > 24 && i > 1 && i < F.n - 3 {
                merge(i)
            }
            i -= 1
        }
    }

    private func insert(_ i: Int, _ t: Float) {
        let x = canalLerp(F.x[i], F.x[i + 1], t), y = canalLerp(F.y[i], F.y[i + 1], t)
        let a = canalLerp(F.a[i], F.a[i + 1], t), p = canalLerp(F.p[i], F.p[i + 1], t)
        let j = F.add(x, y, a)
        if j < 0 { return }
        F.p[j] = p
        // shift the tail up by one to keep the chain in order
        var k = F.n - 1
        while k > i + 1 {
            F.x[k] = F.x[k - 1]; F.y[k] = F.y[k - 1]
            F.a[k] = F.a[k - 1]; F.p[k] = F.p[k - 1]; F.id[k] = F.id[k - 1]
            k -= 1
        }
        F.x[i + 1] = x; F.y[i + 1] = y; F.a[i + 1] = a; F.p[i + 1] = p
        F.id[i + 1] = F.nextId; F.nextId += 1
    }

    private func merge(_ i: Int) {
        F.x[i] = (F.x[i] + F.x[i + 1]) * 0.5
        F.y[i] = (F.y[i] + F.y[i + 1]) * 0.5
        F.a[i] = (F.a[i] + F.a[i + 1]) * 0.5
        if F.n >= 2 {
            for k in (i + 1)..<(F.n - 1) {
                F.x[k] = F.x[k + 1]; F.y[k] = F.y[k + 1]
                F.a[k] = F.a[k + 1]; F.p[k] = F.p[k + 1]; F.id[k] = F.id[k + 1]
            }
        }
        F.n -= 1
    }

    // Freeze the outline, normalise it into blade coordinates, and hand on the
    // convergence points — each becomes a vein source, which is why a real leaf
    // has a vein running to every tooth.
    private func finish() {
        let n = F.n
        var x0: Float = 1e9, x1: Float = -1e9, ymax: Float = 1e-6
        for i in 0..<n {
            if F.x[i] < x0 { x0 = F.x[i] }
            if F.x[i] > x1 { x1 = F.x[i] }
            if abs(F.y[i]) > ymax { ymax = abs(F.y[i]) }
        }
        let L = max(1e-6, x1 - x0)
        length = L
        aspect = ymax / L

        // outline as half-widths either side of the midrib, sampled along it
        var l = [Float](repeating: 0, count: NS)
        var r = [Float](repeating: 0, count: NS)
        for i in 0..<n {
            let u = canalClamp((F.x[i] - x0) / L, 0, 1)
            let k = min(NS - 1, Int((u * Float(NS - 1)).rounded()))
            let v = F.y[i] / L
            if v < 0 { if -v > l[k] { l[k] = -v } }
            else if v > r[k] { r[k] = v }
        }
        // fill any sample the margin skipped, then relax the pair a little
        func fill(_ w: inout [Float]) {
            for k in 1..<NS where w[k] == 0 { w[k] = w[k - 1] }
            for k in stride(from: NS - 2, through: 0, by: -1) where w[k] == 0 { w[k] = w[k + 1] }
            // one light pass only — smoothing here would erase the teeth the
            // chemistry just spent its whole development making
            for k in 1..<(NS - 1) { w[k] = (w[k - 1] + 6 * w[k] + w[k + 1]) * 0.125 }
            w[0] = 0; w[NS - 1] = 0
        }
        fill(&l); fill(&r)
        wl = l; wr = r

        // convergence points: local auxin maxima along the chain
        var sum: Float = 0
        for i in 0..<n { sum += F.a[i] }
        let mean = sum / Float(n)
        teeth = []
        if n > 4 {
            for i in 2..<(n - 2) {
                if F.a[i] < mean * 1.6 { continue }
                if F.a[i] < F.a[i - 1] || F.a[i] < F.a[i + 1] { continue }
                teeth.append(Tooth(u: canalClamp((F.x[i] - x0) / L, 0, 1),
                                   v: F.y[i] / L,
                                   a: F.a[i]))
            }
        }
        mature = true
    }

    // half-width on one side of the midrib, in units of leaf length
    public func half(_ u: Float, _ sgn: Float) -> Float {
        if wl.isEmpty { return 0 }
        let f = canalClamp(u, 0, 1) * Float(NS - 1)
        let i = min(NS - 2, Int(f))
        let t = f - Float(i)
        let w = sgn < 0 ? wl : wr
        return canalLerp(w[i], w[i + 1], t)
    }
}
