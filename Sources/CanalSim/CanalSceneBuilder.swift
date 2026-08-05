import Foundation
import simd

// ---------------------------------------------------------------------------
// Walking a live plant into the vertex buffers — the drawing half of
// src/70_app.js `buildScene()`.
//
// Simplified in one way for this app: the reference's occlusion culling and
// microscope/watch modes exist to serve a mouse-driven camera that can be flown
// inside the specimen. Kid mode has no such camera — it is a slow automatic
// orbit that stays outside the plant — so there is nothing to cull and no blade
// singled out for the microscope. Cell resolution still fades up by apparent
// size, so coming close still shows the mechanism.
// ---------------------------------------------------------------------------

// Abscission separates the organ at the base of its stalk, so what leaves is the
// whole leaf. A drying blade also shrivels — it loses the turgor holding it open.
public let BLADE_DRAWN: Float = 0.80
public let BLADE_DRY_SHRINK: Float = 0.12

@inline(__always)
public func drawnBladeLen(_ len: Float, _ sen: Float) -> Float {
    len * BLADE_DRAWN * (1 - canalClamp(sen, 0, 1) * BLADE_DRY_SHRINK)
}

public struct Camera {
    public var eye = SIMD3<Float>(0, 6, 18)
    public var target = SIMD3<Float>(0, 6, 0)
    public var fov: Float = 0.62
    public var dist: Float = 18
    public var fogNear: Float = 0
    public var dofRange: Float = 8
    public init() {}
}

public struct SceneBuild {
    public var detail: Float = 0        // strongest cell-resolution fade in the frame
}

@discardableResult
public func buildPlantScene(_ B: Buffers, _ plant: Plant, _ species: Species,
                            _ cam: Camera, _ t: Float, viewportHeight: Float,
                            showMeristem: Bool = true) -> SceneBuild {
    let pal = species.pal
    B.reset()
    // vein ribbons face the camera and never get thinner than a pixel or so
    let px = 2 * tan(cam.fov / 2) / max(1, viewportHeight)
    B.view = cam.eye
    B.minWidth = cam.dist * px * 1.5

    var out = SceneBuild()

    // spend the vertex budget where there is something to see: a specimen with
    // sixty fronds gets a coarser surface than one with six
    let nOrg = plant.organCount()
    let bladeMU = nOrg > 42 ? 13 : (nOrg > 24 ? 18 : 22)
    let bladeMV = nOrg > 42 ? 6 : (nOrg > 24 ? 8 : 10)

    for ax in plant.axes {
        if ax.pts.count > 1 {
            let alive = ax.meristem != nil
            // A growing point that has just caught light burns brighter, and it
            // is the tip the eye is already on — so absorbing a drop is legible
            // without anything being drawn to announce it.
            let surge = 1 + ax.vigour * 4
            tube(B, ax.pts, ax.radii, 7) { t in
                let c = simd_mix(pal.stem0, pal.stem1, SIMD3<Float>(repeating: t))
                let e: Float = (t > 0.93 && alive) ? (t - 0.93) * 5.0 * pal.glow * surge : 0
                return (c, e)
            }
        }

        for org in ax.organs {
            if org.len < 0.02 { continue }
            let sen = org.sen
            // A shed blade has let go. The reference hands it to an aerodynamics
            // model (39_fall.js) and flies it to the ground; that is not ported
            // yet, so until it is, the organ lingers and fades from where it was
            // rather than blinking out of existence — which in a scene this quiet
            // is the more distracting of the two wrong answers.
            var vis: Float = 1
            if org.shed {
                let gone = canalClamp((plant.time - org.shedAt) / 260, 0, 1)
                if gone >= 1 { continue }
                vis = 1 - gone * gone
            }

            // petiole — a longer stalk carries the blade clear of the shoot and
            // its neighbours
            let a = org.frame.o
            let pet = org.len * 0.34 + org.radius * 1.8
            let b = a + org.frame.x * pet
            // the stalk empties too: the whole organ is being withdrawn from, and
            // a green stalk under a drained blade reads as a bug
            var petC = sen > 0 ? senesceTint(pal.stem1, sen * 0.85) : pal.stem1
            if vis < 1 { petC *= vis }
            tube(B, [a, b], [org.radius * 0.5, org.radius * 0.30], 5) { _ in (petC, 0) }

            guard let L = org.leaf, L.margin.mature else { continue }
            var fr = Frame()
            fr.o = b; fr.x = org.frame.x; fr.y = org.frame.y; fr.z = org.frame.z

            // blades unfurl rather than appearing at full size: one development
            // parameter — the blade lengthens, the wave of maturation runs out
            // along it, and the furled tip uncoils behind it
            let dev = canalClamp(org.dev * 1.06 - 0.03, 0, 1)
            let bl = drawnBladeLen(org.len, sen)
            if bl < 0.02 { continue }

            let bp = species.paletteFor(org)
            // it curls as it dries, hard: a dead leaf on the ground is a tube
            let curl = -bl * (org.petal ? 0.05 : 0.16) * (1 + sen * 2.2)
            let ripple = bl * 0.014

            // The mechanism fades up on apparent size — come closer and the cells
            // start showing what they are doing. No mode to find.
            let dEye = max(0.01, simd_length(fr.o - cam.eye))
            let detL = canalSmoothstep(0.42, 0.95, bl / dEye)

            let mu = detL > 0 ? Int(canalLerp(Float(bladeMU), Float(L.o.nu), detL).rounded()) : bladeMU
            let mv = detL > 0 ? Int(canalLerp(Float(bladeMV), Float(L.o.nv), detL).rounded()) : bladeMV
            blade(B, L, fr, bl, bl, bp, curl, ripple, bp.glow, mu, mv, dev,
                  (1 - 0.82 * detL) * vis, sen)
            if detL > 0.004 {
                if detL > out.detail { out.detail = detL }
                laminaCells(B, L, fr, bl, bl, pal, curl, ripple, t, detL, dev)
            }
        }

        // the fruit, if this shoot got that far
        if let f = ax.fruit, !f.barren, f.phase != .pattern {
            let tip = ax.pts[ax.pts.count - 1]
            let fs = species.sp.fruitScale * (ax.gen == 0 ? 1 : 0.72)
            fruitShell(B, f, tip, fs, pal)
        }

        // the growing point itself
        if showMeristem, let m = ax.meristem {
            let n = ax.pts.count
            let tip = ax.pts[n - 1]
            let prev = ax.pts[max(0, n - 2)]
            var dir = tip - prev
            let dl = simd_length(dir)
            if !dl.isFinite || dl < 1e-6 { dir = SIMD3<Float>(0, 1, 0) } else { dir /= dl }
            let refv = abs(dir.z) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
            let e1 = simd_normalize(simd_cross(refv, dir))
            let e2 = simd_normalize(simd_cross(dir, e1))
            let mScale = max(0.35, ax.radii[n - 1] * 5.5)
            let dEye = max(0.01, simd_length(cam.eye - tip))
            let det = canalSmoothstep(0.030, 0.105, mScale / dEye)
            if det > out.detail { out.detail = det }
            var f = Frame()
            f.o = tip; f.x = dir; f.y = e2; f.z = e1
            meristemDome(B, m, f, mScale, pal, t, det)
        }
    }
    return out
}
