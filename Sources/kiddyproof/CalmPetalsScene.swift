import AppKit

// PETALS — calm blossoms drifting slowly down, flipping around their axis as they
// tumble. A keypress releases a petal; a click is a soft gust; SCROLL leans a wind
// that carries the whole fall diagonally; CLICK-AND-HOLD spins up a gentle whirlwind —
// petals caught in it spiral upward around a funnel until released to flutter down.
// Moving the mouse quickly tears a visible SLIPSTREAM through the air: wind streaks
// split around the cursor's path and nearby petals are brushed aside. No veil.
final class CalmPetalsScene: Scene {
    let name = "Petals"
    let category = SceneCategory.live
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Petal {
        var pos: NSPoint; var gust: NSPoint
        var angle: CGFloat; var angVel: CGFloat; var size: CGFloat
        var flip: CGFloat; var flipSpeed: CGFloat        // 3D tumble: height foreshortens as it turns edge-on
        var color: Int; var phase: CGFloat; var swaySpeed: CGFloat; var fall: CGFloat
    }
    private var petals: [Petal] = []
    private let ambientCount = 70
    private let maxPetals = 120
    private var rng = RNG(seed: 0x9E7A15)
    private var seededSize = CGSize.zero

    // Scroll-driven wind (stacks, decays back to still air).
    private var wind: CGFloat = 0

    // Whirlwind hold.
    private var holdLevel: CGFloat = 0

    // Slipstream: vapor wisps shed off both sides of a fast cursor's path — soft puffs
    // of torn air that curl outward, expand, and dissolve.
    private struct Wisp {
        var pos: NSPoint; var vel: NSPoint; var dir: NSPoint   // dir: stretch along the path
        var birth: TimeInterval; var life: Double
        var r0: CGFloat; var grow: CGFloat; var alpha0: CGFloat
    }
    private var wisps: [Wisp] = []
    private let maxWisps = 240
    private var lastWakePos = NSPoint.zero
    private var jetAudible = false

    // Saturated blossom tones — near-white petals vanish on a bright wallpaper.
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.35, blue: 0.55, alpha: 1),  // cherry
        NSColor(srgbRed: 1.0, green: 0.50, blue: 0.30, alpha: 1),   // coral
        NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1),   // warm gold
        NSColor(srgbRed: 0.64, green: 0.48, blue: 0.92, alpha: 1),  // lilac
    ]
    // Soft brush dabs + a dark bleed backing so the petals read on any wallpaper without
    // the old hard black edge.
    private static let inkStamps: [CGImage] = colors.map { inkSprite($0) }
    private static let inkDark = inkSprite(NSColor(white: 0, alpha: 1))
    private static let wispStamp = inkSprite(NSColor(srgbRed: 0.86, green: 0.95, blue: 1, alpha: 1))

    // The whirlwind breathes through the shared hum channel — a soft wind roar.
    var audioSwell: CGFloat { holdLevel * 0.35 }

    // Adaptive contrast cache (set each update; draw() has no context).
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    func reset() {
        petals.removeAll(keepingCapacity: true); seededSize = .zero
        wisps.removeAll(keepingCapacity: true); lastWakePos = .zero; jetAudible = false
        wind = 0; holdLevel = 0
        draining = false
    }

    private func newPetal(_ bounds: CGRect, atTop: Bool, at: NSPoint? = nil) -> Petal {
        var p = at ?? NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                              y: atTop ? bounds.maxY + rng.range(10, 80) : rng.range(bounds.minY, bounds.maxY))
        // With a standing wind, respawn biased upwind so the fall keeps crossing the screen.
        if atTop { p.x -= wind * rng.range(80, 240) }
        return Petal(pos: p, gust: .zero, angle: rng.range(0, 6.28), angVel: rng.range(-1.2, 1.2),
                     size: rng.range(14, 26),
                     flip: rng.range(0, 6.28), flipSpeed: rng.range(0.8, 2.0),
                     color: rng.int(Self.colors.count),
                     phase: rng.range(0, 6.28), swaySpeed: rng.range(0.5, 1.1), fall: rng.range(32, 60))
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard bounds.size != seededSize else { return }
        seededSize = bounds.size
        petals.removeAll(keepingCapacity: true)
        for _ in 0..<ambientCount { petals.append(newPetal(bounds, atTop: false)) }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            if petals.count < maxPetals {
                var pt = newPetal(ctx.bounds, atTop: false, at: ctx.cursor)
                pt.gust = NSPoint(x: rng.range(-40, 40), y: rng.range(30, 80))   // gentle puff up
                petals.append(pt)
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            for i in petals.indices {
                let d = petals[i].pos - pt
                let dist = sqrt(hypot2(d))
                if dist < 190, dist > 1 {
                    let f = (1 - dist / 190) * 140
                    petals[i].gust.x += d.x / dist * f
                    petals[i].gust.y += d.y / dist * f + 40
                    petals[i].angVel += rng.range(-2, 2)
                    petals[i].flipSpeed += rng.range(0.5, 1.5)
                }
            }
            ctx.audio?.whoosh()
        case .scroll(let dy):
            // The wind lever: leans the whole fall sideways; stacks and settles.
            wind = max(-1.6, min(1.6, wind + CGFloat(dy) * 0.15))
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        let dt = ctx.dt
        let now = ctx.now
        wind *= exp(-dt / 2.4)

        // Whirlwind hold level (quick to spin up, a beat slower to die down).
        if ctx.leftButtonDown && !draining { holdLevel += (1 - holdLevel) * min(1, dt * 2.8) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 2.5) }

        // Slipstream sampling: only a genuinely fast cursor tears the air. Wisps are
        // spawned by INTERPOLATING along the path segment travelled this frame — a
        // faster mouse covers more ground per frame, so per-frame spawning alone gets
        // gappy exactly when the effect should look its best. Each spawn point sheds a
        // pair of skinny vortex wisps that peel off opposite sides.
        let speed = sqrt(hypot2(ctx.cursorVel))
        if speed > 280 {
            let seg = ctx.cursor - lastWakePos
            let segLen = sqrt(hypot2(seg))
            if segLen > 14 {
                let dir = NSPoint(x: seg.x / segLen, y: seg.y / segLen)
                let perp = NSPoint(x: -dir.y, y: dir.x)
                let punch = min(1, speed / 1200)
                var s: CGFloat = 0
                while s < segLen {
                    let at = NSPoint(x: lastWakePos.x + dir.x * s, y: lastWakePos.y + dir.y * s)
                    for side in [CGFloat(1), -1] {
                        let lateral = (10 + 22 * punch) * side * rng.range(0.6, 1.4)
                        wisps.append(Wisp(
                            pos: at + NSPoint(x: perp.x * 3 * side, y: perp.y * 3 * side),
                            vel: NSPoint(x: perp.x * lateral - dir.x * 40, y: perp.y * lateral - dir.y * 40),
                            dir: dir,
                            birth: now, life: Double(rng.range(1.0, 1.6)),
                            r0: 3 + 3 * punch, grow: rng.range(10, 18),
                            alpha0: 0.26 + 0.2 * punch))
                    }
                    s += 14
                }
                lastWakePos = ctx.cursor
                if wisps.count > maxWisps { wisps.removeFirst(wisps.count - maxWisps) }
            }
        } else {
            lastWakePos = ctx.cursor   // never interpolate across a slow gap
        }
        if speed > 1100 {
            if !jetAudible { jetAudible = true; ctx.audio?.whoosh() }
        } else if speed < 500 { jetAudible = false }
        for i in wisps.indices {
            wisps[i].pos = wisps[i].pos + wisps[i].vel * dt
            wisps[i].vel.x *= exp(-2.6 * dt); wisps[i].vel.y *= exp(-2.6 * dt)
        }
        wisps.removeAll { now - $0.birth >= $0.life }

        let cur = ctx.cursor
        for i in petals.indices {
            petals[i].gust.x *= exp(-2.2 * dt); petals[i].gust.y *= exp(-2.2 * dt)

            // Slipstream force: the jet CUTS through the fall — petals in the path are
            // blasted along the direction of travel and thrown hard to whichever side
            // of the path they sit on, spinning violently as they go.
            if speed > 280 {
                let d = petals[i].pos - cur
                let dist = sqrt(hypot2(d))
                if dist < 150, dist > 1 {
                    let dirx = ctx.cursorVel.x / speed, diry = ctx.cursorVel.y / speed
                    let sideSign: CGFloat = (dirx * d.y - diry * d.x) >= 0 ? 1 : -1
                    let f = (1 - dist / 150) * min(700, speed * 0.9)
                    petals[i].gust.x += (dirx * 0.55 + (-diry) * sideSign * 0.45) * f * dt * 9
                    petals[i].gust.y += (diry * 0.55 + dirx * sideSign * 0.45) * f * dt * 9
                    petals[i].flipSpeed = min(9, petals[i].flipSpeed + 9 * dt)
                    petals[i].angVel += rng.range(-4, 4) * dt * 10
                }
            }

            // Whirlwind: a funnel around the held cursor — tangential spin (one shared
            // direction), a pull toward the funnel wall (wider higher up), real lift.
            if holdLevel > 0.05 {
                let d = cur - petals[i].pos
                let dist = sqrt(hypot2(d))
                if dist < 360, dist > 1 {
                    let n = NSPoint(x: d.x / dist, y: d.y / dist)
                    let height = max(0, petals[i].pos.y - cur.y)
                    let funnelR = 36 + height * 0.28
                    let radialErr = dist - funnelR
                    let desired = NSPoint(
                        x: (-n.y) * (215 * holdLevel) + n.x * radialErr * 2.0,
                        y: n.x * (215 * holdLevel) + n.y * radialErr * 2.0 + 90 * holdLevel)
                    petals[i].gust.x += (desired.x - petals[i].gust.x) * min(1, dt * 4.5)
                    petals[i].gust.y += (desired.y - petals[i].gust.y) * min(1, dt * 4.5)
                    petals[i].flipSpeed = min(7, petals[i].flipSpeed + 3.5 * dt)
                    petals[i].angVel += (2.2 - petals[i].angVel) * dt
                }
            }

            let vx = CGFloat(sin(now * Double(petals[i].swaySpeed) + Double(petals[i].phase))) * 26
                + petals[i].gust.x + wind * 70
            let vy = -petals[i].fall + petals[i].gust.y
            petals[i].pos.x += vx * dt
            petals[i].pos.y += vy * dt
            petals[i].angle += petals[i].angVel * dt
            petals[i].flip += petals[i].flipSpeed * dt
            petals[i].flipSpeed += (rng.range(0.8, 2.0) - petals[i].flipSpeed) * dt * 0.4  // settle back to a lazy tumble
            // recycle to the top once below the screen
            if petals[i].pos.y < ctx.bounds.minY - 40 {
                petals[i] = newPetal(ctx.bounds, atTop: true)
            }
            if petals[i].pos.x < ctx.bounds.minX - 40 { petals[i].pos.x = ctx.bounds.maxX + 40 }
            if petals[i].pos.x > ctx.bounds.maxX + 40 { petals[i].pos.x = ctx.bounds.minX - 40 }
        }
    }

    func liveCount() -> Int { petals.count + wisps.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let now = CACurrentMediaTime()
        drawSlipstream(into: ctx, origin: origin, now: now)

        ctx.setBlendMode(.normal)
        for p in petals {
            // A soft brush dab squashed into a petal and rotated. The FLIP phase
            // foreshortens the height as the petal turns edge-on — the 3D tumble that
            // makes them read as falling blossoms instead of rotating stickers.
            let flip = 0.35 + 0.65 * abs(sin(p.flip))
            let w = p.size * 1.25, h = p.size * 0.7 * flip
            let shade = 0.75 + 0.25 * flip                       // slightly dimmer edge-on
            // Adaptive: over bright pixels the dark edge firms up and the body gets a
            // densifying second stamp; over dark ones the petal stays airy.
            let iw = inkWeight(bgMap, bgFallback, p.pos)
            ctx.saveGState()
            ctx.translateBy(x: p.pos.x - origin.x, y: p.pos.y - origin.y)
            ctx.rotate(by: p.angle)
            ctx.setAlpha(0.3 + 0.35 * iw)
            ctx.draw(Self.inkDark, in: CGRect(x: -w * 0.6, y: -h * 0.62, width: w * 1.2, height: h * 1.24))
            ctx.setAlpha(0.92 * shade)
            ctx.draw(Self.inkStamps[p.color % Self.inkStamps.count], in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            if iw > 0.05 {   // densify: soft ink alone can't hold color over white
                ctx.setAlpha(0.6 * shade * iw)
                ctx.draw(Self.inkStamps[p.color % Self.inkStamps.count], in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            }
            ctx.setAlpha(0.6 * shade)                            // tip highlight → teardrop
            let tw = w * 0.5
            ctx.draw(Self.inkStamps[p.color % Self.inkStamps.count], in: CGRect(x: w * 0.18 - tw / 2, y: -h * 0.4, width: tw, height: h * 0.8))
            ctx.restoreGState()
        }
        ctx.setAlpha(1)
    }

    // The jet's wake: shed vortex puffs — each one expands, drifts away from the path,
    // and dissolves. Overlapping puffs of different ages read as a smooth vapor trail
    // (no polylines, no kinks), and each fades on its own clock.
    private func drawSlipstream(into ctx: CGContext, origin: CGPoint, now: TimeInterval) {
        guard !wisps.isEmpty else { return }
        ctx.setBlendMode(.normal)
        for w in wisps {
            let t = CGFloat((now - w.birth) / w.life)
            guard t >= 0, t < 1 else { continue }
            let a = w.alpha0 * (1 - t) * (1 - t)
            guard a > 0.015 else { continue }
            let r = w.r0 + w.grow * t
            // Whispy: each puff is STRETCHED along the direction of travel, so the
            // dense overlapping chain reads as continuous vapor filaments, not dots.
            let iw = inkWeight(bgMap, bgFallback, w.pos)
            ctx.saveGState()
            ctx.translateBy(x: w.pos.x - origin.x, y: w.pos.y - origin.y)
            ctx.rotate(by: atan2(w.dir.y, w.dir.x))
            let lw = r * 2.8, lh = r * 1.0
            ctx.setAlpha(a * (0.25 + 0.5 * iw))   // dark breath firms up over bright pixels
            ctx.draw(Self.inkDark, in: CGRect(x: -lw * 0.56, y: -lh * 0.6, width: lw * 1.12, height: lh * 1.2))
            ctx.setAlpha(a)
            ctx.draw(Self.wispStamp, in: CGRect(x: -lw / 2, y: -lh / 2, width: lw, height: lh))
            ctx.restoreGState()
        }
        ctx.setAlpha(1)
    }
}
