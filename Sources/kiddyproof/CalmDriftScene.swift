import AppKit

// DRIFT — the first calm scene. Soft glowing fireflies drift through a deep night in
// three parallax layers; a keypress releases a firefly that rises and joins the drift;
// a click blooms a soft ink ring; SCROLL sends a gentle breeze swaying the whole field;
// CLICK-AND-HOLD cups your hands — nearby fireflies spiral into a glowing cluster, and
// letting go releases them upward in a soft scatter. Everything is slow, low-contrast,
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
        var shimmerHz: CGFloat        // per-orb pulse rate — a field of metronomes reads fake
        var tier: Int                 // 0 = far back, 1 = mid, 2 = front (parallax)
        var gather: CGFloat           // 0…1 how captured by the cupped-hands hold
        var life: Double; var birth: TimeInterval; var ambient: Bool
    }
    // A click sends a wave of light THROUGH the field: fireflies brighten as the
    // front passes them (plus a tiny outward nudge), and a soft flash marks the origin.
    private struct Pulse { var pos: NSPoint; let birth: TimeInterval; let color: Int }
    private static let pulseLife: Double = 3.4
    private static let pulseSpeed: CGFloat = 430     // px/s wavefront
    // The crest widens as it travels, so the ring stays populated with lit fireflies
    // even when its circumference is huge — this is what lets the wave read all the
    // way across the screen instead of dying near the click.
    private static func pulseBand(front: CGFloat) -> CGFloat { 120 + front * 0.2 }
    private static func crest(_ dist: CGFloat, _ front: CGFloat) -> CGFloat {
        let x = (dist - front) / pulseBand(front: front)
        return abs(x) < 1 ? (1 - x * x) : 0
    }

    private var orbs: [Orb] = []
    private var pulses: [Pulse] = []
    private let ambientPerTier = [26, 20, 14]     // back → front (back is denser, dimmer)
    private let maxOrbs = 150
    private var rng = RNG(seed: 0xD21F7)
    private var seededSize = CGSize.zero

    // Breeze: scroll accumulates a horizontal gust that sways the field and decays.
    private var breeze: CGFloat = 0
    private var breezeAudible = false

    // Cupped-hands hold state.
    private var holding = false
    private var holdLevel: CGFloat = 0            // eases 0→1 while held (drives glow + swell)

    // Parallax tuning per tier: how much of the wind/attraction/speed each layer feels.
    private static let tierWind: [CGFloat] = [0.35, 0.7, 1.0]
    private static let tierSpeedCap: [CGFloat] = [26, 42, 55]

    // Firefly palette: calm but SATURATED mid-luminance tones — pale pastels (and any
    // near-white) wash out completely on a bright wallpaper.
    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1),   // gold
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.28, alpha: 1),   // amber
        NSColor(srgbRed: 0.36, green: 0.72, blue: 1.0, alpha: 1),   // sky
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.72, alpha: 1),   // rose
        NSColor(srgbRed: 0.72, green: 0.60, blue: 1.0, alpha: 1),   // lavender
    ]
    // Contrast cores (readable on any wallpaper) + additive glows (extra pop on dark).
    private static let cores: [CGImage] = swatches.map { softContrastSprite($0) }
    private static let glows: [CGImage] = swatches.map { softGlowSprite($0) }

    // The gathering hold drives a soft continuous hum (same channel the black hole
    // swells, at a fraction of its level — a whisper, not suction).
    var audioSwell: CGFloat { holdLevel * 0.3 }

    func reset() {
        orbs.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        seededSize = .zero
        breeze = 0; breezeAudible = false
        holding = false; holdLevel = 0
        draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard bounds.size != seededSize else { return }
        seededSize = bounds.size
        orbs.removeAll(keepingCapacity: true)
        // Seed back-to-front so array order doubles as draw order (back painted first).
        for tier in 0..<3 {
            for _ in 0..<ambientPerTier[tier] {
                orbs.append(makeAmbient(tier: tier, bounds: bounds))
            }
        }
    }

    private func makeAmbient(tier: Int, bounds: CGRect) -> Orb {
        // Depth cues: back = small, dim, slow; front = large, bright, lively.
        let radius: CGFloat, alpha: (CGFloat, CGFloat), drift: CGFloat
        switch tier {
        case 0: radius = rng.range(4, 9);   alpha = (0.32, 0.48); drift = 6
        case 1: radius = rng.range(8, 15);  alpha = (0.5, 0.68); drift = 10
        default: radius = rng.range(13, 22); alpha = (0.65, 0.88); drift = 13
        }
        return Orb(pos: NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                                y: rng.range(bounds.minY, bounds.maxY)),
                   vel: NSPoint(x: rng.range(-drift, drift), y: rng.range(-drift, drift)),
                   radius: radius, color: rng.int(Self.cores.count),
                   baseAlpha: rng.range(alpha.0, alpha.1), phase: rng.range(0, 6.28),
                   shimmerHz: rng.range(0.4, 1.2), tier: tier, gather: 0,
                   life: 0, birth: 0, ambient: true)
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            // Release a firefly that rises gently and joins the drift (front layer).
            if orbs.count < maxOrbs {
                orbs.append(Orb(pos: ctx.cursor + NSPoint(x: rng.range(-20, 20), y: rng.range(-20, 20)),
                                vel: NSPoint(x: rng.range(-10, 10), y: rng.range(8, 26)),
                                radius: rng.range(9, 16), color: rng.int(Self.cores.count),
                                baseAlpha: rng.range(0.5, 0.85), phase: rng.range(0, 6.28),
                                shimmerHz: rng.range(0.7, 1.4), tier: 2, gather: 0,
                                life: Double(rng.range(7, 11)), birth: ctx.now, ambient: false))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            pulses.append(Pulse(pos: pt, birth: ctx.now, color: rng.int(Self.cores.count)))
            ctx.audio?.whoosh()
        case .scroll(let dy):
            // A breeze that builds: gust strength follows the scroll size, and repeated
            // scrolling STACKS (up to a firm-but-calm ceiling) before decaying away.
            breeze = max(-1.8, min(1.8, breeze + CGFloat(dy) * 0.2))
            if abs(breeze) > 0.35 && !breezeAudible {
                breezeAudible = true
                ctx.audio?.whoosh()
            }
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        let dt = ctx.dt
        let cur = ctx.cursor

        // Hold state: ease the gather level in/out; on release, scatter the cluster.
        let wasHolding = holding
        holding = ctx.leftButtonDown
        if holding { holdLevel += (1 - holdLevel) * min(1, dt * 2.2) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 3.5) }
        if wasHolding && !holding { releaseGathered(ctx) }

        // Breeze decays (slowly enough that a sustained gust carries); below the audio
        // threshold it can chime again on the next gust.
        breeze *= exp(-dt / 1.6)
        if abs(breeze) < 0.2 { breezeAudible = false }

        let attract = 45 + 90 * ctx.intensity      // gentle ambient gather toward the cursor

        var i = 0
        while i < orbs.count {
            if !orbs[i].ambient, ctx.now - orbs[i].birth >= orbs[i].life { orbs.remove(at: i); continue }
            let tier = orbs[i].tier
            var v = orbs[i].vel
            v.x += rng.range(-7, 7) * dt           // soft brownian wander
            v.y += rng.range(-7, 7) * dt
            if !orbs[i].ambient { v.y += 6 * dt }   // fireflies rise slightly

            // Breeze: horizontal sway, felt more by nearer layers, slightly uneven per
            // orb (phase) so the field ripples instead of sliding as one sheet.
            let sway = 0.75 + 0.25 * CGFloat(sin(Double(orbs[i].phase) * 2.1))
            v.x += breeze * 55 * Self.tierWind[tier] * sway * dt
            v.y += breeze * 10 * Self.tierWind[tier] * CGFloat(sin(Double(orbs[i].phase))) * dt

            // Light waves push a little as they pass (the visual boost lives in draw).
            for p in pulses {
                let pd = orbs[i].pos - p.pos
                let pdist = sqrt(hypot2(pd)) + 0.001
                let front = Self.pulseSpeed * CGFloat(ctx.now - p.birth)
                let c = Self.crest(pdist, front)
                if c > 0 {
                    // A ripple, not a shove: the wave's real presence is the brightness
                    // ignition — a strong push just herds the whole field to the walls.
                    let push = c * 14 * Self.tierWind[tier]
                    v.x += pd.x / pdist * push * dt
                    v.y += pd.y / pdist * push * dt
                }
            }

            // Wall breath: a gentle inward pressure near every edge, so drift, gusts,
            // and wave pushes can never thin the middle out or pile the field up dead
            // against the borders.
            let breath: CGFloat = 70
            if orbs[i].pos.x < ctx.bounds.minX + breath { v.x += 20 * (1 - (orbs[i].pos.x - ctx.bounds.minX) / breath) * dt }
            if orbs[i].pos.x > ctx.bounds.maxX - breath { v.x -= 20 * (1 - (ctx.bounds.maxX - orbs[i].pos.x) / breath) * dt }
            if orbs[i].pos.y < ctx.bounds.minY + breath { v.y += 20 * (1 - (orbs[i].pos.y - ctx.bounds.minY) / breath) * dt }
            if orbs[i].pos.y > ctx.bounds.maxY - breath { v.y -= 20 * (1 - (ctx.bounds.maxY - orbs[i].pos.y) / breath) * dt }

            let d = cur - orbs[i].pos
            let dist2 = hypot2(d)

            if holding && tier > 0 && dist2 < 300 * 300 && dist2 > 1 {
                // Cupped hands: spiral nearby mid/front fireflies into a soft orbit.
                let dist = sqrt(dist2)
                let n = NSPoint(x: d.x / dist, y: d.y / dist)
                let orbitR = 46 + orbs[i].radius * 1.6
                let pull = (dist - orbitR) * 1.5 * holdLevel
                v.x += n.x * pull * dt
                v.y += n.y * pull * dt
                let swirl = (34 + 26 * holdLevel) * (orbs[i].phase > 3.14 ? 1 : -1) // mixed directions
                v.x += -n.y * swirl * dt
                v.y += n.x * swirl * dt
                orbs[i].gather += (1 - orbs[i].gather) * min(1, dt * 2.5)
            } else {
                orbs[i].gather += (0 - orbs[i].gather) * min(1, dt * 1.8)
                // gentle ambient attraction toward the cursor when nearby (mid/front)
                if tier > 0, dist2 > 25, dist2 < 320 * 320 {
                    let dist = sqrt(dist2)
                    let f = attract / max(70, dist)
                    v.x += d.x / dist * f * dt
                    v.y += d.y / dist * f * dt
                }
            }

            v.x *= exp(-0.7 * dt); v.y *= exp(-0.7 * dt)   // damping keeps it slow
            let cap = Self.tierSpeedCap[tier] * (1 + 0.5 * orbs[i].gather) // gathering may hurry a little
            let sp2 = hypot2(v)
            if sp2 > cap * cap { let s = cap / sqrt(sp2); v.x *= s; v.y *= s }
            var p = orbs[i].pos + v * dt
            // Never lose a firefly: every edge is a soft bounce. (Wrapping was tried and
            // scrapped: re-entry placed orbs just outside the far edge, where outward
            // pushes ping-ponged them invisibly between the two off-screen bands.)
            let r = orbs[i].radius
            if p.x < ctx.bounds.minX + r, v.x < 0 { p.x = ctx.bounds.minX + r; v.x *= -0.4 }
            if p.x > ctx.bounds.maxX - r, v.x > 0 { p.x = ctx.bounds.maxX - r; v.x *= -0.4 }
            if p.y < ctx.bounds.minY + r, v.y < 0 { p.y = ctx.bounds.minY + r; v.y *= -0.4 }
            if p.y > ctx.bounds.maxY - r, v.y > 0 { p.y = ctx.bounds.maxY - r; v.y *= -0.4 }
            orbs[i].vel = v
            orbs[i].pos = p
            i += 1
        }

        pulses.removeAll { ctx.now - $0.birth >= Self.pulseLife }
    }

    // Letting go: the gathered cluster drifts up and apart, like startled fireflies —
    // gentle (speed-capped), with one soft exhale.
    private func releaseGathered(_ ctx: EffectContext) {
        var releasedAny = false
        for i in orbs.indices where orbs[i].gather > 0.25 {
            releasedAny = true
            let g = orbs[i].gather
            orbs[i].vel.x += rng.range(-26, 26) * g
            orbs[i].vel.y += rng.range(20, 48) * g
        }
        if releasedAny && holdLevel > 0.35 { ctx.audio?.burst() }
    }

    func liveCount() -> Int { orbs.count + pulses.count }

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

        // Click origin: one soft, quick flash — the wave itself is carried by the
        // fireflies below, not by drawn geometry.
        for p in pulses {
            let t = CGFloat((now - p.birth) / 0.55)
            guard t < 1 else { continue }
            let a = (1 - t) * (1 - t) * 0.55
            blit(ctx, p.color, p.pos.x - origin.x, p.pos.y - origin.y, 20 + t * 26, a)
        }
        ctx.setBlendMode(.normal); ctx.setAlpha(1)

        // Drifting orbs (array is back-to-front, so painter's order gives depth).
        for o in orbs {
            let shimmer = 0.7 + 0.3 * CGFloat(sin(now * Double(o.shimmerHz) * 2 * .pi + Double(o.phase)))
            var a = o.baseAlpha * shimmer

            // Light waves: each firefly brightens as a wavefront passes it — the field
            // itself IS the click effect, sparkling outward from the tap. The fade is
            // gentle (sqrt) so the crest still clearly ignites fireflies at the far
            // edge of the screen before it dies.
            var wave: CGFloat = 0
            for p in pulses {
                let d = o.pos - p.pos
                let front = Self.pulseSpeed * CGFloat(now - p.birth)
                let c = Self.crest(sqrt(hypot2(d)), front)
                if c > 0 {
                    let fade = CGFloat(max(0, 1 - (now - p.birth) / Self.pulseLife)).squareRoot()
                    wave = max(wave, c * fade)
                }
            }

            if !o.ambient {
                let age = now - o.birth
                a *= min(1, CGFloat(age / 0.9)) * max(0, min(1, CGFloat((o.life - age) / 1.6)))
            }
            // Gathered fireflies glow warmer/brighter in the cupped hands; a passing
            // light wave IGNITES them — dim background fireflies jump to near-full
            // brightness (floor), which is what makes the wave read at distance.
            a = min(1, a * (1 + 0.6 * o.gather + 0.9 * wave))
            a = max(a, wave * 0.85)
            guard a > 0.01 else { continue }
            let r = o.radius * (1 + 0.18 * o.gather + 0.3 * wave)
            blit(ctx, o.color, o.pos.x - origin.x, o.pos.y - origin.y, r, a)
        }

        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }
}
