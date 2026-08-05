import Foundation

// ---------------------------------------------------------------------------
// SHOOT APICAL MERISTEM — port of src/20_meristem.js.
//
// A growing sheet of cells. Cells are displaced outward by v(r) = G r, they
// divide to keep the epidermis at roughly constant density, and they leave the
// meristem at the rim. The auxin engine runs on this sheet in gradient mode.
//
// Auxin maxima appear spontaneously. Each committed maximum becomes a
// primordium, which then acts as a sink — that draining is the *only* source of
// lateral inhibition in this model. The divergence angle is never written down
// anywhere; it is measured.
// ---------------------------------------------------------------------------

// A spatial hash over the cell sheet, so relaxation and wall detection stay
// linear as the meristem divides its way up to a few thousand cells.
final class HashGrid {
    private let cell: Float
    private var head: [Int32]
    private var next: [Int32]
    private let mask: Int32 = 4095

    init(cell: Float, cap: Int) {
        self.cell = cell
        head = [Int32](repeating: -1, count: 4096)
        next = [Int32](repeating: -1, count: max(1, cap))
    }

    @inline(__always) private func key(_ cx: Int32, _ cy: Int32) -> Int {
        Int(((cx &* 73856093) ^ (cy &* 19349663)) & mask)
    }

    func build(_ x: UnsafeMutablePointer<Float>, _ y: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<head.count { head[i] = -1 }
        for i in 0..<n {
            let k = key(Int32(floor(x[i] / cell)), Int32(floor(y[i] / cell)))
            next[i] = head[k]
            head[k] = Int32(i)
        }
    }

    // calls `cb(j)` for every candidate within one cell ring of (px,py)
    @inline(__always)
    func query(_ px: Float, _ py: Float, _ cb: (Int) -> Void) {
        let cx = Int32(floor(px / cell)), cy = Int32(floor(py / cell))
        for dx in -1...1 {
            for dy in -1...1 {
                var j = head[key(cx &+ Int32(dx), cy &+ Int32(dy))]
                while j != -1 { cb(Int(j)); j = next[Int(j)] }
            }
        }
    }
}

public struct MeristemOptions {
    public init() {}
    public var R: Float = 10.0          // radius at which cells leave the meristem
    public var rCZ: Float = 2.4         // central zone: auxin-competent, organ-incompetent
    public var rOut: Float = 0          // outer competence edge (0 = none)
    public var rPZ: Float = 6.8         // beyond here auxin drains into the provasculature
    public var d0: Float = 1.0          // target cell spacing
    public var G: Float = 0.003         // relative expansion rate per frame, v(r) = G r
    public var linkR: Float = 1.62      // wall detection radius, in units of d0
    public var spotGrace: Int = 45      // frames a maximum may go missing before write-off
    public var keepFrac: Float = 0.45   // survival threshold, fraction of the birth threshold
    public var organR: Float = 1.9      // radius of tissue recruited as founder cells
    public var organDrain: Float = 0.3  // export of auxin from founder cells into the stem
    public var rimDrain: Float = 1.2
    public var czWidth: Float = 0.9     // how sharply competence switches on at the CZ edge
    public var detectA: Float = 1.7     // a maximum must stand this far above the field mean
    public var persist: Int = 8         // frames a maximum must persist before commitment
    public var mergeR: Float = 2.2      // two maxima this close are the same maximum
    public var noise: Float = 0.05      // per-cell variation in auxin production
    public var maxCells: Int = 3600
    public var detectOff = false
}

// A live auxin maximum. Reference semantics on purpose: the tracker mutates
// these in place across frames, exactly as the original does.
public final class Primordium {
    public var x: Float, y: Float, r: Float, a: Float
    public var ang: Float
    public var strength: Float = 1
    public var age: Float = 0
    public var run: Int = 1
    public var miss: Int = 0
    public var matched = true
    public var emitted = false
    public var t: Float
    public var id: Int32
    public var cells: Int = 0

    init(x: Float, y: Float, r: Float, a: Float, ang: Float, t: Float, id: Int32) {
        self.x = x; self.y = y; self.r = r; self.a = a
        self.ang = ang; self.t = t; self.id = id
    }
}

public final class Meristem {
    public var o: MeristemOptions
    private var prm: AuxinParams
    private var rnd: Mulberry32
    public let F: CellField
    private let grid: HashGrid
    public private(set) var primordia: [Primordium] = []   // live sinks inside the meristem
    public var emitted: [Primordium] = []                  // queue consumed by the plant
    public private(set) var divergence: [Float] = []        // measured angles
    private var lastAngle: Float? = nil
    public private(set) var time: Float = 0
    public private(set) var plastochron: Float = 0
    private var lastEmit: Float = 0
    public private(set) var aMean: Float = 1
    private var crowd: [Int32]
    private var nextOrganId: Int32 = 0

    public init(_ prm: AuxinParams, _ opts: MeristemOptions = MeristemOptions(), seed: UInt32 = 1) {
        o = opts
        self.prm = prm
        rnd = Mulberry32(seed: seed)
        F = CellField(cap: opts.maxCells)
        grid = HashGrid(cell: opts.d0 * opts.linkR, cap: opts.maxCells)
        crowd = [Int32](repeating: 0, count: opts.maxCells)
        seedTissue()
        rebuild()
    }

    private func seedTissue() {
        let R = o.R, d0 = o.d0
        // hexagonal-ish seeding with jitter, then let relaxation sort it out
        let dy = d0 * 0.866
        var gy = Int(-R / dy) - 1
        while Float(gy) <= R / dy + 1 {
            var gx = Int(-R / d0) - 1
            while Float(gx) <= R / d0 + 1 {
                let x = (Float(gx) + ((gy & 1) != 0 ? 0.5 : 0)) * d0 + (rnd.next() - 0.5) * d0 * 0.25
                let y = Float(gy) * dy + (rnd.next() - 0.5) * d0 * 0.25
                if (x * x + y * y).squareRoot() < R {
                    let i = F.add(x, y, 0.4 + rnd.next() * 0.9)
                    // spread cells through the division cycle so they do not
                    // divide in lockstep
                    if i >= 0 { F.sz[i] = 1 + rnd.next() * 0.85 }
                }
                gx += 1
            }
            gy += 1
        }
        for i in 0..<F.n { F.aux0[i] = 1 + (rnd.next() - 0.5) * 2 * o.noise }
    }

    // Throw away the startup transient. A shoot starts from a meristem that has
    // already settled, so the readings taken while it was settling are not part of
    // this plant's sequence.
    public func resetDivergence() {
        divergence.removeAll()
        lastAngle = nil
    }

    // per-cell production jitter, keyed to stable ids so it does not flicker
    @inline(__always) private func jitter(_ i: Int) -> Float {
        let h = (UInt32(bitPattern: F.id[i]) ^ 0x9e3779b9) &* 0x85ebca6b
        return 1 + (Float(h & 0xffff) / 65535 - 0.5) * 2 * o.noise
    }

    public func rebuild() {
        let lim = o.d0 * o.linkR, lim2 = lim * lim
        grid.build(F.x, F.y, F.n)
        F.clearTopology()
        for i in 0..<F.n {
            let xi = F.x[i], yi = F.y[i]
            grid.query(xi, yi) { j in
                if j <= i { return }
                let dx = F.x[j] - xi, dy = F.y[j] - yi
                let d2 = dx * dx + dy * dy
                if d2 < lim2 && d2 > 1e-9 {
                    // wall conductance falls off with cell separation
                    F.link(i, j, 1.0 - 0.45 * (d2.squareRoot() / lim))
                }
            }
        }
    }

    // Physical relaxation: cells push each other apart to a target spacing. The
    // last pass also records how crowded each cell is, which is what decides
    // division — measured space, not a clock, so the sheet cannot drift out of
    // balance with its own division rate.
    public func relax(_ iters: Int = 2) {
        let d0 = o.d0
        let crowdR = d0 * 1.25, crowdR2 = crowdR * crowdR
        for it in 0..<iters {
            let record = it == iters - 1
            grid.build(F.x, F.y, F.n)
            for i in 0..<F.n {
                var px: Float = 0, py: Float = 0
                var cnt: Int32 = 0
                let xi = F.x[i], yi = F.y[i]
                grid.query(xi, yi) { j in
                    if j == i { return }
                    let dx = xi - F.x[j], dy = yi - F.y[j]
                    let d2 = dx * dx + dy * dy
                    if d2 < crowdR2 { cnt += 1 }
                    let d = d2.squareRoot()
                    if d > 1e-6 && d < d0 {
                        let f = (d0 - d) / d0
                        px += (dx / d) * f; py += (dy / d) * f
                    }
                }
                F.x[i] = xi + px * 0.42 * d0
                F.y[i] = yi + py * 0.42 * d0
                if record {
                    crowd[i] = cnt
                    // remembered cell size, used only for drawing the mosaic
                    F.sz[i] = 0.9 * F.sz[i] + 0.1 * (cnt >= 6 ? 0.85 : (cnt >= 4 ? 1.0 : 1.25))
                }
            }
        }
    }

    // Cells that reach the rim have left the meristem.
    public func prune() {
        var i = F.n - 1
        while i >= 0 {
            if (F.x[i] * F.x[i] + F.y[i] * F.y[i]).squareRoot() > o.R { F.remove(i) }
            i -= 1
        }
    }

    // A cell whose neighbourhood has thinned out has, in effect, grown too
    // large: it divides. Expansion opens the gaps; division fills them.
    public func divide() {
        let n0 = F.n
        let rimGuard = o.R - o.d0 * 1.3
        var i = 0
        while i < n0 && F.n < o.maxCells - 2 {
            defer { i += 1 }
            if crowd[i] >= 5 { continue }
            let r = (F.x[i] * F.x[i] + F.y[i] * F.y[i]).squareRoot()
            // low neighbour counts at the rim are geometry, not a gap
            if r > rimGuard && crowd[i] >= 3 { continue }
            let th = rnd.next() * CANAL_TAU
            let off = 0.32 * o.d0
            let dx = cos(th) * off, dy = sin(th) * off
            let j = F.add(F.x[i] + dx, F.y[i] + dy, F.a[i])
            if j < 0 { break }
            F.x[i] -= dx; F.y[i] -= dy
            F.p[j] = F.p[i]
            F.sz[j] = F.sz[i]
            F.organ[j] = F.organ[i]   // founder-cell identity is heritable
            crowd[i] = 6; crowd[j] = 6
        }
    }

    // An organ's position is the centre of mass of its founder cells, so it
    // moves only as fast as the tissue carries it.
    public func trackOrgans() {
        var sx = [Int32: Float](), sy = [Int32: Float](), sn = [Int32: Int]()
        for i in 0..<F.n {
            let oid = F.organ[i]
            if oid == 0 { continue }
            sx[oid, default: 0] += F.x[i]
            sy[oid, default: 0] += F.y[i]
            sn[oid, default: 0] += 1
        }
        var k = primordia.count - 1
        while k >= 0 {
            defer { k -= 1 }
            let p = primordia[k]
            if !p.emitted { continue }
            guard let n = sn[p.id], n > 0 else { primordia.remove(at: k); continue }
            p.x = sx[p.id]! / Float(n); p.y = sy[p.id]! / Float(n)
            p.r = (p.x * p.x + p.y * p.y).squareRoot()
            p.cells = n
            p.matched = true; p.miss = 0
            // Once the organ has cleared the peripheral zone it has left the
            // meristem: it stops competing for the meristem's auxin and goes on
            // being a leaf somewhere else.
            if p.r > o.R * 0.97 {
                for i in 0..<F.n where F.organ[i] == p.id { F.organ[i] = 0 }
                primordia.remove(at: k)
            }
        }
    }

    public func step(_ dt: Float) {
        time += dt

        // --- tissue growth: displace every cell down the velocity field v = G r
        let g = 1 + o.G * dt
        for i in 0..<F.n { F.x[i] *= g; F.y[i] *= g; F.age[i] += dt }
        for p in primordia {
            p.x *= g; p.y *= g
            p.r = (p.x * p.x + p.y * p.y).squareRoot()
            p.age += dt
        }
        trackOrgans()

        prune()
        relax(1)
        divide()
        rebuild()

        // --- sources and sinks ------------------------------------------------
        // A primordium drains only the handful of cells it actually occupies.
        // The inhibition field that spaces the next organ is not drawn here — it
        // is the depletion halo diffusion carves around that sink, and its reach
        // is sqrt(D/mu), a real length scale of the tissue.
        let cw = o.czWidth
        for i in 0..<F.n {
            F.rho[i] = prm.rho * jitter(i)
            var m = prm.mu
            let xi = F.x[i], yi = F.y[i]
            let rr = (xi * xi + yi * yi).squareRoot()
            // PIN competence: the central zone's stem cells do not polarise the
            // way peripheral-zone cells do, so patterning is confined to the flank.
            var cmp = canalSmoothstep(o.rCZ - cw, o.rCZ + cw, rr)
            // outer edge of the competent ring: beyond it tissue is committed and
            // no longer able to found an organ
            if o.rOut > 0 { cmp *= 1 - canalSmoothstep(o.rOut - cw, o.rOut + cw, rr) }
            // where the long-range signal is strong, a cell can still carry auxin
            // but can no longer sharpen a gradient into a new maximum
            if prm.rhoI > 0 {
                let q = F.inh[i] / prm.kI
                cmp *= 1 / (1 + q * q)
            }
            F.comp[i] = cmp
            // Founder cells keep exporting auxin downward into the provasculature
            // for as long as they exist. They are anchored in the tissue, so this
            // drain travels outward with them — that is the memory which keeps the
            // pattern from re-arranging itself into a jammed lattice.
            if F.organ[i] > 0 { m += o.organDrain }
            // Below the peripheral zone the tissue is already committed: auxin is
            // pulled down into the developing provasculature. That drain is what
            // confines organ initiation to a ring, rather than a rule saying so.
            if rr > o.rPZ {
                let t = canalClamp((rr - o.rPZ) / max(1e-3, o.R - o.rPZ), 0, 1)
                m += o.rimDrain * t * t * (3 - 2 * t)
            }
            F.mu[i] = m
        }

        // --- solve -------------------------------------------------------------
        for _ in 0..<prm.substeps {
            F.stepAuxin(prm, .grad)
            if prm.rhoI > 0 { F.stepInhibitor(prm) }
        }

        if !o.detectOff { detect() }
    }

    // -----------------------------------------------------------------------
    // ORGAN INITIATION
    //
    // There is no separate "primordium" object imposed on the field. An auxin
    // maximum *is* a primordium: the up-the-gradient network around it is
    // already pumping auxin into it, and that draining is already the lateral
    // inhibition keeping the next organ away. All this does is watch the maxima,
    // give them identities as they persist, and report the angle each appeared at.
    // -----------------------------------------------------------------------
    public func detect() {
        var sum: Float = 0
        for i in 0..<F.n { sum += F.a[i] }
        aMean = F.n > 0 ? sum / Float(F.n) : 1
        // Hysteresis: it takes a strong maximum to declare a new organ, but only
        // a weak one to keep an organ you already have. Without this a maximum
        // that dips for a moment is buried and then "re-founded" as a second
        // organ at the same angle, which corrupts the sequence.
        let birthT = aMean * o.detectA
        let keepT = birthT * o.keepFrac

        // this frame's strict local maxima, in competent tissue
        var found: [(x: Float, y: Float, a: Float, r: Float)] = []
        for i in 0..<F.n {
            let ai = F.a[i]
            if ai < keepT || F.comp[i] < 0.5 { continue }
            let d = Int(F.deg[i]), off = i * MAXNB
            if d < 3 { continue }
            var isMax = true
            for k in 0..<d where F.a[Int(F.nbr[off + k])] > ai { isMax = false; break }
            if isMax {
                found.append((F.x[i], F.y[i], ai, (F.x[i] * F.x[i] + F.y[i] * F.y[i]).squareRoot()))
            }
        }

        // track them frame to frame; a spot is the same spot if it barely moved
        for p in primordia { p.matched = false }
        var fresh: [(x: Float, y: Float, a: Float, r: Float)] = []
        for f in found {
            var best: Primordium? = nil
            var bd = o.mergeR
            for p in primordia {
                if p.matched { continue }
                let d = ((p.x - f.x) * (p.x - f.x) + (p.y - f.y) * (p.y - f.y)).squareRoot()
                if d < bd { bd = d; best = p }
            }
            if let b = best {
                b.x = f.x; b.y = f.y; b.r = f.r; b.a = f.a
                b.matched = true; b.miss = 0; b.run += 1
            } else if f.a >= birthT {
                fresh.append(f)
            }
        }
        var k = primordia.count - 1
        while k >= 0 {
            defer { k -= 1 }
            let p = primordia[k]
            if p.emitted { continue }
            if !p.matched {
                p.miss += 1
                if p.miss > o.spotGrace { primordia.remove(at: k) }
            }
        }

        // a genuinely new maximum is a new organ
        for f in fresh {
            // do not found an organ inside tissue already recruited to one
            var taken = false
            for i in 0..<F.n {
                if F.organ[i] == 0 { continue }
                let dx = F.x[i] - f.x, dy = F.y[i] - f.y
                if (dx * dx + dy * dy).squareRoot() < o.organR * 1.4 { taken = true; break }
            }
            if taken { continue }
            nextOrganId += 1
            primordia.append(Primordium(x: f.x, y: f.y, r: f.r, a: f.a,
                                        ang: atan2(f.y, f.x), t: time, id: nextOrganId))
        }

        // Report an organ once its maximum has proved it is not a flicker. The
        // angle recorded is the one it was born at, not where it has drifted to.
        for p in primordia {
            if p.emitted || p.run < o.persist { continue }
            p.emitted = true
            // specify the founder cells: from here the organ is a place in the
            // tissue, not a place in the field
            for i in 0..<F.n {
                if F.organ[i] != 0 { continue }
                let dx = F.x[i] - p.x, dy = F.y[i] - p.y
                if (dx * dx + dy * dy).squareRoot() < o.organR { F.organ[i] = p.id }
            }
            emitted.append(p)
            if let la = lastAngle {
                divergence.append(angDelta(la, p.ang))
                plastochron = time - lastEmit
            }
            lastAngle = p.ang
            lastEmit = time
        }
    }

    // --- measurement, not decoration -----------------------------------------
    // Reports the angle between consecutive organs as the plant actually built
    // them. Nothing here feeds back into the simulation.
    public struct Divergence {
        public var mean: Float
        public var sd: Float
        public var n: Int
        public var lock: Float
        public var counterClockwise: Bool
    }

    public func divergenceStats(window: Int = 40) -> Divergence? {
        let raw = Array(divergence.suffix(window))
        if raw.count < 4 { return nil }
        var pos = 0
        for v in raw where v > 0 { pos += 1 }
        let sign: Float = pos >= raw.count / 2 ? 1 : -1
        let vals = raw.map { v -> Float in
            var a = sign * v * 180 / .pi
            if a < -60 { a += 360 }   // same rotation, other way round the circle
            return a
        }
        let mean = vals.reduce(0, +) / Float(vals.count)
        let sd = (vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)).squareRoot()
        let lock = Float(vals.filter { abs($0 - mean) < 20 }.count) / Float(vals.count)
        return Divergence(mean: mean, sd: sd, n: vals.count, lock: lock, counterClockwise: sign > 0)
    }

    // The way you would measure a real plant: ignore the clock, sort the organs
    // by how far they have travelled from the tip (which is their age), and read
    // the angle from one to the next around the axis.
    public func spatialDivergence() -> Divergence? {
        let ps = primordia.filter { $0.emitted }.sorted { $0.r < $1.r }
        if ps.count < 4 { return nil }
        var d: [Float] = []
        for i in 1..<ps.count { d.append(angDelta(ps[i].ang, ps[i - 1].ang)) }
        var pos = 0
        for v in d where v > 0 { pos += 1 }
        let sign: Float = pos >= d.count / 2 ? 1 : -1
        let vals = d.map { v -> Float in
            var a = sign * v * 180 / .pi
            if a < -60 { a += 360 }
            return a
        }
        let mean = vals.reduce(0, +) / Float(vals.count)
        let sd = (vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)).squareRoot()
        return Divergence(mean: mean, sd: sd, n: vals.count, lock: 0, counterClockwise: sign > 0)
    }

    // diagnostics: how spotty is the field, and at what wavelength?
    public struct PatternStats {
        public var cells: Int, mean: Float, min: Float, max: Float
        public var contrast: Float, peaks: Int, spacing: Float
    }

    public func patternStats() -> PatternStats {
        var sum: Float = 0, mx: Float = 0, mn: Float = 1e9
        for i in 0..<F.n { sum += F.a[i]; if F.a[i] > mx { mx = F.a[i] }; if F.a[i] < mn { mn = F.a[i] } }
        let mean = sum / Float(max(1, F.n))
        var peaks: [(Float, Float)] = []
        for i in 0..<F.n {
            let r = (F.x[i] * F.x[i] + F.y[i] * F.y[i]).squareRoot()
            if r > o.R * 0.9 { continue }
            let d = Int(F.deg[i]), off = i * MAXNB
            if d < 3 { continue }
            var isMax = true
            for k in 0..<d where F.a[Int(F.nbr[off + k])] >= F.a[i] { isMax = false; break }
            if isMax && F.a[i] > mean * 1.2 { peaks.append((F.x[i], F.y[i])) }
        }
        var spacing: Float = 0
        if peaks.count > 1 {
            var s: Float = 0
            for (pi, p) in peaks.enumerated() {
                var best: Float = 1e9
                for (qi, q) in peaks.enumerated() where qi != pi {
                    let d = ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1)).squareRoot()
                    if d < best { best = d }
                }
                s += best
            }
            spacing = s / Float(peaks.count)
        }
        return PatternStats(cells: F.n, mean: mean, min: mn, max: mx,
                            contrast: mx / (mean == 0 ? 1 : mean),
                            peaks: peaks.count, spacing: spacing)
    }
}
