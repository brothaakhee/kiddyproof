import Foundation

// ---------------------------------------------------------------------------
// THE BLADE — port of src/30_leaf.js.
//
// The same auxin engine, on a different piece of geometry, doing the other
// thing it can do.
//
// Auxin is made along the growing margin. Up-the-gradient polarisation breaks
// that margin into discrete convergence points — those are the teeth and lobes.
// Each convergence point accumulates auxin until it crosses the switch, flips to
// with-the-flux polarisation, and canalises a strand back to the petiole. That
// strand is a vein.
//
// Serration and venation are not two systems here. They are one system either
// side of a threshold, which is the claim Bayer and Cieslak make about the real
// thing.
// ---------------------------------------------------------------------------

public struct LeafOptions {
    public init() {}
    public var nu = 46                  // cells along the blade
    public var nv = 25                  // cells across the blade at its widest
    public var srcRho: Float = 1.6      // auxin made at each convergence point
    public var srcSpacing: Float = 0.055 // how close two sources may be
    public var srcEvery: Float = 14     // frames between recruiting a new source
    public var maxSources = 70
    public var interiorSrc: Float = 0.08 // chance a source lands inside the blade
    public var petioleU: Float = 0.045
    public var petioleMu: Float = 6.0   // the base of the blade is the sink
    public var bodyMu: Float = 0.045    // low turnover, so auxin reaches the sink
    public var grow: Float = 0.0022     // blade expansion per frame
    public var matureAt: Float = 900    // frames until the vein pattern is frozen
    public var veinFrac: Float = 0.40   // share of a cell's PIN on one wall to be a canal
    public var veinMax = 260            // strongest N canals are kept
    public var veinFloor: Float = 0.004 // and it must carry real traffic, not just be lopsided
    public var lobes: Float = 3.0       // marginal undulation
    public var lobeDepth: Float = 0.16
    public var fenestrate: Float = 0.0  // programmed cell death between veins (monstera holes)
    public var aspect: Float = 0.44     // width / length
    public var furl: Float = 0.42       // how tightly the immature tip is rolled
    public var laminaComp: Float = 0.12 // gradient competence inside the blade
    public var margin = MarginOptions()
}

public struct VeinSeg {
    public var x0: Float, y0: Float, x1: Float, y1: Float
    public var mag: Float               // raw traffic
    public var f: Float                 // share of the cell's polarity on this wall
    public var w: Float = 1             // drawn order, log-compressed (set in bake)
}

public final class Leaf {
    public var o: LeafOptions
    private var prm: AuxinParams
    public let seed: UInt32
    private var rnd: Mulberry32

    private(set) var age: Float = 0
    private(set) var scale: Float = 0.06   // blades start tiny and expand
    private(set) var mature = false
    private(set) var veins: [VeinSeg] = []
    private(set) var maxPi: Float = 0

    public let margin: Margin
    private(set) var built = false
    private(set) var F: CellField!
    private var index: [Int32] = []
    private var isMargin: [UInt8] = []
    private var sources: [Int] = []

    init(_ base: AuxinParams, _ opts: LeafOptions = LeafOptions(), seed: UInt32 = 1) {
        o = opts
        var q = base
        q.rho = 0; q.mu = 0
        prm = q
        self.seed = seed
        rnd = Mulberry32(seed: seed)
        // Phase one: grow the outline. Nothing about this leaf's shape exists yet.
        margin = Margin(base, opts.margin, seed: seed ^ 0x9e37)
    }

    // half-width on one side of the midrib, read off the grown margin
    public func wSide(_ u: Float, _ sgn: Float) -> Float {
        margin.mature ? margin.half(u, sgn) : 0
    }

    // The silhouette is no longer a formula. It is whatever the margin grew.
    public func widthAt(_ u: Float) -> Float {
        if !margin.mature { return 0 }
        if u <= 0 || u >= 1 { return 0 }
        return max(margin.half(u, -1), margin.half(u, 1))
    }

    private func build() {
        let field = CellField(cap: o.nu * o.nv + 8)
        F = field
        index = [Int32](repeating: -1, count: o.nu * o.nv)
        let du = 1 / Float(o.nu - 1)
        let dv = 1 / Float(o.nv - 1)
        for r in 0..<o.nu {
            let u = Float(r) * du
            // The lamina has to be cut to the SAME outline the blade is drawn
            // with. The two halves of the margin patterned independently, so using
            // one half-width for both sides leaves tissue — and veins — hanging
            // outside the leaf on whichever side came out narrower.
            let hwL = wSide(u, -1), hwR = wSide(u, 1)
            for c in 0..<o.nv {
                // triangular lattice: alternate rows are offset by half a cell
                let v = ((Float(c) + ((r & 1) != 0 ? 0.5 : 0)) * dv - 0.5) * 2
                let yy = v * o.aspect
                if abs(yy) > (yy < 0 ? hwL : hwR) { continue }
                // jitter so canals cannot snap to the lattice axes
                let jx = (rnd.next() - 0.5) * du * 0.45
                let jy = (rnd.next() - 0.5) * dv * 0.45
                let i = field.add(u + jx, v * o.aspect + jy, 0.05)
                if i < 0 { continue }
                index[r * o.nv + c] = Int32(i)
                field.comp[i] = 1
            }
        }
        linkLattice()
        classify()
    }

    private func linkLattice() {
        func at(_ r: Int, _ c: Int) -> Int {
            (r < 0 || r >= o.nu || c < 0 || c >= o.nv) ? -1 : Int(index[r * o.nv + c])
        }
        for r in 0..<o.nu {
            for c in 0..<o.nv {
                let i = at(r, c)
                if i < 0 { continue }
                let odd = (r & 1) != 0 ? 1 : 0
                for j in [at(r, c + 1), at(r + 1, c - 1 + odd), at(r + 1, c + odd)] {
                    if j < 0 || j <= i { continue }
                    let dx = F.x[j] - F.x[i], dy = F.y[j] - F.y[i]
                    let d = max(1e-4, (dx * dx + dy * dy).squareRoot())
                    F.link(i, j, canalClamp(0.024 / d, 0.25, 1.0))
                }
            }
        }
    }

    // Who makes auxin and who drains it. Discrete sources appear near the margin
    // as the blade expands — these stand for the convergence points that mark
    // future teeth and hydathodes. The petiole is the one sink. Everything
    // between them is undifferentiated blade.
    private func classify() {
        isMargin = [UInt8](repeating: 0, count: F.n)
        sources = []
        for i in 0..<F.n {
            let u = F.x[i]
            let hw = wSide(u, F.y[i] < 0 ? -1 : 1)
            let edge = hw - abs(F.y[i])
            isMargin[i] = (edge < 0.055 || u > 0.94) ? 1 : 0
            F.rho[i] = 0
            F.mu[i] = o.bodyMu
            F.comp[i] = 1
            if u < o.petioleU { F.mu[i] = o.petioleMu; isMargin[i] = 0 }
        }
        // every convergence point the margin made becomes a vein source, which is
        // why a real leaf has a strand running out to every tooth
        for t in margin.teeth {
            var best = -1
            var bd: Float = 1e9
            for i in 0..<F.n {
                if F.rho[i] > 0 { continue }
                let dx = F.x[i] - t.u, dy = F.y[i] - t.v
                let d = (dx * dx + dy * dy).squareRoot()
                if d < bd { bd = d; best = i }
            }
            if best >= 0 && bd < 0.12 { F.rho[best] = o.srcRho; sources.append(best) }
        }
    }

    // Add one source where the blade is emptiest — new tissue is what makes room
    // for a new convergence point, so the pattern refines as the leaf expands.
    @discardableResult
    private func addSource() -> Bool {
        var best = -1
        var bestD: Float = -1
        for i in 0..<F.n {
            if F.x[i] < 0.10 || F.rho[i] > 0 { continue }
            // sources sit at or near the margin, as hydathodes do
            if isMargin[i] == 0 && rnd.next() > o.interiorSrc { continue }
            var d: Float = 9
            for s in sources {
                let dx = F.x[i] - F.x[s], dy = F.y[i] - F.y[s]
                let dd = (dx * dx + dy * dy).squareRoot()
                if dd < d { d = dd }
            }
            d *= 0.75 + 0.5 * rnd.next()   // a little disorder, as in real leaves
            if d > bestD { bestD = d; best = i }
        }
        if best < 0 || bestD < o.srcSpacing { return false }
        F.rho[best] = o.srcRho
        sources.append(best)
        return true
    }

    public func step(_ dt: Float = 1) {
        if mature { return }
        if !built {
            margin.step(dt)
            if margin.mature {
                o.aspect = max(0.12, margin.aspect)
                build()
                built = true
            }
            return
        }
        age += dt
        scale = min(1, scale + o.grow * dt)
        // the blade keeps recruiting sources while it is still expanding
        if age.truncatingRemainder(dividingBy: o.srcEvery) < dt && sources.count < o.maxSources {
            addSource()
        }
        for _ in 0..<prm.substeps { F.stepAuxin(prm, .flux) }
        if age > o.matureAt { bake() }
    }

    // Freeze the vein network into drawable geometry. After this the leaf costs
    // nothing per frame, which is what lets a whole plant stay interactive.
    public func bake() {
        guard let F = F else { return }
        var segs: [VeinSeg] = []
        // A canal is a cell that has committed most of its transport to ONE wall.
        // So an edge counts as a vein by its SHARE of the cell's polarity, not by
        // its absolute PIN — otherwise only the trunk, where all the flux funnels,
        // ever clears the bar.
        var frac = [Float](repeating: 0, count: F.n * MAXNB)
        for i in 0..<F.n {
            let d = Int(F.deg[i]), off = i * MAXNB
            var tot: Float = 0
            for k in 0..<d { tot += F.pi[off + k] }
            if tot <= 1e-9 { continue }
            for k in 0..<d { frac[off + k] = F.pi[off + k] / tot }
        }
        var mp: Float = 1e-9
        for i in 0..<(F.n * MAXNB) where F.pi[i] > mp { mp = F.pi[i] }
        for i in 0..<F.n {
            let d = Int(F.deg[i]), off = i * MAXNB
            for k in 0..<d {
                let e = off + k, j = Int(F.nbr[e])
                if j <= i { continue }
                let f = max(frac[e], frac[Int(F.rev[e])])
                let mag = max(F.pi[e], F.pi[Int(F.rev[e])])
                if f < o.veinFrac || mag < mp * o.veinFloor { continue }
                segs.append(VeinSeg(x0: F.x[i], y0: F.y[i], x1: F.x[j], y1: F.y[j],
                                    mag: mag, f: f))
            }
        }
        // Keep the network that carries the traffic. Drawing every lopsided wall
        // turns a leaf into a solid sheet of light; the hierarchy is the point.
        segs.sort { $0.mag > $1.mag }
        if segs.count > o.veinMax { segs = Array(segs.prefix(o.veinMax)) }
        // Order of a vein: how much traffic it carries, log-compressed — traffic
        // spans three orders of magnitude across a blade, and vein calibre goes
        // like its logarithm (the same Murray's-law reasoning as the stem taper).
        //
        // Normalise against the range the SURVIVING veins actually occupy, not
        // against maxPi: maxPi is the maximum over every wall in the tissue,
        // including walls that never became veins, so dividing by it leaves the
        // bottom of the 0…1 range unreachable and squashes a genuine 15x
        // hierarchy into about 1.5x of drawn width. See the repo's TUNING.md.
        var lo: Float = .infinity, hi: Float = 0
        for s in segs { if s.mag < lo { lo = s.mag }; if s.mag > hi { hi = s.mag } }
        let l0 = log(1 + lo), l1 = log(1 + hi)
        let span = l1 - l0
        for i in segs.indices {
            segs[i].w = span > 1e-6 ? canalClamp((log(1 + segs[i].mag) - l0) / span, 0, 1) : 1
        }
        veins = segs
        maxPi = mp
        mature = true
    }

    // Distance from a blade point to the nearest vein — drives fenestration and
    // the way light pools around the vasculature. Computed once, at maturity.
    @discardableResult
    public func veinDistanceField(_ res: Int = 40) -> [Float] {
        var fld = [Float](repeating: 9, count: res * res)
        for a in 0..<res {
            for b in 0..<res {
                let u = Float(a) / Float(res - 1)
                let v = (Float(b) / Float(res - 1) - 0.5) * 2 * o.aspect
                var best: Float = 9
                for s in veins {
                    let dx = s.x1 - s.x0, dy = s.y1 - s.y0
                    let L2 = max(1e-6, dx * dx + dy * dy)
                    var t = ((u - s.x0) * dx + (v - s.y0) * dy) / L2
                    t = t < 0 ? 0 : (t > 1 ? 1 : t)
                    let px = s.x0 + dx * t - u, py = s.y0 + dy * t - v
                    let d = (px * px + py * py).squareRoot()
                    if d < best { best = d }
                }
                fld[a * res + b] = best
            }
        }
        vdf = fld; vdfRes = res
        return fld
    }
    public private(set) var vdf: [Float] = []
    public private(set) var vdfRes = 0

    public struct Stats { public var cells: Int; public var aMean: Float; public var aMax: Float; public var maxPi: Float; public var veinEdges: Int }

    public func stats() -> Stats {
        guard let F = F, F.n > 0 else { return Stats(cells: 0, aMean: 0, aMax: 0, maxPi: 0, veinEdges: 0) }
        var mx: Float = 0, sum: Float = 0, veinEdges = 0, mp: Float = 0
        for i in 0..<F.n { sum += F.a[i]; if F.a[i] > mx { mx = F.a[i] } }
        for i in 0..<F.n {
            let d = Int(F.deg[i]), off = i * MAXNB
            for k in 0..<d where F.pi[off + k] > mp { mp = F.pi[off + k] }
        }
        for i in 0..<F.n {
            let d = Int(F.deg[i]), off = i * MAXNB
            for k in 0..<d where Int(F.nbr[off + k]) > i && F.pi[off + k] > mp * 0.05 { veinEdges += 1 }
        }
        return Stats(cells: F.n, aMean: sum / Float(F.n), aMax: mx, maxPi: mp, veinEdges: veinEdges)
    }
}
