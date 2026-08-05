import Foundation
import simd

// ---------------------------------------------------------------------------
// THE ORGANISM — port of src/40_plant.js.
//
// The meristem decides where organs go and when. This file only has to believe
// it. Nothing here invents an angle, a spacing or a branching rule — it reads
// them off the simulation and builds a body around them.
//
// NOT ported: src/38_shoot.js (Vasculature). It ships `enabled: false` in the
// reference and its own JOURNAL records it as a falsified experiment — it could
// not derive shed order from transport, so senescence is the stated rule below.
// Running it would add cost for a path the original does not take either.
// ---------------------------------------------------------------------------

public struct Frame {
    public var o = SIMD3<Float>(0, 0, 0)
    public var x = SIMD3<Float>(1, 0, 0)   // the petiole direction
    public var y = SIMD3<Float>(0, 1, 0)   // blade normal
    public var z = SIMD3<Float>(0, 0, 1)   // blade sideways
    public init() {}
}

// A frond hanging off one node of an axis.
public final class Organ {
    public var node: Int
    public var angle: Float
    public var leaf: Leaf?
    public var age: Float = 0
    var rnd: Mulberry32
    public var len: Float = 0
    public var maxLen: Float = 0
    public var droop: Float = 0
    public var tilt: Float = 0
    public var frame = Frame()
    public var seed: UInt32
    public var roll: Float = 0
    public var lift: Float = 0
    public var leafAt: Float = 0
    public var birthLen: Float = 0
    public var dev: Float = 0
    public var radius: Float = 0
    public var branched = false
    // floral identity
    public var q: Float = 0
    public var floral = false
    public var petal = false
    public var droopScale: Float = 1
    // senescence
    public var sen: Float = 0
    public var shed = false
    public var shedAt: Float = 0

    init(node: Int, angle: Float, leaf: Leaf?, seed: UInt32) {
        self.node = node; self.angle = angle; self.leaf = leaf; self.seed = seed
        rnd = Mulberry32(seed: seed)
    }
}

public final class Axis {
    unowned let plant: Plant
    public let gen: Int
    let seed: UInt32
    private var rnd: Mulberry32
    public private(set) var pts: [SIMD3<Float>]
    public private(set) var radii: [Float]
    public var dir: SIMD3<Float>
    public private(set) var organs: [Organ] = []
    public private(set) var alive = true
    public private(set) var arrested = false
    public private(set) var length: Float = 0
    public private(set) var meristem: Meristem?
    public private(set) var age: Float = 0
    private var lastOrganLen: Float = -1e9
    private var lastOrganAt: Float = 0
    public private(set) var floral = false
    public private(set) var pedicel = false
    // 0…1, how much light this growing point has just absorbed
    public internal(set) var vigour: Float = 0
    public private(set) var fruit: Fruit?
    private var floralCount = 0
    private var lastFloralAt: Float = 0
    private var floralR0: Float = 0

    // scratch, reused every frame
    private var oldArc: [Float] = [], newArc: [Float] = [], segL: [Float] = []
    private var dirs: [SIMD3<Float>] = []
    private var arc: [Float] = [], tanv: [SIMD3<Float>] = [], fu: [SIMD3<Float>] = []
    private var bl: [Float] = []

    init(plant: Plant, base: SIMD3<Float>, dir d: SIMD3<Float>, gen: Int, seed: UInt32) {
        self.plant = plant
        self.gen = gen
        self.seed = seed
        rnd = Mulberry32(seed: seed)
        pts = [base]
        radii = [0.02]
        dir = simd_normalize(d)
        var mo = plant.mo
        // a lateral shoot has a smaller growing point than the leader, which is
        // both true of real plants and considerably cheaper
        if gen > 0 { mo.R *= 0.78; mo.rCZ *= 0.9; mo.rPZ *= 0.82 }
        let m = Meristem(plant.prm, mo, seed: seed)
        // A shoot does not start from a randomised sheet of cells — it starts
        // from a meristem that has already settled. Run it forward and throw the
        // startup transient away, or the plant is born wearing a burst of organs.
        let warm = gen == 0 ? 220 : 90
        for _ in 0..<warm { m.step(1) }
        m.emitted.removeAll()
        m.resetDivergence()
        meristem = m
    }

    public func tipPos() -> SIMD3<Float> { pts[pts.count - 1] }

    func step(_ dt: Float, _ sp: SpeciesOptions) {
        age += dt
        if !alive {
            // an arrested shoot still fills out the organs it already made
            for org in organs {
                org.age += dt
                let f2 = canalSmoothstep(0, sp.organGrow, org.age)
                org.dev = f2
                org.len = org.maxLen * (0.04 + 0.96 * f2)
                org.droop = sp.droop * canalSmoothstep(0, sp.organGrow * 1.7, org.age)
                if org.leaf == nil {
                    org.leaf = org.petal ? plant.leaves.requestPetal(org.seed)
                                         : plant.leaves.request(org.seed)
                    if org.leaf != nil { org.leafAt = org.age }
                }
            }
            updateRadii(sp)
            return
        }
        guard let m = meristem else { return }
        m.step(dt)

        // --- elongate ---------------------------------------------------------
        // Light landing on a shoot is spent by that shoot. `vigour` decays, so a
        // burst reads as a surge in the tip that caught it rather than a global
        // speed change nobody can point at.
        vigour = max(0, vigour - dt / 260)
        let rate = sp.elongation * (gen == 0 ? 1 : 0.72) * (floral ? 0.22 : 1)
                 * (1 + vigour * 1.8)
        // tropism: up, plus a slow drift that gives the axis its character
        var want = SIMD3<Float>(0, 1, 0)
        let t = age * 0.004 + Float(seed)
        want.x += sin(t) * sp.wander
        want.z += cos(t * 1.31) * sp.wander
        // circumnutation — the slow helical search a real growing tip performs
        let nu = age * sp.nutation + Float(seed) * 0.7
        want.x += cos(nu) * sp.nutAmp
        want.z += sin(nu) * sp.nutAmp
        // PHOTOTROPISM. A shoot leans toward its light, and in this scene the
        // light is wherever the child is pointing — so the plant grows toward
        // the cursor. This is added to the same `want` vector the upward bias
        // and the circumnutation already share, so it composes with them
        // instead of overriding them: the tip still searches and still knows
        // which way is up, it just favours one side while it does.
        if let sun = plant.sun, plant.sunPull > 0 {
            let toLight = sun - tipPos()
            let l = simd_length(toLight)
            if l > 1e-3 { want += (toLight / l) * plant.sunPull }
        }
        want = simd_normalize(want)
        dir = simd_normalize(simd_mix(dir, want, SIMD3<Float>(repeating: canalClamp(sp.tropism * dt, 0, 1))))

        elongate(dt, sp)

        let seg = rate * dt
        length += seg
        let last = pts[pts.count - 1]
        let np = last + dir * seg
        // resample: keep one point per internode-ish distance
        if pts.count > 1 && simd_length(np - pts[pts.count - 2]) < sp.segLen {
            pts[pts.count - 1] = np
        } else {
            pts.append(np)
            radii.append(0.02)
            if pts.count > 900 { pts.removeFirst(); radii.removeFirst() }
        }

        // Florigen is made in the leaves and reaches every growing point, so it is
        // the PLANT that becomes competent to flower, not one shoot. So WHEN a
        // specimen flowers is a consequence of how much leaf it managed to build,
        // not a number in a table.
        if sp.florigenRate > 0 && !floral {
            var area: Float = 0
            for org in organs { area += org.dev * org.len * org.len }
            plant.florigen += (area / (sp.organLen * sp.organLen + 1e-6)) * sp.florigenRate * dt
            if plant.florigen > sp.florigenThresh && gen == 0 {
                plant.floweredAt = plant.vegOrganCount()
                goFloral(sp)
            }
        }
        // A determinate shoot: once it has made its complement of organs the apex
        // arrests. The specimen finishes instead of growing off the top of the
        // frame forever — and the meristem stops costing anything.
        let budgetLeft = sp.organBudget - plant.vegOrganCount()
        if !floral && (organs.count >= sp.maxOrgans || budgetLeft <= 0 || apexStalled(sp)) {
            alive = false; arrested = true
            retireMeristem()
        }

        // --- harvest whatever the meristem decided ----------------------------
        while !m.emitted.isEmpty && fruit == nil {
            let prim = m.emitted.removeFirst()
            if organs.count >= sp.maxOrgans { break }
            // two organs cannot share an internode, however fast the tip patterns
            let mi = floral ? sp.minInternode * 0.10 : sp.minInternode
            if length - lastOrganLen < mi { continue }
            lastOrganLen = length
            addOrgan(prim)
        }

        // A determinate apex ends one of two ways: it hits the species' ceiling,
        // or it runs out of itself.
        if floral && fruit == nil && (floralCount >= sp.floralOrgans || apexSpent(sp)) {
            setFruit(sp)
        }

        // --- organs mature -----------------------------------------------------
        for org in organs {
            org.age += dt
            let f = canalSmoothstep(0, sp.organGrow, org.age)
            org.dev = f
            org.len = org.maxLen * (0.04 + 0.96 * f)
            org.droop = sp.droop * canalSmoothstep(0, sp.organGrow * 1.7, org.age)
            if org.leaf == nil {
                org.leaf = org.petal ? plant.leaves.requestPetal(org.seed)
                                     : plant.leaves.request(org.seed)
                if org.leaf != nil { org.leafAt = org.age }
            }
        }

        // --- branching: an axillary bud escapes once the apex is far enough away
        if sp.branching > 0 && plant.axes.count < sp.maxAxes && gen < sp.maxGen {
            for org in organs {
                if org.branched || org.age < sp.budRelease { continue }
                // the apex suppresses buds below it; that suppression falls off
                // with distance, which is what apical dominance actually looks like
                let d = simd_length(tipPos() - org.frame.o)
                let suppressed = exp(-d / sp.dominance)
                if suppressed > sp.branching { continue }
                if rnd.next() > 0.35 { org.branched = true; continue }
                org.branched = true
                let bd = simd_normalize(simd_mix(org.frame.x, SIMD3<Float>(0, 1, 0),
                                                 SIMD3<Float>(repeating: 0.45)))
                // competent plant → this bud makes a flower rather than a branch
                let flowering = plant.florigen > sp.florigenThresh
                if flowering && plant.flowerCount() >= sp.maxFlowers { break }
                let ax = plant.addAxis(base: org.frame.o, dir: bd, gen: gen + 1)
                if flowering { ax.goFloral(sp, immediate: true) }
                break
            }
        }
        updateRadii(sp)
    }

    // The floral meristem is a smaller, faster version of the same tissue.
    // Organs crowd together instead of spiralling apart, which is what a flower is.
    func goFloral(_ sp: SpeciesOptions, immediate: Bool = false) {
        floral = true
        pedicel = immediate       // a bud that became a flower sits on a stalk
        guard let m = meristem else { return }
        // Conversion is a loss of stem-cell renewal, not of size: the central zone
        // stops being maintained, so most of the dome becomes competent at once and
        // organs crowd in instead of spiralling apart. The dome keeps the radius it
        // had — everything the flower will make has to fit in it, and from here
        // nothing replaces what gets used.
        m.o.rCZ *= sp.floralCZ
        m.o.G *= 2.3
        // The scale the apex had when it converted. Organ identity is read against
        // this fixed reference, not the apex's current size — a meristem that
        // contracts self-similarly reports the same q forever measured against itself.
        floralR0 = m.o.rPZ
        lastFloralAt = age
        m.emitted.removeAll()
    }

    // A determinate apex has no renewing stem-cell pool. Every organ it founds
    // recruits a patch of tissue that is never replaced, so the competent flank
    // contracts by the area it just lost and the next organ has nowhere to be
    // founded but further in. That contraction is the whole of floral organ
    // identity here — nothing anywhere names a whorl or counts one.
    private func consumeApex() {
        guard let m = meristem else { return }
        let comp = Float.pi * (m.o.rPZ * m.o.rPZ - m.o.rCZ * m.o.rCZ)
        let lost = Float.pi * m.o.organR * m.o.organR
        let k = canalClamp(1 - lost / max(1e-3, comp), 0.35, 1).squareRoot()
        m.o.R *= k; m.o.rPZ *= k; m.o.rCZ *= k
    }

    // How you notice something has stopped, not a statement about what it should
    // be — the same shape of rule as the meristem's `spotGrace`.
    private func apexStalled(_ sp: SpeciesOptions) -> Bool {
        age - lastOrganAt > sp.vegGrace
    }

    private func apexSpent(_ sp: SpeciesOptions) -> Bool {
        guard let m = meristem else { return true }
        // no room left: the competent flank is narrower than one founder patch
        if m.o.rPZ - m.o.rCZ < m.o.organR { return true }
        // room, but no organ in far longer than the last one took
        return age - lastFloralAt > sp.floralGrace
    }

    // A growing point is about to be discarded. It is the only thing that ever
    // measured the divergence angle, so hand that reading to the organism before
    // dropping it — keeping the fullest one, not the last to retire.
    private func retireMeristem() {
        if let m = meristem {
            let st = m.divergenceStats(window: 24)
            if let s = st, plant.lastDiv == nil || s.n >= plant.lastDiv!.n { plant.lastDiv = s }
            plant.lastCells = m.F.n
            plant.lastPlastochron = m.plastochron
        }
        meristem = nil
    }

    // The apex has spent itself. What is left becomes an ovary.
    private func setFruit(_ sp: SpeciesOptions) {
        let s = UInt32(truncatingIfNeeded: Int(seed) &* 2654435761 &+ 7919)
        fruit = Fruit(plant.prm, sp.fruitOpts, seed: s)
        alive = false
        arrested = true
        retireMeristem()
    }

    private func addOrgan(_ prim: Primordium) {
        let sp = plant.sp
        let s = UInt32(truncatingIfNeeded: Int(seed) &* 7919 &+ organs.count &* 104729)
        let leaf = plant.leaves.request(s)
        let org = Organ(node: pts.count - 1, angle: prim.ang, leaf: leaf, seed: s)
        org.maxLen = sp.organLen * (0.75 + 0.5 * org.rnd.next()) * (gen == 0 ? 1 : 0.7)
        org.tilt = sp.organTilt * (0.8 + 0.4 * org.rnd.next())
        // a little roll and pitch scatter so neighbouring blades do not lie in the
        // same plane and saw through each other
        org.roll = (org.rnd.next() - 0.5) * sp.organRoll
        org.lift = (org.rnd.next() - 0.5) * 0.22
        org.birthLen = length
        lastOrganAt = age
        if floral {
            floralCount += 1
            // identity read off the radius the organ was founded at: the floral
            // meristem shrinks as it consumes itself, so later organs start
            // further in, and that gradient is the only thing distinguishing them
            let r0 = floralR0 > 0 ? floralR0 : (meristem?.o.rPZ ?? 1)
            org.q = canalClamp(1 - (prim.r / max(1e-3, r0)), 0, 1)
            org.floral = true
            // the outer ones are petals — leaves whose margin was told to grow
            // broad and smooth instead of long and toothed
            org.petal = org.q < sp.petalQ
            org.leaf = nil
            org.maxLen = sp.organLen * (org.petal ? 0.30 : 0.13) * (0.82 + 0.36 * org.rnd.next())
            org.tilt = org.petal ? sp.petalTilt * (0.9 + 0.2 * org.rnd.next())
                                 : sp.organTilt * 0.30
            org.roll *= 0.25
            org.droopScale = org.petal ? 0.12 : 0.05
            lastFloralAt = age
            consumeApex()
        }
        organs.append(org)
    }

    // A shoot does not only grow at its tip. The tissue just below the apex goes
    // on stretching for a while after it is laid down, which is what pushes leaves
    // apart as the plant develops. Segments are lengthened in place and every
    // organ is carried along by the tissue it was born in.
    private func elongate(_ dt: Float, _ sp: SpeciesOptions) {
        let n = pts.count
        if n < 3 || sp.internode <= 0 { return }
        if oldArc.count < n { oldArc = [Float](repeating: 0, count: n) }
        if newArc.count < n { newArc = [Float](repeating: 0, count: n) }
        if segL.count < n { segL = [Float](repeating: 0, count: n) }
        if dirs.count < n { dirs = [SIMD3<Float>](repeating: .zero, count: n) }

        oldArc[0] = 0
        for i in 0..<(n - 1) {
            let d = pts[i + 1] - pts[i]
            let L = max(1e-6, simd_length(d))
            segL[i] = L
            dirs[i] = d / L
            oldArc[i + 1] = oldArc[i] + L
        }
        let total = oldArc[n - 1]

        newArc[0] = 0
        for i in 0..<(n - 1) {
            let belowTip = total - oldArc[i]
            let e = sp.internode * exp(-belowTip / sp.internodeSpan)
            let L = segL[i] * (1 + e * dt)
            newArc[i + 1] = newArc[i] + L
            pts[i + 1] = pts[i] + dirs[i] * L
        }
        length = newArc[n - 1]

        for org in organs {
            let L = org.birthLen
            if L >= total { org.birthLen = length; continue }
            var lo = 0, hi = n - 1
            while hi - lo > 1 { let m = (lo + hi) >> 1; if oldArc[m] <= L { lo = m } else { hi = m } }
            let t = (L - oldArc[lo]) / max(1e-6, oldArc[hi] - oldArc[lo])
            org.birthLen = newArc[lo] + t * (newArc[hi] - newArc[lo])
        }
    }

    // Murray's law: a stem is exactly as thick as the traffic it carries. Organs
    // are placed by ARC LENGTH along the axis, interpolated between stem points,
    // using a frame parallel-transported up the shoot — indexing the nearest
    // vertex instead made every organ hop sideways whenever the stem gained a point.
    private func updateRadii(_ sp: SpeciesOptions) {
        let n = pts.count
        if n < 2 { radii[0] = sp.tipRadius; return }
        if arc.count < n { arc = [Float](repeating: 0, count: n) }
        if tanv.count < n { tanv = [SIMD3<Float>](repeating: .zero, count: n) }
        if fu.count < n { fu = [SIMD3<Float>](repeating: .zero, count: n) }

        arc[0] = 0
        for i in 1..<n { arc[i] = arc[i - 1] + simd_length(pts[i] - pts[i - 1]) }
        for i in 0..<n {
            var d = pts[min(n - 1, i + 1)] - pts[max(0, i - 1)]
            if simd_length(d) < 1e-7 { d = SIMD3<Float>(0, 1, 0) }
            tanv[i] = simd_normalize(d)
        }
        // transport one perpendicular up the axis so organ angles stay put
        let ax = SIMD3<Float>(1, 0, 0), ay = SIMD3<Float>(0, 1, 0)
        fu[0] = simd_normalize(simd_cross(abs(tanv[0].y) > 0.9 ? ax : ay, tanv[0]))
        for i in 1..<n {
            let d = simd_dot(fu[i - 1], tanv[i])
            let v = fu[i - 1] - tanv[i] * d
            if simd_length(v) < 1e-5 {
                fu[i] = simd_normalize(simd_cross(abs(tanv[i].y) > 0.9 ? ax : ay, tanv[i]))
            } else {
                fu[i] = simd_normalize(v)
            }
        }

        let total = arc[n - 1]

        // Thickness as a smooth function of arc length: the traffic from organs
        // above, plus steady secondary thickening with distance below the tip.
        bl.removeAll(keepingCapacity: true)
        for org in organs { bl.append(org.birthLen) }
        bl.sort()
        var above = bl.count, k = 0
        for i in 0..<n {
            while k < bl.count && bl[k] <= arc[i] { k += 1; above -= 1 }
            let below = total - arc[i]
            radii[i] = powf(powf(sp.tipRadius, 3) + sp.organFlow * Float(above)
                            + sp.thicken * below + (fruit != nil ? sp.fruitFlow : 0),
                            1.0 / 3.0) * sp.radiusScale
        }

        for org in organs {
            let L = canalClamp(org.birthLen, 0, total)
            var lo = 0, hi = n - 1
            while hi - lo > 1 { let m = (lo + hi) >> 1; if arc[m] <= L { lo = m } else { hi = m } }
            let seg = max(1e-6, arc[hi] - arc[lo])
            let t = canalClamp((L - arc[lo]) / seg, 0, 1)
            let tv = SIMD3<Float>(repeating: t)
            let p = simd_mix(pts[lo], pts[hi], tv)
            let axs = simd_normalize(simd_mix(tanv[lo], tanv[hi], tv))
            var u = simd_mix(fu[lo], fu[hi], tv)
            u = simd_normalize(u - axs * simd_dot(u, axs))

            let dirRot = rotAxis(u, axs, org.angle)
            // pitch away from the axis, then let it settle under its own weight:
            // young organs are pressed against the axis and swing out as they fill
            let tl = org.tilt * (0.12 + 0.88 * canalSmoothstep(0.04, 0.72, org.dev))
            var zd = simd_mix(axs, dirRot, SIMD3<Float>(repeating: tl))
            zd.y -= (org.droop * org.droopScale - org.lift) * org.dev
            zd = simd_normalize(zd)

            org.frame.o = p
            org.frame.x = zd
            var side = simd_cross(zd, axs)
            if simd_length(side) < 0.1 { side = SIMD3<Float>(1, 0, 0) } else { side = simd_normalize(side) }
            var nrm = simd_normalize(simd_cross(side, zd))
            // roll the blade about its own petiole
            let cr = cos(org.roll), sr = sin(org.roll)
            let s2 = side * cr + nrm * sr
            nrm = -side * sr + nrm * cr
            org.frame.z = s2
            org.frame.y = nrm
            org.radius = radii[lo]
        }
    }
}

// Blades are expensive to grow, so a small library of them is canalised one at a
// time in the background and shared out. Growing one per organ would mean thirty
// tissue simulations running at once, which is thirty times too many.
public final class LeafPool {
    private let prm: AuxinParams
    private let sp: SpeciesOptions
    public private(set) var lib: [Leaf] = []
    public private(set) var plib: [Leaf] = []
    public private(set) var cur: Leaf?
    private var n: UInt32 = 0
    private var pn: UInt32 = 0
    private var petalTurn = false
    private let seed: UInt32

    init(_ prm: AuxinParams, _ sp: SpeciesOptions, seed: UInt32) {
        self.prm = prm; self.sp = sp; self.seed = seed
    }

    private func make() -> Leaf {
        let s = seed &+ n &* 2654435761
        n += 1
        var r = Mulberry32(seed: s)
        var o = sp.leafOpts
        // Variety comes from the margin's CHEMISTRY, not from shape numbers: how
        // slender it grows, how hard a convergence point pushes, and how far apart
        // those points sit. A species scales that chemistry rather than replacing
        // it, so every leaf on one plant still differs from its neighbours while
        // the whole plant differs from another species. The bias is a multiplier on
        // a rate constant, never a width or a tooth count — nothing here knows what
        // the silhouette will be.
        let mb = sp.marginBias
        var m = MarginOptions()
        m.ay = canalLerp(0.34, 0.86, r.next()) * mb.ay
        m.g1 = canalLerp(0.00070, 0.00170, r.next()) * mb.g1
        m.gExp = canalLerp(1.6, 3.0, r.next()) * mb.gExp
        m.D = canalClamp(canalLerp(4.5, 11.0, r.next()) * mb.D, 2.0, 16.0)
        m.tipBias = canalClamp(canalLerp(0.25, 0.85, r.next()) * mb.tipBias, 0, 1)
        m.mature = (canalLerp(1100, 1700, r.next())).rounded()
        o.margin = m
        o.maxSources = Int(canalLerp(30, 64, r.next()))
        return Leaf(prm, o, seed: s)
    }

    private func makePetal() -> Leaf {
        let s = seed &+ 977 &+ pn &* 2246822519
        pn += 1
        var r = Mulberry32(seed: s)
        var o = sp.leafOpts
        // a petal is a leaf whose margin was told to be broad, smooth and short:
        // wide mediolateral growth, almost no answer to convergence points
        var m = MarginOptions()
        m.ay = canalLerp(0.95, 1.5, r.next())
        m.g1 = canalLerp(0.00010, 0.00030, r.next())
        m.gExp = 1.2
        m.D = canalLerp(9, 16, r.next())
        m.tipBias = canalLerp(0.05, 0.30, r.next())
        m.mature = (canalLerp(700, 1000, r.next())).rounded()
        o.margin = m
        o.maxSources = 14
        o.veinMax = 90
        return Leaf(prm, o, seed: s)
    }

    public func request(_ seed: UInt32) -> Leaf? {
        lib.isEmpty ? nil : lib[Int(seed % UInt32(lib.count))]
    }
    public func requestPetal(_ seed: UInt32) -> Leaf? {
        plib.isEmpty ? nil : plib[Int(seed % UInt32(plib.count))]
    }

    func step() {
        if cur == nil {
            // fill the leaf library first, then keep a few petals ready
            if lib.count < sp.leafLibrary { cur = make(); petalTurn = false }
            else if plib.count < 3 { cur = makePetal(); petalTurn = true }
            else { return }
        }
        guard let L = cur else { return }
        var k = 0
        while k < sp.leafBudget && !L.mature { L.step(1); k += 1 }
        if L.mature {
            if petalTurn { plib.append(L) } else { lib.append(L) }
            cur = nil
        }
    }

    public var growingLeaf: Leaf? { cur }
}

// Per-species multipliers on the leaf margin's own chemistry: ay slenderness,
// g1/gExp how hard a convergence point pushes, D how far apart those points can
// sit. All 1 means "the generic leaf".
public struct MarginBias {
    public init() {}
    public var ay: Float = 1
    public var g1: Float = 1
    public var gExp: Float = 1
    public var D: Float = 1
    public var tipBias: Float = 1
}

public struct SpeciesOptions {
    public init() {}
    public var elongation: Float = 0.0052
    public var segLen: Float = 0.16
    public var minInternode: Float = 0.18
    public var organRoll: Float = 0.55     // scatter in blade roll, radians
    public var internode: Float = 0.0072   // subapical stretching rate
    public var internodeSpan: Float = 2.6  // how far below the tip that persists
    public var thicken: Float = 0.00030    // secondary thickening per unit below the tip
    public var nutation: Float = 0.0135    // circumnutation rate
    public var nutAmp: Float = 0.16
    public var florigenRate: Float = 0.0016 // how fast leaves make the flowering signal
    public var florigenThresh: Float = 12   // how much must reach the tip before it converts
    public var floralOrgans: Int = 9        // ceiling; the apex usually stops first
    public var floralGrace: Float = 320     // idle steps before a floral apex is spent
    // Idle steps before a VEGETATIVE apex counts as stalled. Chosen from measured
    // gaps: across all eight reference species the longest a healthy shoot ever
    // went between founding organs is 500 steps. 1600 is 3.2x the worst real gap.
    public var vegGrace: Float = 1600
    public var floralCZ: Float = 0.42      // how much of the central zone survives conversion
    public var fruitFlow: Float = 0.0060   // a swelling fruit is a huge sink; the stem answers
    public var fruitScale: Float = 0.55
    public var fruitOpts = FruitOptions()
    public var maxFlowers: Int = 6
    // Where the identity boundary sits on `q`, and so the petal:stamen ratio. This
    // number is chosen, not derived — the imposition the reference's SCIENCE.md lists.
    public var petalQ: Float = 0.28        // organs founded outside this are petals
    public var petalTilt: Float = 1.45     // petals reflex past perpendicular as they open
    public var tropism: Float = 0.02
    public var wander: Float = 0.35
    public var organLen: Float = 1.35
    public var organTilt: Float = 0.85
    public var organGrow: Float = 190
    public var droop: Float = 0.55
    public var maxOrgans: Int = 60
    public var organBudget: Int = 96       // across the whole specimen, not per shoot
    public var tipRadius: Float = 0.05
    public var organFlow: Float = 0.00035
    public var radiusScale: Float = 1.0
    public var branching: Float = 0.55
    public var budRelease: Float = 300
    public var dominance: Float = 6.0
    public var maxAxes: Int = 5
    public var maxGen: Int = 2
    public var leafBudget: Int = 60
    public var leafLibrary: Int = 5
    public var leafOpts = LeafOptions()
    // How long the slowest blade on a finished specimen takes to let go. Only the
    // rate is set here — whether it happens at all is `Plant.spent()`.
    public var senesceFor: Float = 2200
    public var marginBias = MarginBias()
}

public enum PlantStage: String {
    case seedling, leafing, flowering, fruiting, ripe, senescing, dead
}

public final class Plant {
    public let prm: AuxinParams
    public let mo: MeristemOptions
    public let sp: SpeciesOptions
    public let seed: UInt32
    public let leaves: LeafPool
    public private(set) var axes: [Axis] = []
    public private(set) var time: Float = 0
    public var florigen: Float = 0
    public var floweredAt: Int = 0
    // Where the light is coming from, in world space, and how hard the shoots
    // lean toward it. Nil restores plain negative-gravitropism (straight up).
    public var sun: SIMD3<Float>?
    public var sunPull: Float = 0

    // A drop of light has reached a growing point. Everything this does is
    // something the model already answers to: the shoot it landed on surges,
    // and the flowering signal the leaves make is topped up — so playing brings
    // the specimen into flower sooner instead of merely making it taller.
    @discardableResult
    public func absorbLight(at p: SIMD3<Float>, amount: Float) -> SIMD3<Float>? {
        var best: Axis? = nil
        var bd = Float.greatestFiniteMagnitude
        for a in axes where a.meristem != nil {
            let d = simd_length_squared(a.tipPos() - p)
            if d < bd { bd = d; best = a }
        }
        // no growing point left: a spent specimen cannot use it
        guard let a = best else { return nil }
        a.vigour = min(1, a.vigour + amount)
        // A top-up, not a trigger. At 0.05 a played-with specimen flowered in
        // seconds and the whole life cycle became a blur; this brings flowering
        // forward by a noticeable amount over a minute or two of attention,
        // which is the timescale a child actually plays on.
        florigen += amount * sp.florigenThresh * 0.012
        return a.tipPos()
    }

    // Where a drop of light should fly to. Nil once every apex is spent.
    public func nearestTip(to p: SIMD3<Float>) -> SIMD3<Float>? {
        var best: SIMD3<Float>? = nil
        var bd = Float.greatestFiniteMagnitude
        for a in axes where a.meristem != nil {
            let t = a.tipPos()
            let d = simd_length_squared(t - p)
            if d < bd { bd = d; best = t }
        }
        return best
    }
    var lastDiv: Meristem.Divergence?
    var lastCells: Int = 0
    var lastPlastochron: Float = 0

    public init(_ prm: AuxinParams, _ mo: MeristemOptions = MeristemOptions(),
                _ sp: SpeciesOptions = SpeciesOptions(), seed: UInt32 = 1) {
        self.prm = prm; self.mo = mo; self.sp = sp; self.seed = seed
        leaves = LeafPool(prm, sp, seed: seed)
        _ = addAxis(base: SIMD3<Float>(0, 0, 0), dir: SIMD3<Float>(0, 1, 0), gen: 0)
    }

    @discardableResult
    func addAxis(base: SIMD3<Float>, dir: SIMD3<Float>, gen: Int) -> Axis {
        let s = UInt32(truncatingIfNeeded: Int(seed) &* 31 &+ axes.count &* 6151)
        let a = Axis(plant: self, base: base, dir: dir, gen: gen, seed: s)
        axes.append(a)
        return a
    }

    public var main: Axis { axes[0] }
    public func organCount() -> Int { axes.reduce(0) { $0 + $1.organs.count } }
    // flowers are not leaves and should not be charged against the leaf budget
    public func vegOrganCount() -> Int {
        axes.reduce(0) { $0 + $1.organs.filter { !$0.floral }.count }
    }
    public func flowerCount() -> Int { axes.filter { $0.floral }.count }

    // The organism has nothing left to build: every growing point has either
    // arrested on its budget or spent itself into a flower, so there is no tissue
    // anywhere still patterning. A physical condition read off the plant, not a
    // time — senescence waits for it, because a plant with a meristem left is
    // still investing in itself and does not dismantle its leaves.
    public func spent() -> Bool {
        for a in axes where a.meristem != nil { return false }
        return !axes.isEmpty
    }

    // ...and nothing left to ripen or hold up. The end of one specimen.
    public func dead() -> Bool {
        if !spent() { return false }
        for a in axes {
            if let f = a.fruit, !f.barren, !f.mature { return false }
            for o in a.organs where !o.floral && !o.shed { return false }
        }
        return true
    }

    // how far through dismantling itself the specimen is
    public func senescence() -> Float {
        var n = 0
        var s: Float = 0
        for a in axes { for o in a.organs where !o.floral { n += 1; s += o.shed ? 1 : o.sen } }
        return n > 0 ? s / Float(n) : 0
    }

    public func step(_ dt: Float) {
        time += dt
        leaves.step()
        for a in axes {
            a.step(dt, sp)
            // the fruit runs faster than the shoot; there is a lot to resolve
            if let f = a.fruit { for _ in 0..<3 { f.step(dt) } }
        }
        senesceStep(dt)
    }

    // SENESCENCE
    //
    // WHEN it starts is a physical state of the organism and nothing else — see
    // `spent()`. The ORDER is a wave up the plant, oldest tissue letting go
    // first, and that is asserted here rather than derived: the reference built a
    // whole-plant transport network (38_shoot.js) to derive it and could not, so
    // the honest thing is a stated rule rather than a stated rule wearing a
    // transport model.
    private func senesceStep(_ dt: Float) {
        if !spent() { return }
        var oldest: Float = 0
        for a in axes { for o in a.organs where !o.floral && o.age > oldest { oldest = o.age } }
        if oldest <= 0 { return }
        for a in axes {
            for o in a.organs {
                if o.floral || o.shed { continue }
                // squared, so the wave has a front instead of everything fading together
                let rel = canalClamp(o.age / oldest, 0, 1)
                o.sen = canalClamp(o.sen + dt * rel * rel / sp.senesceFor, 0, 1)
                if o.sen >= 1 { o.shed = true; o.shedAt = time }
            }
        }
    }

    // world-space extent of everything currently alive, used to frame the shot
    public struct Bounds { public var cx, cy, cz, w, h: Float }

    public func bounds() -> Bounds {
        var x0: Float = 1e9, y0: Float = 1e9, z0: Float = 1e9
        var x1: Float = -1e9, y1: Float = -1e9, z1: Float = -1e9
        for a in axes {
            for p in a.pts {
                x0 = min(x0, p.x); x1 = max(x1, p.x)
                y0 = min(y0, p.y); y1 = max(y1, p.y)
                z0 = min(z0, p.z); z1 = max(z1, p.z)
            }
            for o in a.organs {
                // a shed blade keeps no reach: a specimen that has dropped
                // everything must not still be framed for the canopy it used to have
                if o.shed { continue }
                let f = o.frame.o, r = o.len
                x0 = min(x0, f.x - r); x1 = max(x1, f.x + r)
                y0 = min(y0, f.y - r); y1 = max(y1, f.y + r)
                z0 = min(z0, f.z - r); z1 = max(z1, f.z + r)
            }
        }
        if x0 > x1 { x0 = -1; y0 = -1; z0 = -1; x1 = 1; y1 = 1; z1 = 1 }
        return Bounds(cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, cz: (z0 + z1) / 2,
                      w: max(x1 - x0, z1 - z0), h: y1 - y0)
    }

    // Which act the specimen is in. Drives both the camera and the display.
    public func stage() -> PlantStage {
        let fr = axes.compactMap { a -> Fruit? in
            guard let f = a.fruit, !f.barren else { return nil }
            return f
        }
        if dead() { return .dead }
        if senescence() > 0.04 { return .senescing }
        if !fr.isEmpty && fr.allSatisfy({ $0.done }) { return .ripe }
        if fr.contains(where: { $0.phase == .grow }) { return .fruiting }
        if axes.contains(where: { $0.floral }) { return .flowering }
        if organCount() > 2 { return .leafing }
        return .seedling
    }

    // Everything on this label is something the chemistry decided. None of these
    // numbers exists anywhere in the code — they are measurements of one
    // individual that grew the way it grew.
    public struct Card {
        public var stage: PlantStage
        public var leaves: Int, flowers: Int, petals: Int, teeth: Int
        public var seeds: Int, fruit: Int, ripe: Float, floweredAt: Int
        public var divergence: Float?, divergenceSd: Float?
    }

    public func card() -> Card {
        var nLeaves = 0, flowers = 0, seeds = 0, teeth = 0, petals = 0
        var lastLeaf: Leaf? = nil, lastFlower: Axis? = nil
        var ripe: Float = 0
        var nfruit = 0
        for a in axes {
            if a.floral { flowers += 1; lastFlower = a }
            if let f = a.fruit, !f.barren {
                nfruit += 1
                seeds += f.seeds.count
                var r: Float = 0
                for i in 0..<f.n { r += f.ripe[i] }
                ripe += r / Float(f.n)
            }
            for o in a.organs where !o.floral {
                nLeaves += 1
                if let l = o.leaf, l.margin.mature { lastLeaf = l }
            }
        }
        if let l = lastLeaf { teeth = l.margin.teeth.count }
        if let f = lastFlower { petals = f.organs.filter { $0.petal }.count }
        let st = stats().divergence
        return Card(stage: stage(), leaves: nLeaves, flowers: flowers, petals: petals,
                    teeth: teeth, seeds: seeds, fruit: nfruit,
                    ripe: nfruit > 0 ? ripe / Float(nfruit) : 0,
                    floweredAt: floweredAt,
                    divergence: st?.mean, divergenceSd: st?.sd)
    }

    public struct Stats {
        public var organs: Int, axes: Int, cells: Int, live: Int
        public var divergence: Meristem.Divergence?
        public var plastochron: Float, height: Float
    }

    public func stats() -> Stats {
        // read the angle off whichever growing point has the most to say — the
        // leader arrests, but its laterals keep patterning
        var m: Meristem? = nil
        for a in axes {
            if let am = a.meristem, m == nil || am.divergence.count > m!.divergence.count { m = am }
        }
        // once every growing point has been spent there is nothing left to
        // measure, so hold the last reading rather than blanking the display
        let st = (m?.divergenceStats(window: 24)) ?? lastDiv
        if let s = st { lastDiv = s }
        if let mm = m { lastCells = mm.F.n; lastPlastochron = mm.plastochron }
        return Stats(organs: organCount(), axes: axes.count,
                     cells: m?.F.n ?? lastCells, live: m?.primordia.count ?? 0,
                     divergence: st, plastochron: m?.plastochron ?? lastPlastochron,
                     height: main.tipPos().y)
    }
}
