import AppKit

// GRAVITATIONAL — soft bodies drift in slow orbits around a few gently-roaming gravity
// wells (and the cursor), each tracing a fading arc so the orbital paths shimmer. Unlike
// Black Hole, nothing is consumed — it's a calm, endless orbital dance. A click nudges a
// soft outward swell; a keypress releases another orbiter.
final class CalmGravitationalScene: Scene {
    let name = "Gravitational"
    let category = SceneCategory.archived
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Body {
        var pos: NSPoint; var vel: NSPoint; var color: Int; var size: CGFloat
        var trail: [NSPoint]      // recent positions (head last)
    }
    private struct Well { var pos: NSPoint; var vel: NSPoint; var mass: CGFloat }
    private var bodies: [Body] = []
    private var wells: [Well] = []
    private var pulses: [(p: NSPoint, t: TimeInterval)] = []
    private let ambient = 46
    private let maxBodies = 110
    private let trailLen = 9
    private var rng = RNG(seed: 0x6247A)
    private var seededSize = CGSize.zero

    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.9, blue: 0.7, alpha: 1),   // warm
        NSColor(srgbRed: 0.7, green: 0.88, blue: 1.0, alpha: 1),   // cool blue
        NSColor(srgbRed: 0.8, green: 1.0, blue: 0.85, alpha: 1),   // mint
    ]
    private static let cores: [CGImage] = swatches.map { softContrastSprite($0) }
    private static let glows: [CGImage] = swatches.map { softGlowSprite($0) }
    private static let trailCore = NSColor(srgbRed: 0.85, green: 0.92, blue: 1, alpha: 1)

    func reset() { bodies.removeAll(keepingCapacity: true); wells.removeAll(); pulses.removeAll(); seededSize = .zero; draining = false }

    private func newBody(_ b: CGRect) -> Body {
        let p = NSPoint(x: rng.range(b.minX, b.maxX), y: rng.range(b.minY, b.maxY))
        return Body(pos: p, vel: NSPoint(x: rng.range(-60, 60), y: rng.range(-60, 60)),
                    color: rng.int(Self.cores.count), size: rng.range(3, 6), trail: [p])
    }

    private func seedIfNeeded(_ b: CGRect) {
        guard b.size != seededSize else { return }
        seededSize = b.size
        bodies.removeAll(keepingCapacity: true); wells.removeAll(keepingCapacity: true)
        for _ in 0..<3 {
            wells.append(Well(pos: NSPoint(x: rng.range(b.minX + 200, b.maxX - 200), y: rng.range(b.minY + 150, b.maxY - 150)),
                              vel: NSPoint(x: rng.range(-12, 12), y: rng.range(-12, 12)), mass: rng.range(7e4, 1.2e5)))
        }
        for _ in 0..<ambient { bodies.append(newBody(b)) }
    }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key:
            if bodies.count < maxBodies { var bd = newBody(ctx.bounds); bd.pos = ctx.cursor; bd.trail = [ctx.cursor]; bodies.append(bd) }
            ctx.audio?.note(for: ks(e), intensity: ctx.intensity)
        case .click(let pt, .left): pulses.append((pt, ctx.now)); ctx.audio?.whoosh()
        default: break
        }
    }
    private func ks(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        let dt = ctx.dt
        pulses.removeAll { ctx.now - $0.t > 0.8 }
        // Wells roam slowly and bounce off the screen.
        for i in wells.indices {
            wells[i].pos = wells[i].pos + wells[i].vel * dt
            if wells[i].pos.x < ctx.bounds.minX + 120 || wells[i].pos.x > ctx.bounds.maxX - 120 { wells[i].vel.x *= -1 }
            if wells[i].pos.y < ctx.bounds.minY + 120 || wells[i].pos.y > ctx.bounds.maxY - 120 { wells[i].vel.y *= -1 }
        }
        let eps2: CGFloat = 70 * 70
        let cursorMass: CGFloat = 8e4 * (0.6 + 0.6 * ctx.intensity)
        for i in bodies.indices {
            var v = bodies[i].vel
            for w in wells {
                let d = w.pos - bodies[i].pos, r2 = hypot2(d) + eps2, r = sqrt(r2)
                let a = w.mass / r2
                v.x += d.x / r * a * dt; v.y += d.y / r * a * dt
            }
            let dc = ctx.cursor - bodies[i].pos, rc2 = hypot2(dc) + eps2, rc = sqrt(rc2)
            let ac = cursorMass / rc2
            v.x += dc.x / rc * ac * dt; v.y += dc.y / rc * ac * dt
            for pulse in pulses {
                let pd = bodies[i].pos - pulse.p, pdist = sqrt(hypot2(pd))
                if pdist < 220, pdist > 1 { let f = (1 - pdist / 220) * 220; v.x += pd.x / pdist * f * dt; v.y += pd.y / pdist * f * dt }
            }
            let sp2 = hypot2(v), vmax: CGFloat = 520
            if sp2 > vmax * vmax { let s = vmax / sqrt(sp2); v.x *= s; v.y *= s }
            bodies[i].vel = v
            var p = bodies[i].pos + v * dt
            // soft wrap to keep the dance on-screen
            if p.x < ctx.bounds.minX - 30 { p.x = ctx.bounds.maxX + 30; bodies[i].trail.removeAll() }
            if p.x > ctx.bounds.maxX + 30 { p.x = ctx.bounds.minX - 30; bodies[i].trail.removeAll() }
            if p.y < ctx.bounds.minY - 30 { p.y = ctx.bounds.maxY + 30; bodies[i].trail.removeAll() }
            if p.y > ctx.bounds.maxY + 30 { p.y = ctx.bounds.minY - 30; bodies[i].trail.removeAll() }
            bodies[i].pos = p
            bodies[i].trail.append(p)
            if bodies[i].trail.count > trailLen { bodies[i].trail.removeFirst(bodies[i].trail.count - trailLen) }
        }
    }

    func liveCount() -> Int { bodies.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        // Orbital trails (one contrast stroke per body).
        for b in bodies where b.trail.count >= 2 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: b.trail[0].x - origin.x, y: b.trail[0].y - origin.y))
            for k in 1..<b.trail.count { path.addLine(to: CGPoint(x: b.trail[k].x - origin.x, y: b.trail[k].y - origin.y)) }
            strokeContrast(ctx, path, width: 1.0, alpha: 0.32, coreColor: Self.trailCore)
        }
        // Bodies.
        for b in bodies {
            let r = b.size, cx = b.pos.x - origin.x, cy = b.pos.y - origin.y
            ctx.setBlendMode(.normal); ctx.setAlpha(0.88)
            ctx.draw(Self.cores[b.color % Self.cores.count], in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.5)
            let gr = r * 1.6
            ctx.draw(Self.glows[b.color % Self.glows.count], in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
