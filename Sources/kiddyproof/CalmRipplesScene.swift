import AppKit

// RIPPLES — calm concentric waves spreading like raindrops on a still pond. A gentle
// ambient rain drops occasional ripples (SCROLL turns the weather up or down); the
// cursor leaves a soft wake; a keypress drops a ripple; a click sends a larger double
// ring; CLICK-AND-HOLD rests a fingertip on the water — slow heartbeat rings emanate
// until the finger lifts with one larger farewell ring. Rings are drawn as smooth
// crest+echo strokes (a bright caustic line over a dark casing) so they read as water
// on any wallpaper — not chalk. No veil.
final class CalmRipplesScene: Scene {
    let name = "Ripples"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Ripple { let center: NSPoint; let birth: TimeInterval; let life: Double; let maxR: CGFloat; let color: Int; let width: CGFloat }
    private var ripples: [Ripple] = []
    private let maxRipples = 60
    private var rng = RNG(seed: 0x21FF1E)
    private var ambientAccum: Double = 0
    private var lastWake = NSPoint.zero
    private var lastKeyDrop: TimeInterval = 0

    // Weather: scroll leans the rain heavier (+) or calmer (−); eases back to a drizzle.
    private var storm: CGFloat = 0

    // Fingertip hold: rhythmic heartbeat rings while the button rests on the water.
    private var holding = false
    private var holdLevel: CGFloat = 0
    private var nextHeartbeat: TimeInterval = 0

    // Saturated pond tones — pale/near-white inks vanish on a bright wallpaper.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.42, green: 0.72, blue: 1.0, alpha: 1),   // clear blue
        NSColor(srgbRed: 0.30, green: 0.60, blue: 0.95, alpha: 1),  // deep sky
        NSColor(srgbRed: 0.35, green: 0.85, blue: 0.80, alpha: 1),  // teal
        NSColor(srgbRed: 0.60, green: 0.62, blue: 1.0, alpha: 1),   // periwinkle
    ]
    // Soft impact dimple at each drop's birth.
    private static let dimples: [CGImage] = palette.map { softContrastSprite($0) }
    // Interference glint: where two crests cross, the water catches the light.
    private static let glintColor = NSColor(srgbRed: 0.55, green: 0.88, blue: 1.0, alpha: 1)
    private static let glintCore = softContrastSprite(glintColor)
    private static let glintGlow = softGlowSprite(glintColor)
    private static let glintDark = inkSprite(NSColor(white: 0, alpha: 1))

    var audioSwell: CGFloat { holdLevel * 0.25 }

    // Adaptive contrast cache (set each update; draw() has no context).
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    func reset() {
        ripples.removeAll(keepingCapacity: true); ambientAccum = 0
        storm = 0; holding = false; holdLevel = 0; nextHeartbeat = 0
        lastKeyDrop = 0
        draining = false; lastWake = .zero   // a stale drain flag would leave the scene input-dead
    }

    private func drop(_ center: NSPoint, _ now: TimeInterval, life: Double, maxR: CGFloat, width: CGFloat, concentric: Bool) {
        guard ripples.count < maxRipples else { return }
        let c = rng.int(Self.palette.count)
        ripples.append(Ripple(center: center, birth: now, life: life, maxR: maxR, color: c, width: width))
        if concentric, ripples.count < maxRipples {
            ripples.append(Ripple(center: center, birth: now + 0.22, life: life, maxR: maxR * 0.62, color: c, width: width * 0.8))
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            // Coalesce a mash: rings closer than 70ms apart are imperceptible as
            // separate drops but multiply the worst-case draw load.
            if ctx.now - lastKeyDrop >= 0.07 {
                lastKeyDrop = ctx.now
                drop(ctx.cursor, ctx.now, life: 1.8, maxR: rng.range(80, 130), width: 1.6, concentric: false)
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            drop(pt, ctx.now, life: 2.6, maxR: rng.range(170, 240), width: 2.2, concentric: true)
            ctx.audio?.drip(intensity: 0.9)
        case .scroll(let dy):
            // The weather lever: rain thickens or calms with scroll size and stacks.
            storm = max(-1, min(1, storm + CGFloat(dy) * 0.08))
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        let now = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        storm *= exp(-CGFloat(ctx.dt) / 10)   // weather eases back to a drizzle

        // Fingertip hold: heartbeat rings from the resting point.
        let wasHolding = holding
        holding = ctx.leftButtonDown && !draining
        if holding { holdLevel += (1 - holdLevel) * min(1, ctx.dt * 2.5) }
        else { holdLevel += (0 - holdLevel) * min(1, ctx.dt * 4) }
        if holding && !wasHolding { nextHeartbeat = now + 0.5 }   // first ring came from the click
        if holding, now >= nextHeartbeat {
            nextHeartbeat = now + 0.6
            drop(ctx.cursor, now, life: 2.0, maxR: 120 + 50 * holdLevel, width: 1.8, concentric: false)
            ctx.audio?.drip(intensity: 0.35)   // quiet heartbeat drops
        }
        if wasHolding && !holding && holdLevel > 0.3 {
            // The finger lifts off: one larger farewell ring and a fuller bloop.
            drop(ctx.cursor, now, life: 3.0, maxR: 260, width: 2.4, concentric: true)
            ctx.audio?.drip(intensity: 1.0)
        }

        if !draining {
            // Ambient rain, throttled or thickened by the weather.
            ambientAccum += ctx.dt
            var interval = 1.4 - 0.6 * Double(ctx.intensity)
            if storm > 0 { interval /= Double(1 + 2.4 * storm) }        // shower
            if storm < 0 { interval *= Double(1 - 2.2 * storm) }        // near-stillness
            if ambientAccum >= interval {
                ambientAccum = 0
                let p = NSPoint(x: rng.range(ctx.bounds.minX, ctx.bounds.maxX),
                                y: rng.range(ctx.bounds.minY, ctx.bounds.maxY))
                let size = 1 + 0.35 * max(0, storm)
                drop(p, now, life: 2.4, maxR: rng.range(110, 190) * size, width: 1.6, concentric: false)
            }
            // Soft cursor wake.
            if sqrt(hypot2(ctx.cursor - lastWake)) > 44 {
                lastWake = ctx.cursor
                drop(ctx.cursor, now, life: 1.4, maxR: rng.range(50, 80), width: 1.2, concentric: false)
            }
        }
        ripples.removeAll { now - $0.birth >= $0.life }
    }

    func liveCount() -> Int { ripples.count }

    // A bolder sibling of strokeContrast for water rings: wide deep-toned colored
    // casing (reads as saturated ink on light wallpaper) beneath a bright crest core
    // (carries the glow on dark wallpaper). With adaptive contrast, `w` tunes the
    // ring for the pixels behind it: over bright windows the casing deepens and the
    // crest drops its white lift (pure saturated ink); over dark ones the casing
    // recedes and the crest brightens.
    private func waterStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, alpha: CGFloat, color: NSColor, _ w: CGFloat) {
        guard alpha > 0.01 else { return }
        ctx.setBlendMode(.normal)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.setLineWidth(width + 3.0)
        ctx.setStrokeColor(blendColor(color, .black, 0.4 + 0.25 * w)
            .withAlphaComponent(min(1, alpha * (0.6 + 0.4 * w))).cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(blendColor(color, .white, 0.42 * (1 - w))
            .withAlphaComponent(min(1, alpha)).cgColor)
        ctx.strokePath()
    }

    // Current crest radius + alpha for a ripple (shared by draw and the glint pass).
    private func crestState(_ r: Ripple, _ now: TimeInterval) -> (radius: CGFloat, alpha: CGFloat)? {
        let age = now - r.birth
        guard age >= 0 else { return nil }
        let t = CGFloat(age / r.life)
        let radius = r.maxR * (1 - (1 - t) * (1 - t))          // ease-out expansion
        let a = (1 - t) * 0.82
        guard a > 0.02, radius > 1 else { return nil }
        return (radius, a)
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let now = CACurrentMediaTime()
        ctx.setBlendMode(.normal)
        for r in ripples {
            guard let (radius, a) = crestState(r, now) else { continue }
            let t = CGFloat((now - r.birth) / r.life)
            let cx = r.center.x - origin.x, cy = r.center.y - origin.y
            let color = Self.palette[r.color]

            // WATER, not chalk: a thin bright crest line (caustic) over a wide casing,
            // thinning as the ring expands and its energy spreads; a fainter echo ring
            // trails just inside the crest, like the trough behind a real wavefront.
            // The casing is a DEEP version of the ripple's own color — bold ink on a
            // light wallpaper (a translucent black outline just fades there), while on
            // dark it recedes and the bright core carries the glow.
            let w = inkWeight(bgMap, bgFallback, r.center)
            let crestW = r.width * (2.6 - 1.4 * t)
            let crest = CGPath(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                                 width: radius * 2, height: radius * 2), transform: nil)
            waterStroke(ctx, crest, width: crestW, alpha: a, color: color, w)
            let echoR = radius * 0.84
            if echoR > 3 {
                let echo = CGPath(ellipseIn: CGRect(x: cx - echoR, y: cy - echoR,
                                                    width: echoR * 2, height: echoR * 2), transform: nil)
                waterStroke(ctx, echo, width: crestW * 0.6, alpha: a * 0.5, color: color, w)
            }

            // Impact dimple: a soft glow right after the drop lands, gone in a blink.
            if t < 0.22 {
                let dt2 = t / 0.22
                ctx.setAlpha((1 - dt2) * 0.5)
                let dr = 10 + dt2 * 14
                ctx.draw(Self.dimples[r.color], in: CGRect(x: cx - dr, y: cy - dr, width: dr * 2, height: dr * 2))
                ctx.setAlpha(1)
            }
        }

        drawInterferenceGlints(into: ctx, origin: origin, now: now)
        ctx.setBlendMode(.normal); ctx.setAlpha(1)
    }

    // Where two expanding crests cross, real water interferes constructively — the
    // crossing points catch the light. Circle-circle intersection gives exactly those
    // two points, and because both radii keep growing, the glints SLIDE along the
    // rings frame to frame, just like on a pond.
    private func drawInterferenceGlints(into ctx: CGContext, origin: CGPoint, now: TimeInterval) {
        guard ripples.count > 1 else { return }
        var budget = 60   // glint pairs per frame — plenty, and bounds the O(n²) pass
        for i in 0..<(ripples.count - 1) {
            guard let (r1, a1) = crestState(ripples[i], now) else { continue }
            let c1 = ripples[i].center
            for j in (i + 1)..<ripples.count {
                guard budget > 0 else { return }
                guard let (r2, a2) = crestState(ripples[j], now) else { continue }
                let c2 = ripples[j].center
                let dx = c2.x - c1.x, dy = c2.y - c1.y
                let d = sqrt(dx * dx + dy * dy)
                // Crests must genuinely cross (concentric echo rings share a center and
                // are correctly skipped by d > 0).
                guard d > 1, d < r1 + r2, d > abs(r1 - r2) else { continue }
                budget -= 1
                let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
                let h = sqrt(max(0, r1 * r1 - a * a))
                let mx = c1.x + a * dx / d, my = c1.y + a * dy / d
                let px = -dy / d * h, py = dx / d * h
                let glow = min(1, a1 * a2 * 2.2)   // both crests must still carry energy
                guard glow > 0.05 else { continue }
                for s in [CGFloat(1), -1] {
                    let gx = mx + px * s - origin.x, gy = my + py * s - origin.y
                    let iw = inkWeight(bgMap, bgFallback, NSPoint(x: mx + px * s, y: my + py * s))
                    let gr: CGFloat = 7
                    if iw > 0.05 {   // ground the sparkle over bright pixels
                        ctx.setBlendMode(.normal); ctx.setAlpha(glow * 0.5 * iw)
                        let dr = gr * 1.4
                        ctx.draw(Self.glintDark, in: CGRect(x: gx - dr, y: gy - dr, width: dr * 2, height: dr * 2))
                    }
                    ctx.setBlendMode(.normal); ctx.setAlpha(glow * 0.8)
                    ctx.draw(Self.glintCore, in: CGRect(x: gx - gr, y: gy - gr, width: gr * 2, height: gr * 2))
                    let ga = glow * 0.55 * (1 - 0.7 * iw)
                    if ga > 0.02 {
                        ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                        let hr = gr * 1.7
                        ctx.draw(Self.glintGlow, in: CGRect(x: gx - hr, y: gy - hr, width: hr * 2, height: hr * 2))
                    }
                }
            }
        }
    }
}
