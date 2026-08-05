import Foundation
import simd

// ---------------------------------------------------------------------------
// Turning simulation state into triangles, ribbons and points — port of
// src/50_geom.js. Rebuilt every few frames; nothing here is persistent.
//
// Three interleaved streams, laid out exactly as the GPU consumes them:
//   tri  — pos3 nrm3 col3 emis1   (10 floats)  blades, stems, fruit shells
//   line — pos3 col3 emis1        ( 7 floats)  vein ribbons and PIN needles
//   pt   — pos3 col3 size1        ( 7 floats)  cells and travelling auxin
// ---------------------------------------------------------------------------

public final class Buffers {
    // Sized for a dense specimen with one blade refined to cell resolution. A
    // full buffer drops geometry silently, so the failure mode is a picture that
    // is merely missing things — headroom costs nothing per frame, only the
    // allocation.
    public private(set) var tri: [Float]
    public private(set) var triN = 0
    public private(set) var line: [Float]
    public private(set) var lineN = 0
    public private(set) var pt: [Float]
    public private(set) var ptN = 0

    // where the camera is, for orienting vein ribbons
    public var view = SIMD3<Float>(0, 0, 1)
    public var minWidth: Float = 0.004

    public init() {
        tri = [Float](repeating: 0, count: 1 << 21)
        line = [Float](repeating: 0, count: 1 << 21)
        pt = [Float](repeating: 0, count: 1 << 19)
    }

    public func reset() { triN = 0; lineN = 0; ptN = 0 }

    public var triCount: Int { triN / 10 }
    public var lineCount: Int { lineN / 7 }
    public var ptCount: Int { ptN / 7 }

    @inline(__always)
    public func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ c: SIMD3<Float>, _ e: Float) {
        if triN + 10 > tri.count { return }
        let i = triN
        tri[i] = p.x; tri[i + 1] = p.y; tri[i + 2] = p.z
        tri[i + 3] = n.x; tri[i + 4] = n.y; tri[i + 5] = n.z
        tri[i + 6] = c.x; tri[i + 7] = c.y; tri[i + 8] = c.z
        tri[i + 9] = e
        triN += 10
    }

    // one glowing vertex of a vein ribbon
    @inline(__always)
    private func gv(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ e: Float) {
        let i = lineN
        line[i] = p.x; line[i + 1] = p.y; line[i + 2] = p.z
        line[i + 3] = c.x; line[i + 4] = c.y; line[i + 5] = c.z; line[i + 6] = e
        lineN += 7
    }

    // A vein drawn as a camera-facing ribbon rather than a hairline, so its order
    // — how much traffic it carries — is legible as thickness.
    public func ribbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ side: SIMD3<Float>,
                       _ w0: Float, _ w1: Float, _ c: SIMD3<Float>, _ e: Float) {
        if lineN + 42 > line.count { return }
        let a0 = a - side * w0, a1 = a + side * w0
        let b0 = b - side * w1, b1 = b + side * w1
        gv(a0, c, e); gv(a1, c, e); gv(b1, c, e)
        gv(a0, c, e); gv(b1, c, e); gv(b0, c, e)
    }

    // a plain 2-vertex glowing line (needles are thin by nature)
    public func seg2(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ e: Float) {
        if lineN + 42 > line.count { return }
        let s = simd_cross(b - a, view - a)
        let l = simd_length(s)
        if !(l > 1e-20) || !l.isFinite { return }
        let side = s / l
        let w = minWidth * 0.85
        ribbon(a, b, side, w, w * 0.35, c, e)
    }

    @inline(__always)
    public func point(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ s: Float) {
        if ptN + 7 > pt.count { return }
        let i = ptN
        pt[i] = p.x; pt[i + 1] = p.y; pt[i + 2] = p.z
        pt[i + 3] = c.x; pt[i + 4] = c.y; pt[i + 5] = c.z; pt[i + 6] = s
        ptN += 7
    }
}

// The colours a species is drawn in. Everything here was authored in the
// reference too (its species table), so it adds no spatial prior — the PATTERNS
// these colours land in are all simulation output.
public struct Palette {
    public init() {}
    public var blade0 = SIMD3<Float>(0.06, 0.21, 0.21)
    public var blade1 = SIMD3<Float>(0.10, 0.36, 0.32)
    public var veinTint = SIMD3<Float>(0.02, 0.16, 0.22)
    public var vein = SIMD3<Float>(0.35, 1.0, 0.95)
    public var stem0 = SIMD3<Float>(0.07, 0.20, 0.16)
    public var stem1 = SIMD3<Float>(0.14, 0.34, 0.24)
    public var cell0 = SIMD3<Float>(0.05, 0.14, 0.18)
    public var cell1 = SIMD3<Float>(0.55, 1.0, 0.85)
    public var pin = SIMD3<Float>(0.45, 0.95, 1.0)
    public var spark = SIMD3<Float>(1.0, 0.95, 0.6)
    public var fruit0 = SIMD3<Float>(0.16, 0.26, 0.14)
    public var fruit1 = SIMD3<Float>(0.85, 0.28, 0.20)
    public var glow: Float = 1.0
    // lighting
    public var key = simd_normalize(SIMD3<Float>(0.4, 0.8, 0.45))
    public var keyCol = SIMD3<Float>(1.0, 0.97, 0.88)
    public var ambTop = SIMD3<Float>(0.16, 0.20, 0.26)
    public var ambBot = SIMD3<Float>(0.05, 0.07, 0.08)
    public var fog = SIMD3<Float>(0.02, 0.03, 0.04)
    public var fogD: Float = 0.010
    public var sway: Float = 1.0
    // grade
    public var bloom: Float = 0.85
    public var bloomThresh: Float = 0.75
    public var exposure: Float = 1.15
    public var grain: Float = 0.012
    public var vignette: Float = 0.20
    public var dof: Float = 0.85
}

// ---------------------------------------------------------------------------
// THE COLOUR OF SENESCENCE, DERIVED RATHER THAN PAINTED
//
// A senescing leaf is not repainted, it is EMPTIED. The pigment-protein
// complexes are dismantled and their nitrogen withdrawn into the plant before
// the blade is let go. What stays behind is cell wall: unpigmented, and warm,
// because that is the colour of what oxidises in it.
//
// So this is a SUBTRACTION from the blade's own colour rather than hand-picked
// autumn browns — discard the pigment (collapse to luminance), keep the wall,
// tint it warm. Two stages, because that is the order it happens in: the pigment
// goes first and the tissue is briefly PALER than it was alive, and only then
// does the wall dry and darken. One stage looks like a dimmer switch.
// ---------------------------------------------------------------------------
public func senesceTint(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
    if s <= 0 { return c }
    let l = 0.30 * c.x + 0.59 * c.y + 0.11 * c.z
    let k0 = canalClamp(s * 2, 0, 1), k1 = canalClamp(s * 2 - 1, 0, 1)
    // pigment gone, wall exposed        then dried out
    let p0 = l * 1.45 + 0.020, d0 = l * 0.72 + 0.010
    let p1 = l * 1.16 + 0.012, d1 = l * 0.48 + 0.005
    let p2 = l * 0.44, d2 = l * 0.20
    return SIMD3<Float>(canalLerp(canalLerp(c.x, p0, k0), d0, k1),
                        canalLerp(canalLerp(c.y, p1, k0), d1, k1),
                        canalLerp(canalLerp(c.z, p2, k0), d2, k1))
}

// How far behind the lamina the vasculature drains. Tissue next to a vein is the
// last to be dismantled, because the vein is the route the recovered nitrogen
// leaves by — green islands along the veins of a yellow leaf are this. The
// constant sets only the LAG; the SHAPE of what is spared is `leaf.vdf`, the
// distance field of a network that canalised itself.
let VEIN_LAG: Float = 0.45

// a generalised cylinder along a polyline, with a parallel-transported frame
public func tube(_ B: Buffers, _ pts: [SIMD3<Float>], _ radii: [Float], _ sides: Int,
                 _ colFn: (Float) -> (SIMD3<Float>, Float)) {
    let n = pts.count
    if n < 2 { return }
    var up = SIMD3<Float>(0, 0, 1)
    var prevRing = [SIMD3<Float>](repeating: .zero, count: sides)
    var prevNrm = [SIMD3<Float>](repeating: .zero, count: sides)
    var curRing = prevRing, curNrm = prevNrm
    for i in 0..<n {
        let p = pts[i]
        var t = pts[min(n - 1, i + 1)] - pts[max(0, i - 1)]
        if simd_length(t) < 1e-6 { t = SIMD3<Float>(0, 1, 0) }
        t = simd_normalize(t)
        if abs(simd_dot(t, up)) > 0.95 { up = SIMD3<Float>(1, 0, 0) }
        let u = simd_normalize(simd_cross(up, t))
        let nn = simd_normalize(simd_cross(t, u))
        up = nn
        let r = radii[min(i, radii.count - 1)]
        for k in 0..<sides {
            let th = Float(k) / Float(sides) * CANAL_TAU
            let cs = cos(th), sn = sin(th)
            let nv = u * cs + nn * sn
            curNrm[k] = nv
            curRing[k] = p + nv * r
        }
        if i > 0 {
            let (c0, e0) = colFn(Float(i - 1) / Float(n - 1))
            let (c1, e1) = colFn(Float(i) / Float(n - 1))
            for k in 0..<sides {
                let k2 = (k + 1) % sides
                B.vert(prevRing[k], prevNrm[k], c0, e0)
                B.vert(curRing[k], curNrm[k], c1, e1)
                B.vert(prevRing[k2], prevNrm[k2], c0, e0)
                B.vert(prevRing[k2], prevNrm[k2], c0, e0)
                B.vert(curRing[k], curNrm[k], c1, e1)
                B.vert(curRing[k2], curNrm[k2], c1, e1)
            }
        }
        swap(&prevRing, &curRing)
        swap(&prevNrm, &curNrm)
    }
}

// map a point in blade space (u along, v across) into world space, with a little
// curl so blades are not flat cards
@inline(__always)
func bladePoint(_ frame: Frame, _ u: Float, _ v: Float, _ len: Float, _ wid: Float,
                _ curl: Float, _ ripple: Float, _ off: Float) -> SIMD3<Float> {
    let bend = curl * u * u
    let rip = sin(u * 9.0 + v * 5.0) * ripple * u
    let n = bend + rip + off
    return frame.o + frame.x * (u * len) + frame.z * (v * wid) + frame.y * n
}

// Where a point of leaf TISSUE currently sits on the drawn surface.
//
// Veins and cells are both simulated in material coordinates and both have to be
// mapped onto whatever the blade is doing right now: expanding, furled at the
// tip, cut to an asymmetric outline. Both callers need exactly the same mapping,
// or cells float off their own leaf.
struct BladeMap {
    let leaf: Leaf
    let len: Float
    let dev: Float
    // A leaf does not scale up. It expands from the base outward as a wave of
    // maturation runs to the tip, and the tissue ahead of that wave is still
    // rolled up in the bud. That is why an unfurling frond looks the way it does.
    static let TAIL: Float = 0.46

    @inline(__always) func matAt(_ u: Float) -> Float {
        canalClamp((dev - u) / BladeMap.TAIL + 1, 0, 1)
    }
    // asymmetric: the two sides of a grown leaf are not the same, because the two
    // halves of the margin patterned independently
    @inline(__always) func wAt(_ u: Float, _ t: Float) -> Float {
        leaf.wSide(canalClamp(u, 0, 1), t < 0 ? -1 : 1) * (0.10 + 0.90 * matAt(u))
    }
    @inline(__always) func wMat(_ u: Float, _ t: Float) -> Float {
        leaf.wSide(canalClamp(u, 0, 1), t < 0 ? -1 : 1)
    }
    @inline(__always) func furlAt(_ u: Float) -> Float {
        let m = 1 - matAt(u)
        return -len * leaf.o.furl * m * m * (0.6 + m)
    }
}

// A frond: a coarse parametric surface cut to the blade outline, with the
// canalised vein network laid on top of it. The mesh is deliberately much coarser
// than the tissue that was simulated — the veins carry the detail.
//
// `fade` dims the blade's own surface: under the microscope the lamina is an
// opaque sheet and the cells sit ON it, so at full strength the skin outshines
// the tissue. `sen` is the ORGAN's senescence, deliberately not stored on the
// leaf — blades come from a shared library, and one organ dying must not drain
// the others.
public func blade(_ B: Buffers, _ leaf: Leaf, _ frame: Frame, _ len: Float, _ wid: Float,
                  _ pal: Palette, _ curl: Float, _ ripple: Float, _ glow: Float,
                  _ MU: Int = 22, _ MV: Int = 10, _ dev: Float = 1,
                  _ fade: Float = 1, _ sen: Float = 0) {
    guard leaf.margin.mature else { return }
    let o = leaf.o
    let map = BladeMap(leaf: leaf, len: len, dev: dev)
    let res = leaf.vdfRes
    let vdf = leaf.vdf
    @inline(__always) func nearVein(_ u: Float, _ v: Float) -> Float {
        if vdf.isEmpty || res == 0 { return 9 }
        let a = Int(canalClamp((u * Float(res - 1)).rounded(), 0, Float(res - 1)))
        let b = Int(canalClamp(((v / o.aspect * 0.5 + 0.5) * Float(res - 1)).rounded(), 0, Float(res - 1)))
        return vdf[a * res + b]
    }

    // Build the surface once as a grid, with normals from finite differences of
    // the parametrisation. Smooth normals rather than per-facet ones: a frond is a
    // curved sheet, and faceting reads as cheap.
    let NU = MU + 1, NV = MV + 1
    var pos = [SIMD3<Float>](repeating: .zero, count: NU * NV)
    var nrm = [SIMD3<Float>](repeating: .zero, count: NU * NV)
    var col = [SIMD3<Float>](repeating: .zero, count: NU * NV)
    var emi = [Float](repeating: 0, count: NU * NV)
    let h: Float = 0.004
    @inline(__always) func at(_ u: Float, _ t: Float) -> Float { t * map.wAt(u, t) }
    @inline(__always) func matAtUV(_ u: Float, _ t: Float) -> Float { t * map.wMat(u, t) }

    for i in 0..<NU {
        let u = Float(i) / Float(MU)
        for j in 0..<NV {
            let t = (Float(j) / Float(MV)) * 2 - 1
            let k = i * NV + j
            let P = bladePoint(frame, u, at(u, t), len, wid, curl, ripple, map.furlAt(u))
            let Pu = bladePoint(frame, u + h, at(u + h, t), len, wid, curl, ripple, map.furlAt(u + h))
            let Pv = bladePoint(frame, u, at(u, t + h), len, wid, curl, ripple, map.furlAt(u))
            let nn = simd_cross(Pu - P, Pv - P)
            let nl = simd_length(nn)
            pos[k] = P
            nrm[k] = nl > 1e-20 ? nn / nl : SIMD3<Float>(0, 1, 0)
            let vv = matAtUV(u, t)
            let dd = vdf.isEmpty ? 0 : canalClamp(1 - nearVein(u, vv) * 11, 0, 1)
            let tt = canalClamp(u * 0.9 + 0.1, 0, 1)
            let base = simd_mix(pal.blade0, pal.blade1, SIMD3<Float>(repeating: tt))
                     + pal.veinTint * dd
            // This vertex's own senescence: the open lamina goes first and the
            // tissue held against a vein goes last, so the blade empties into its
            // own vasculature rather than dimming as one flat card. `hold` is
            // squared because `dd` reads better than half the lamina as "near a
            // vein" — squaring narrows what is spared without touching `dd`,
            // which fenestration and the vein tint are both calibrated against.
            let hold = dd * dd
            let sl = sen > 0 ? canalClamp((sen - hold * VEIN_LAG) / (1 - VEIN_LAG), 0, 1) : 0
            col[k] = senesceTint(base, sl) * fade
            // dead tissue does not glow. It is the first thing to go, and it is
            // what makes the drain read at a distance where the hue shift alone
            // does not.
            emi[k] = dd * glow * 0.24 * fade * (1 - sl)
        }
    }

    for i in 0..<MU {
        let u0 = Float(i) / Float(MU), u1 = Float(i + 1) / Float(MU)
        for j in 0..<MV {
            // Fenestration is cut against the distance-to-vein field, which only
            // exists once the leaf has baked — without that guard a still-
            // canalising monstera is drawn as a hole with a rim.
            if o.fenestrate > 0 && !vdf.isEmpty {
                let mu = (u0 + u1) * 0.5
                let mt = ((Float(j) + 0.5) / Float(MV)) * 2 - 1
                if nearVein(mu, matAtUV(mu, mt)) > o.fenestrate && mu > 0.16 && mu < 0.93 { continue }
            }
            let k00 = i * NV + j, k01 = i * NV + j + 1
            let k11 = (i + 1) * NV + j + 1, k10 = (i + 1) * NV + j
            B.vert(pos[k00], nrm[k00], col[k00], emi[k00])
            B.vert(pos[k01], nrm[k01], col[k01], emi[k01])
            B.vert(pos[k11], nrm[k11], col[k11], emi[k11])
            B.vert(pos[k00], nrm[k00], col[k00], emi[k00])
            B.vert(pos[k11], nrm[k11], col[k11], emi[k11])
            B.vert(pos[k10], nrm[k10], col[k10], emi[k10])
        }
    }

    // --- the vasculature, as ribbons whose width is the vein's order ---------
    let lift = len * 0.010 + 0.005
    let base = len * 0.0034
    // The vasculature is at dd=1 by definition, so it drains on the far end of the
    // lag and is still lit when the lamina around it has gone: a shed blade leaves
    // as a skeleton, and the midrib is the last lit thing on the plant.
    let sv = sen > 0 ? canalClamp((sen - VEIN_LAG) / (1 - VEIN_LAG), 0, 1) : 0
    let vcol = senesceTint(pal.vein, sv)
    let vglow = glow * (1 - sv * 0.92)
    for s in leaf.veins {
        // veins mature basipetally too — none exist ahead of the wave
        if s.x0 > dev + 0.04 || s.x1 > dev + 0.04 { continue }
        // a vein whose material half-width has collapsed cannot be mapped onto the
        // current outline — skip it rather than divide by nothing
        let w0 = map.wMat(s.x0, s.y0), w1 = map.wMat(s.x1, s.y1)
        if w0 < 1e-3 || w1 < 1e-3 { continue }
        // and never let a remapped vein leave the blade, whatever the outline did
        let t0 = canalClamp(s.y0 / w0, -1, 1), t1 = canalClamp(s.y1 / w1, -1, 1)
        let q0 = bladePoint(frame, s.x0, t0 * map.wAt(s.x0, s.y0), len, wid, curl, ripple, lift + map.furlAt(s.x0))
        let q1 = bladePoint(frame, s.x1, t1 * map.wAt(s.x1, s.y1), len, wid, curl, ripple, lift + map.furlAt(s.x1))
        let sv3 = simd_cross(q1 - q0, B.view - q0)
        let sl = simd_length(sv3)
        if !(sl > 1e-20) || !sl.isFinite { continue }
        let w = max(B.minWidth, base * (0.25 + s.w * 1.35))
        B.ribbon(q0, q1, sv3 / sl, w, w, vcol, vglow * (0.06 + s.w * 0.52))
    }
}

// ---------------------------------------------------------------------------
// THE BLADE, AT CELL RESOLUTION
//
// On the meristem the needles CONVERGE, and that convergence is a leaf. Here
// they fall into LINE, and that line is a vein. Same field, same solver, same
// drawing language — only the boundary conditions differ.
//
// One thing does NOT carry over: on the meristem, needle length is |polarity|,
// but the blade runs in flux mode with no competence gate and EVERY cell ends up
// essentially fully polarised. What separates a vein from an areole here is
// TRAFFIC. So direction comes from the PIN allocation and length/brightness come
// from flux — which is the same quantity `bake()` keeps a vein by.
// ---------------------------------------------------------------------------
public func laminaCells(_ B: Buffers, _ leaf: Leaf, _ frame: Frame, _ len: Float, _ wid: Float,
                        _ pal: Palette, _ curl: Float, _ ripple: Float, _ t: Float,
                        _ detail: Float, _ dev: Float = 1) {
    guard let F = leaf.F, F.n > 0, leaf.margin.mature else { return }
    let map = BladeMap(leaf: leaf, len: len, dev: dev)
    let lift = len * 0.013 + 0.006      // clear of the blade, and of the veins
    // Size everything off the lattice the tissue was simulated on, not off the
    // blade: a fixed fraction of blade length merges cells into a sheet of
    // touching discs on anything dense.
    let ms = 1 / Float(max(4, leaf.o.nu))
    let cw = len * ms

    // Normalise traffic against this leaf's own busiest wall — the midrib at the
    // petiole, where everything funnels. Linear, not log: the hierarchy spans
    // three orders of magnitude and log-compressing it washes the picture out.
    var maxJ: Float = 1e-6
    for i in 0..<F.n {
        let d = Int(F.deg[i]), off = i * MAXNB
        for k in 0..<d where F.J[off + k] > maxJ { maxJ = F.J[off + k] }
    }

    @inline(__always) func toSurface(_ u: Float, _ y: Float) -> SIMD3<Float>? {
        let w0 = map.wMat(u, y)
        if w0 < 1e-3 { return nil }
        let tt = canalClamp(y / w0, -1, 1)
        return bladePoint(frame, u, tt * map.wAt(u, y), len, wid, curl, ripple, lift + map.furlAt(u))
    }

    for i in 0..<F.n {
        let x = F.x[i], y = F.y[i]
        // no tissue exists ahead of the wave of maturation, so no cells either
        if x > dev + 0.04 { continue }
        guard let c0 = toSurface(x, y) else { continue }

        // The median cell sits near 0.8 — the sources at the teeth are an order of
        // magnitude above the lamina. A 0.55 exponent keeps every cell present as
        // a cell while the sources still obviously blaze.
        let a = canalClamp(F.a[i] / 8, 0, 1)
        let g = powf(a, 0.55)
        let dim = 1 - detail * 0.42
        B.point(c0, simd_mix(pal.cell0, pal.cell1, SIMD3<Float>(repeating: g)) * dim,
                cw * 0.62 * (1 + g * 0.5))

        if detail < 0.02 { continue }

        // --- which way this cell has aimed its pumps -------------------------
        let d = Int(F.deg[i]), off = i * MAXNB
        var px: Float = 0, py: Float = 0, tot: Float = 0, flux: Float = 0
        for k in 0..<d {
            let e = off + k, j = Int(F.nbr[e])
            let ex = F.x[j] - x, ey = F.y[j] - y
            let el = max(1e-20, (ex * ex + ey * ey).squareRoot())
            let w = F.P[e]
            px += w * ex / el; py += w * ey / el; tot += w
            if F.J[e] > flux { flux = F.J[e] }
        }
        if tot <= 1e-6 { continue }
        px /= tot; py /= tot
        let pol = (px * px + py * py).squareRoot()
        if pol < 0.02 { continue }
        let ux = px / pol, uy = py / pol
        let fn = canalClamp(flux / maxJ, 0, 1)         // traffic: the vein channel

        // a needle reaches at most a little under two cells, so a committed file
        // reads as a continuous line without every cell overwriting its neighbour
        let nl = ms * (0.30 + fn * 1.40)
        guard let c1 = toSurface(x + ux * nl, y + uy * nl) else { continue }
        B.seg2(c0, c1, pal.pin, detail * (0.10 + fn * 2.1))

        // --- auxin actually on the move --------------------------------------
        if fn > 0.02 {
            let hh = Float((UInt32(bitPattern: F.id[i]) ^ 0x2545f491) &* 0x9e3779b1 >> 8) / 16777216
            let ph = (t * 0.00055 * (0.5 + min(2.5, flux * 0.08)) + hh)
                .truncatingRemainder(dividingBy: 1)
            if let c2 = toSurface(x + ux * nl * (0.15 + ph * 1.25), y + uy * nl * (0.15 + ph * 1.25)) {
                let fade = sin(ph * .pi)
                let b2 = detail * fade * canalClamp(fn * 2.4, 0, 1.6)
                B.point(c2, pal.spark * b2, cw * 0.30 * (0.6 + fade))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// THE GROWING TIP, AT CELL RESOLUTION
//
// Each cell is a disc coloured by how much auxin it holds, with the mechanism
// fading up on top of it as the camera comes in: the needle is the direction
// that cell has loaded its PIN pumps, and the spark is auxin actually being
// moved along it at a rate set by the real flux. Watch the needles around a
// forming organ — they all swing to point at it. That convergence IS the
// primordium. Nothing else is happening.
// ---------------------------------------------------------------------------
public func meristemDome(_ B: Buffers, _ m: Meristem, _ frame: Frame, _ scale: Float,
                         _ pal: Palette, _ t: Float, _ detail: Float) {
    let F = m.F
    let R = m.o.R
    let dt = detail
    @inline(__always) func toWorld(_ sx: Float, _ sy: Float, _ sz: Float) -> SIMD3<Float> {
        frame.o + frame.z * sx + frame.y * sy + frame.x * sz
    }
    @inline(__always) func domeH(_ r: Float) -> Float { max(0, 1 - r * r).squareRoot() * 0.55 }

    for i in 0..<F.n {
        let x = F.x[i], y = F.y[i]
        let r = (x * x + y * y).squareRoot() / R
        let sx = x / R * scale, sy = y / R * scale, sz = domeH(r) * scale
        let p = toWorld(sx, sy, sz)
        let a = canalClamp(F.a[i] / 6, 0, 1)
        let g = powf(a, 0.7)
        let c = simd_mix(pal.cell0, pal.cell1, SIMD3<Float>(repeating: g))
        // at close range the cells must read as separate cells, not as one lamp
        let shrink = 1 - dt * 0.42
        let dim = 1 - dt * 0.45
        B.point(p, c * dim, scale * (0.052 + 0.018 * F.sz[i]) * (1 + g * 0.55) * shrink)

        if dt < 0.02 { continue }

        let d = Int(F.deg[i]), off = i * MAXNB
        var px: Float = 0, py: Float = 0, tot: Float = 0, flux: Float = 0
        for k in 0..<d {
            let e = off + k, j = Int(F.nbr[e])
            let ex = F.x[j] - x, ey = F.y[j] - y
            let el = max(1e-20, (ex * ex + ey * ey).squareRoot())
            let w = F.P[e]
            px += w * ex / el; py += w * ey / el; tot += w
            if F.J[e] > flux { flux = F.J[e] }
        }
        if tot <= 1e-6 { continue }
        px /= tot; py /= tot
        let pol = (px * px + py * py).squareRoot()   // 0 apolar, 1 all on one wall
        if pol < 0.02 { continue }
        let ux = px / pol, uy = py / pol

        let nl = scale * 0.070 * (0.35 + pol * 1.45)
        let bx = sx + ux * nl, by = sy + uy * nl
        let r2 = (bx * bx + by * by).squareRoot() / scale
        let q = toWorld(bx, by, domeH(min(1, r2)) * scale)
        let nb = dt * (0.10 + pol * 1.5) * (0.4 + canalClamp(F.a[i] / 4, 0, 1))
        B.seg2(p, q, pal.pin, nb)

        if flux > 0.02 {
            let hh = Float((UInt32(bitPattern: F.id[i]) ^ 0x2545f491) &* 0x9e3779b1 >> 8) / 16777216
            let ph = (t * 0.00055 * (0.5 + min(2.5, flux * 0.35)) + hh)
                .truncatingRemainder(dividingBy: 1)
            let fx = sx + ux * nl * (0.15 + ph * 1.25)
            let fy = sy + uy * nl * (0.15 + ph * 1.25)
            let rr = (fx * fx + fy * fy).squareRoot() / scale
            let q2 = toWorld(fx, fy, domeH(min(1, rr)) * scale)
            let fade = sin(ph * .pi)
            let b2 = dt * fade * canalClamp(flux * 0.5, 0, 1.6)
            B.point(q2, pal.spark * b2, scale * 0.035 * (0.6 + fade))
        }
    }
}

// ---------------------------------------------------------------------------
// A fruit: the ovary wall as a closed shell, coloured by how far the ripening
// wave has crossed it, with the seeds glowing faintly through the flesh.
// ---------------------------------------------------------------------------
public func fruitShell(_ B: Buffers, _ fr: Fruit, _ origin: SIMD3<Float>, _ scale: Float,
                       _ pal: Palette) {
    var glow = [Float](repeating: 0, count: fr.n)
    for s in fr.seeds { glow[s] = 1 }
    @inline(__always) func col(_ i: Int) -> SIMD3<Float> {
        simd_mix(pal.fruit0, pal.fruit1, SIMD3<Float>(repeating: canalClamp(fr.ripe[i], 0, 1)))
    }
    @inline(__always) func em(_ i: Int) -> Float {
        pal.glow * (0.04 + 0.26 * glow[i] + 0.18 * fr.ripe[i])
    }
    for f in fr.faces {
        for i in [f.0, f.1, f.2] {
            B.vert(origin + fr.pos[i] * scale, fr.nrm[i], col(i), em(i))
        }
    }
}
