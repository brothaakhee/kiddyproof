import Foundation

// ===========================================================================
// AUXIN TRANSPORT ENGINE — port of src/10_auxin.js from
// github.com/aj-dev-smith/canalisation.
//
// One solver, two polarisation regimes, switched by local auxin concentration
// (Bayer et al. 2009; Cieslak et al. 2019): the same PIN feedback loop makes
// convergence points where auxin is low (phyllotaxis, leaf teeth) and canals
// where auxin is high (veins).
//
//   da_i/dt = rho_i - mu_i a_i
//           + sum_j [ T (P_ji phi(a_j) - P_ij phi(a_i)) + D w_ij (a_j - a_i) ]
//   phi(a)  = a / (Km + a)                       saturating carrier kinetics
//   P_ij    = p_i * q_ij / sum_k q_ik            PIN allocated over membranes
//   q_ij    = (1 - s_i) G_ij + s_i C_ij          the two regimes, blended
//     G_ij  = a_j^b / sum_k a_k^b                UP-THE-GRADIENT  (Smith 2006)
//     C_ij  = pi_ij / sum_k pi_ik                WITH-THE-FLUX    (Mitchison 1980)
//        d pi_ij/dt = alpha J^2/(1 + J^2/Jsat) - beta pi_ij
//     s_i   = a_i^h / (ath^h + a_i^h)            the concentration switch
//   dp_i/dt = rhoP a^n/(kP^n + a^n) - muP p_i    auxin up-regulates its carrier
//
// Nothing in here knows what a leaf or a stem is. Geometry decides the rest.
//
// Storage is raw pointers rather than Swift arrays: this steps a few thousand
// cells three times per frame inside the render loop, and bounds-checked array
// access in a debug build is the difference between 60fps and a slideshow.
// ===========================================================================

public let MAXNB = 8

public struct AuxinParams {
    public init() {}
    public var rho: Float = 0.60        // baseline auxin production
    public var mu: Float = 0.30         // baseline auxin turnover
    public var D: Float = 6.0           // passive diffusion across a wall
    public var T: Float = 40.0          // active transport strength
    public var Km: Float = 1.2          // Michaelis constant of the efflux carrier
    public var b: Float = 3.0           // up-the-gradient sharpness
    public var ath: Float = 0.60        // auxin level at which canalisation takes over
    public var hSwitch: Float = 2.5     // steepness of that switch — a sigmoid, not a step
    public var alpha: Float = 0.08      // flux -> PIN feedback gain
    public var beta: Float = 0.15       // PIN turnover on the flux branch
    // The feedback must stay in its quadratic regime. If pi saturates, every wall
    // of a cell ends up equal and the cell has no polarity at all — the canal is
    // the *contrast* between one wall and its neighbours, not the absolute level.
    public var Jsat: Float = 1e6
    public var piFloor: Float = 0.002   // residual PIN so a canal can always be re-routed
    public var rhoP: Float = 1.0        // PIN synthesis
    public var kP: Float = 1.6          // half-saturation of PIN synthesis by auxin
    public var nP: Float = 2.0
    public var muP: Float = 0.55        // PIN decay
    public var pMin: Float = 0.35
    // Explicit Euler is stable only while dt < 1/(2 D w deg). With D=6, w<=1 and
    // eight walls that ceiling is ~0.014, so the step is held under it and the
    // work is made up with substeps.
    public var DI: Float = 6.0          // second signal: reach is sqrt(DI/muI)
    public var muI: Float = 0.06
    public var rhoI: Float = 0.0        // > 0 switches the long-range inhibitor on
    public var kI: Float = 1.0          // inhibitor level at which competence is halved
    public var dt: Float = 0.014
    public var substeps: Int = 3
}

// 'grad' pins the tissue to up-the-gradient polarisation (a meristem), 'flux'
// pins it to canalisation (a vein network), 'auto' lets each cell decide from
// its own auxin level — which is the unified model.
public enum AuxinMode { case grad, flux, auto }

// Cell flag bits (Uint8 in the original).
public struct CellFlag {
    public static let alive: UInt8 = 1
    public static let frozen: UInt8 = 2
    public static let source: UInt8 = 4
}

// A CellField is a bag of cells plus a symmetric neighbour graph in CSR form.
// Every DIRECTED edge carries its own PIN state, which is what makes
// canalisation possible at all.
public final class CellField {
    public let cap: Int
    public var n = 0
    public var nextId: Int32 = 1

    // per cell
    public let x: UnsafeMutablePointer<Float>
    public let y: UnsafeMutablePointer<Float>
    public let a: UnsafeMutablePointer<Float>        // auxin
    public let p: UnsafeMutablePointer<Float>        // total PIN in the cell
    public let rho: UnsafeMutablePointer<Float>      // per-cell production
    public let mu: UnsafeMutablePointer<Float>       // per-cell turnover (sinks raise this)
    public let flag: UnsafeMutablePointer<UInt8>     // bit0 alive, bit1 frozen, bit2 source
    public let age: UnsafeMutablePointer<Float>
    public let id: UnsafeMutablePointer<Int32>       // stable identity across swap-removal
    public let sz: UnsafeMutablePointer<Float>       // cell area, in target-area units
    public let comp: UnsafeMutablePointer<Float>     // PIN competence (0…1) — tissue identity
    public let organ: UnsafeMutablePointer<Int32>    // id of the organ this cell joined
    public let inh: UnsafeMutablePointer<Float>      // second, slower signal made by organs
    public let aux0: UnsafeMutablePointer<Float>     // scratch
    public let aux1: UnsafeMutablePointer<Float>     // scratch

    // per directed edge (cap * MAXNB)
    public let deg: UnsafeMutablePointer<Int32>
    public let nbr: UnsafeMutablePointer<Int32>
    public let rev: UnsafeMutablePointer<Int32>      // index of the mirrored half-edge
    public let w: UnsafeMutablePointer<Float>        // wall conductance
    public let pi: UnsafeMutablePointer<Float>       // flux-mode PIN memory
    public let P: UnsafeMutablePointer<Float>        // allocated PIN, membrane i->j
    public let J: UnsafeMutablePointer<Float>        // last net flux i->j
    public let q: UnsafeMutablePointer<Float>        // scratch allocation weights

    init(cap: Int) {
        self.cap = max(1, cap)
        let c = self.cap, m = self.cap * MAXNB
        func f(_ count: Int, _ v: Float) -> UnsafeMutablePointer<Float> {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: count)
            b.initialize(repeating: v, count: count); return b
        }
        func i32(_ count: Int) -> UnsafeMutablePointer<Int32> {
            let b = UnsafeMutablePointer<Int32>.allocate(capacity: count)
            b.initialize(repeating: 0, count: count); return b
        }
        x = f(c, 0); y = f(c, 0); a = f(c, 0); p = f(c, 1)
        rho = f(c, 0); mu = f(c, 0); age = f(c, 0); sz = f(c, 1)
        comp = f(c, 1); inh = f(c, 0); aux0 = f(c, 0); aux1 = f(c, 0)
        flag = UnsafeMutablePointer<UInt8>.allocate(capacity: c)
        flag.initialize(repeating: 0, count: c)
        id = i32(c); organ = i32(c); deg = i32(c)
        nbr = i32(m); rev = i32(m)
        w = f(m, 1); pi = f(m, 0.05); P = f(m, 0); J = f(m, 0); q = f(m, 0)
    }

    deinit {
        for b in [x, y, a, p, rho, mu, age, sz, comp, inh, aux0, aux1, w, pi, P, J, q] {
            b.deallocate()
        }
        for b in [id, organ, deg, nbr, rev] { b.deallocate() }
        flag.deallocate()
    }

    @discardableResult
    public func add(_ px: Float, _ py: Float, _ av: Float = 0.1) -> Int {
        guard n < cap else { return -1 }
        let i = n; n += 1
        x[i] = px; y[i] = py; a[i] = av
        p[i] = 1; rho[i] = 0; mu[i] = 0
        flag[i] = CellFlag.alive; age[i] = 0; deg[i] = 0
        id[i] = nextId; nextId += 1
        sz[i] = 1; comp[i] = 1; organ[i] = 0; inh[i] = 0
        let o = i * MAXNB
        for k in 0..<MAXNB { pi[o + k] = 0.05; P[o + k] = 0; J[o + k] = 0 }
        return i
    }

    // swap-remove; caller must rebuild topology afterwards
    public func remove(_ i: Int) {
        n -= 1
        let last = n
        if i != last {
            x[i] = x[last]; y[i] = y[last]
            a[i] = a[last]; p[i] = p[last]
            rho[i] = rho[last]; mu[i] = mu[last]
            flag[i] = flag[last]; age[i] = age[last]
            id[i] = id[last]; sz[i] = sz[last]
            comp[i] = comp[last]; organ[i] = organ[last]
            inh[i] = inh[last]
        }
    }

    public func clearTopology() {
        deg.update(repeating: 0, count: n)
    }

    // Adds the pair (i,j) once; caller guarantees each pair is added once.
    public func link(_ i: Int, _ j: Int, _ ww: Float = 1) {
        guard deg[i] < Int32(MAXNB), deg[j] < Int32(MAXNB) else { return }
        let ei = i * MAXNB + Int(deg[i])
        let ej = j * MAXNB + Int(deg[j])
        nbr[ei] = Int32(j); w[ei] = ww; rev[ei] = Int32(ej)
        nbr[ej] = Int32(i); w[ej] = ww; rev[ej] = Int32(ei)
        deg[i] += 1; deg[j] += 1
    }

    // -----------------------------------------------------------------------
    // one explicit Euler step of the whole system
    // -----------------------------------------------------------------------
    public func stepAuxin(_ prm: AuxinParams, _ mode: AuxinMode) {
        let dt = prm.dt
        let athH = powf(prm.ath, prm.hSwitch)

        // --- 1. allocate each cell's PIN over its membranes ------------------
        for i in 0..<n {
            guard flag[i] & CellFlag.alive != 0 else { continue }
            let d = Int(deg[i]); if d == 0 { continue }
            let o = i * MAXNB
            let ai = a[i]

            // concentration switch: how canalising is this cell right now?
            let s: Float
            switch mode {
            case .grad: s = 0
            case .flux: s = 1
            case .auto: let aH = powf(ai, prm.hSwitch); s = aH / (athH + aH)
            }

            var sg: Float = 0, sc: Float = 0
            for k in 0..<d {
                let j = Int(nbr[o + k])
                let g = powf(a[j] > 0 ? a[j] : 0, prm.b)   // up-the-gradient weight
                let c = pi[o + k] + prm.piFloor            // with-the-flux weight
                q[o + k] = g                               // stash the gradient part
                sg += g; sc += c
            }
            if sg <= 1e-9 { sg = 1e-9 }
            if sc <= 1e-9 { sc = 1e-9 }

            // Competence is how *polarised* a cell's PIN can get, not how much of
            // it there is. An incompetent cell still carries auxin — it just
            // spreads its carriers evenly over every wall, so it cannot sharpen a
            // gradient into a maximum. This is the only spatial prior in the model.
            let pin = p[i]
            let uni = 1 / Float(d)
            let cmp = comp[i]
            for k in 0..<d {
                // Competence gates gradient *sensing* only. Canalisation is a
                // different feedback — a cell carrying a real flux can polarise to
                // it whatever its identity, which is why veins can cross tissue
                // that would never spontaneously form a maximum.
                var g = q[o + k] / sg
                g = uni + (g - uni) * cmp
                let c = (pi[o + k] + prm.piFloor) / sc
                P[o + k] = pin * ((1 - s) * g + s * c)
            }
        }

        // --- 2. fluxes and the auxin update ---------------------------------
        let da = aux0
        da.update(repeating: 0, count: n)
        for i in 0..<n {
            guard flag[i] & CellFlag.alive != 0 else { continue }
            let d = Int(deg[i]), o = i * MAXNB
            let ai = a[i]
            let phi_i = ai / (prm.Km + ai)
            var acc = rho[i] - mu[i] * ai
            for k in 0..<d {
                let e = o + k
                let j = Int(nbr[e])
                let aj = a[j]
                let phi_j = aj / (prm.Km + aj)
                let out = prm.T * P[e] * phi_i
                let inn = prm.T * P[Int(rev[e])] * phi_j
                let dif = prm.D * w[e] * (aj - ai)
                acc += inn - out + dif
                // Total net flux, carrier-mediated plus diffusive. The diffusive
                // part is what lets a canal nucleate at all: before any PIN is
                // polarised the only thing pointing at the sink is the
                // concentration gradient, and canalisation has to hear it.
                J[e] = out - inn - dif
            }
            da[i] = acc
        }
        for i in 0..<n {
            let fl = flag[i]
            guard fl & CellFlag.alive != 0, fl & CellFlag.frozen == 0 else { continue }
            var v = a[i] + dt * da[i]
            if v < 0 { v = 0 } else if v > 60 { v = 60 }
            a[i] = v
        }

        // --- 3. the canalisation feedback: flux begets transport capacity ----
        if mode != .grad {
            for i in 0..<n {
                guard flag[i] & CellFlag.alive != 0 else { continue }
                let d = Int(deg[i]), o = i * MAXNB
                for k in 0..<d {
                    let e = o + k
                    let jf = J[e] > 0 ? J[e] : 0
                    let drive = (jf * jf) / (1 + (jf * jf) / prm.Jsat)
                    var v = pi[e] + dt * (prm.alpha * drive - prm.beta * pi[e])
                    if v < 0 { v = 0 } else if v > 1e4 { v = 1e4 }
                    pi[e] = v
                }
            }
        }

        // --- 4. auxin up-regulates its own transporter -----------------------
        let kPn = powf(prm.kP, prm.nP)
        for i in 0..<n {
            guard flag[i] & CellFlag.alive != 0 else { continue }
            let an = powf(a[i], prm.nP)
            let prod = prm.rhoP * an / (kPn + an)
            var v = p[i] + dt * (prod - prm.muP * p[i])
            if v < prm.pMin { v = prm.pMin } else if v > 6 { v = 6 }
            p[i] = v
        }
    }

    // -----------------------------------------------------------------------
    // A SECOND SIGNAL
    //
    // In the auxin-only model the reach of an organ's inhibition is sqrt(D/mu),
    // and D and mu are the same two constants that set the spacing of the
    // pattern — you cannot lengthen the memory without coarsening the pattern.
    // This field is made by organ founder cells, diffuses with its OWN D and
    // decays with its OWN mu, and suppresses polarisation COMPETENCE rather than
    // auxin, so its length scale sqrt(DI/muI) is free and the auxin budget is
    // untouched. Cells carry it, so it advects outward with the tissue exactly
    // as the organs do.
    // -----------------------------------------------------------------------
    public func stepInhibitor(_ prm: AuxinParams) {
        let dt = prm.dt
        for i in 0..<n {
            guard flag[i] & CellFlag.alive != 0 else { aux1[i] = 0; continue }
            let d = Int(deg[i]), o = i * MAXNB
            let vi = inh[i]
            var acc = (organ[i] > 0 ? prm.rhoI : 0) - prm.muI * vi
            for k in 0..<d {
                let e = o + k
                acc += prm.DI * w[e] * (inh[Int(nbr[e])] - vi)
            }
            aux1[i] = acc
        }
        for i in 0..<n {
            var v = inh[i] + dt * aux1[i]
            if v < 0 { v = 0 } else if v > 80 { v = 80 }
            inh[i] = v
        }
    }

    // total outgoing active flux of a cell — used to size veins and draw glow
    public func fluxMagnitude(_ i: Int) -> Float {
        let d = Int(deg[i]), o = i * MAXNB
        var m: Float = 0
        for k in 0..<d { let v = J[o + k]; if v > m { m = v } }
        return m
    }
}
