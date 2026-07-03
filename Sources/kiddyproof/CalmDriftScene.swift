import AppKit

// DRIFT — the first calm scene. Soft glowing orbs drift slowly through a deep night;
// the cursor gently gathers nearby ones; a keypress releases a firefly that rises and
// joins the drift; a click blooms a soft ring of light. Everything is slow, low-contrast,
// and additively soft. Reactivity is capped low so a frantic mash never makes it busy.
final class CalmDriftScene: Scene {
    let name = "Drift"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0             // no dimming — effects read on any wallpaper via contrast sprites
    var draining = false

    private struct Orb {
        var pos: NSPoint; var vel: NSPoint
        var radius: CGFloat; var color: Int; var baseAlpha: CGFloat; var phase: CGFloat
        var life: Double; var birth: TimeInterval; var ambient: Bool
    }
    private struct Bloom { var pos: NSPoint; let birth: TimeInterval; let life: Double; let color: Int; let seed: CGFloat }

    private var orbs: [Orb] = []
    private var blooms: [Bloom] = []
    private let ambientCount = 60
    private let maxOrbs = 150
    private var rng = RNG(seed: 0xD21F7)
    private var seededSize = CGSize.zero

    // Soft pastel firefly palette + pre-rendered soft-dot sprites (built once).
    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.90, blue: 0.62, alpha: 1),   // pale gold
        NSColor(srgbRed: 1.0, green: 0.78, blue: 0.45, alpha: 1),   // warm amber
        NSColor(srgbRed: 0.95, green: 0.97, blue: 1.0, alpha: 1),   // soft white
        NSColor(srgbRed: 0.6, green: 0.88, blue: 1.0, alpha: 1),    // pale cyan
        NSColor(srgbRed: 1.0, green: 0.8, blue: 0.88, alpha: 1),    // soft rose
    ]
    // Contrast cores (readable on any wallpaper) + additive glows (extra pop on dark).
    private static let cores: [CGImage] = swatches.map { softContrastSprite($0) }
    private static let glows: [CGImage] = swatches.map { softGlowSprite($0) }

    func reset() {
        orbs.removeAll(keepingCapacity: true)
        blooms.removeAll(keepingCapacity: true)
        seededSize = .zero
        draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard bounds.size != seededSize else { return }
        seededSize = bounds.size
        orbs.removeAll(keepingCapacity: true)
        for _ in 0..<ambientCount {
            orbs.append(Orb(pos: NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                                         y: rng.range(bounds.minY, bounds.maxY)),
                            vel: NSPoint(x: rng.range(-12, 12), y: rng.range(-12, 12)),
                            radius: rng.range(6, 20), color: rng.int(Self.cores.count),
                            baseAlpha: rng.range(0.42, 0.68), phase: rng.range(0, 6.28),
                            life: 0, birth: 0, ambient: true))
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            // Release a firefly that rises gently and joins the drift.
            if orbs.count < maxOrbs {
                orbs.append(Orb(pos: ctx.cursor + NSPoint(x: rng.range(-20, 20), y: rng.range(-20, 20)),
                                vel: NSPoint(x: rng.range(-10, 10), y: rng.range(8, 26)),
                                radius: rng.range(9, 16), color: rng.int(Self.cores.count),
                                baseAlpha: rng.range(0.5, 0.85), phase: rng.range(0, 6.28),
                                life: Double(rng.range(7, 11)), birth: ctx.now, ambient: false))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            blooms.append(Bloom(pos: pt, birth: ctx.now, life: 1.8, color: rng.int(Self.cores.count), seed: rng.range(0, 6.28)))
            ctx.audio?.whoosh()
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        let dt = ctx.dt
        let cur = ctx.cursor
        let attract = 45 + 90 * ctx.intensity      // gentle gather toward the cursor

        var i = 0
        while i < orbs.count {
            if !orbs[i].ambient, ctx.now - orbs[i].birth >= orbs[i].life { orbs.remove(at: i); continue }
            var v = orbs[i].vel
            v.x += rng.range(-7, 7) * dt           // soft brownian wander
            v.y += rng.range(-7, 7) * dt
            if !orbs[i].ambient { v.y += 6 * dt }   // fireflies rise slightly
            // gentle attraction toward the cursor when nearby
            let d = cur - orbs[i].pos
            let dist2 = hypot2(d)
            if dist2 > 25, dist2 < 320 * 320 {
                let dist = sqrt(dist2)
                let f = attract / max(70, dist)
                v.x += d.x / dist * f * dt
                v.y += d.y / dist * f * dt
            }
            v.x *= exp(-0.7 * dt); v.y *= exp(-0.7 * dt)   // damping keeps it slow
            let sp2 = hypot2(v)
            if sp2 > 55 * 55 { let s = 55 / sqrt(sp2); v.x *= s; v.y *= s }
            orbs[i].vel = v
            var p = orbs[i].pos + v * dt
            // toroidal wrap so ambient orbs never disappear
            if p.x < ctx.bounds.minX - 40 { p.x = ctx.bounds.maxX + 40 }
            if p.x > ctx.bounds.maxX + 40 { p.x = ctx.bounds.minX - 40 }
            if p.y < ctx.bounds.minY - 40 { p.y = ctx.bounds.maxY + 40 }
            if p.y > ctx.bounds.maxY + 40 { p.y = ctx.bounds.minY - 40 }
            orbs[i].pos = p
            i += 1
        }

        blooms.removeAll { ctx.now - $0.birth >= $0.life }
    }

    func liveCount() -> Int { orbs.count + blooms.count }

    // Each glow is two passes: a contrast core (normal blend, reads on any wallpaper)
    // and an additive bloom (extra glow on dark, harmless on light).
    private func blit(_ ctx: CGContext, _ color: Int, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a: CGFloat) {
        let core = Self.cores[color % Self.cores.count]
        let glow = Self.glows[color % Self.glows.count]
        ctx.setBlendMode(.normal); ctx.setAlpha(a)
        ctx.draw(core, in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.setBlendMode(.plusLighter); ctx.setAlpha(a * 0.5)
        let gr = r * 1.25
        ctx.draw(glow, in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        // Effects only — no background; the parent's real screen is behind us.
        let now = CACurrentMediaTime()

        // Click blooms: a billowing ink puff — an expanding bleeding ring plus a soft
        // fading center, like ink dropped into the dark.
        for b in blooms {
            let t = CGFloat((now - b.birth) / b.life)
            let a = (1 - t) * 0.5
            guard a > 0.01 else { continue }
            let cx = b.pos.x - origin.x, cy = b.pos.y - origin.y
            let radius = 24 + t * 150
            ctx.setBlendMode(.normal); ctx.setAlpha(a)
            inkRing(ctx, cx: cx, cy: cy, radius: radius, dab: 9 + t * 16,
                    stamp: Self.cores[b.color % Self.cores.count], seed: b.seed, wobble: 0.07 + 0.05 * t)
            blit(ctx, b.color, cx, cy, 22 + t * 30, a * 0.45)
        }
        ctx.setBlendMode(.normal); ctx.setAlpha(1)

        // Drifting orbs.
        for o in orbs {
            let shimmer = 0.7 + 0.3 * CGFloat(sin(now * 0.8 + Double(o.phase)))
            var a = o.baseAlpha * shimmer
            if !o.ambient {
                let age = now - o.birth
                a *= min(1, CGFloat(age / 0.9)) * max(0, min(1, CGFloat((o.life - age) / 1.6)))
            }
            guard a > 0.01 else { continue }
            blit(ctx, o.color, o.pos.x - origin.x, o.pos.y - origin.y, o.radius, a)
        }

        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }
}
