import AppKit

// MUSIC BOX — the first scene that composes TIME instead of decorating space.
// A glowing clockwork carousel turns forever; a radial beam sweeps it like the
// tine-drum of a music box. Whatever the child plays is CAPTURED INTO THE LOOP:
//   • Every KEY sets a note-gem on the outer ring at the beam's current position —
//     the timing of their mashing becomes the rhythm, the key becomes the pitch
//     (and its color). Each revolution replays their melody.
//   • CLICK sets a droplet-gem on the inner ring — the percussion track.
//   • CLICK-AND-HOLD is double-time: the box spins up, the music tumbles faster;
//     release and it breathes back down.
//   • SCROLL is the tempo crown: wind the loop longer or shorter.
// Gems live for six revolutions and dissolve, so the composition keeps evolving —
// mash, listen, answer yourself. When the beam strikes a gem it flares and rings
// a light-ripple outward. A hub jewel beats at the heart like an escapement.
final class MusicBoxScene: Scene {
    let name = "Music Box"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Gem {
        var angle: CGFloat          // position on the loop (radians)
        var key: String             // replayed through the same deterministic synth path
        var hue: Int
        var kind: Int               // 0 = melody (outer ring), 1 = percussion (inner)
        var birth: TimeInterval
        var hits: Int = 0
        var lastHit: TimeInterval = -9
    }
    private struct Burst { var angle: CGFloat; var radius: CGFloat; var birth: TimeInterval; var hue: Int }

    private var gems: [Gem] = []
    private var bursts: [Burst] = []
    private let maxMelody = 26
    private let maxDrums = 14
    private let gemLives = 6                    // revolutions before a gem dissolves
    private var rng = RNG(seed: 0xB0C5)

    // The loop.
    private var period: CGFloat = 4.5           // seconds per revolution (scroll: 2.4…9)
    private var playAngle: CGFloat = 0
    private var holdLevel: CGFloat = 0          // double-time when held

    private var center = NSPoint.zero
    private var outerR: CGFloat = 300
    private var innerR: CGFloat = 200
    private var seeded = false
    private var now: TimeInterval = 0

    // Adaptive contrast cache.
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    private static let hues: [NSColor] = (0..<12).map {
        NSColor(hue: CGFloat($0) / 12, saturation: 0.78, brightness: 1.0, alpha: 1)
    }
    private static let cores: [CGImage] = hues.map { softContrastSprite($0) }
    private static let glows: [CGImage] = hues.map { softGlowSprite($0) }
    private static let beamGlow = softGlowSprite(NSColor(srgbRed: 1.0, green: 0.95, blue: 0.8, alpha: 1))
    private static let dark = inkSprite(NSColor(white: 0, alpha: 1))
    private static let ringColor = NSColor(srgbRed: 0.75, green: 0.82, blue: 1.0, alpha: 1)

    var audioSwell: CGFloat { holdLevel * 0.2 }

    func reset() {
        gems.removeAll(keepingCapacity: true)
        bursts.removeAll(keepingCapacity: true)
        period = 4.5; playAngle = 0; holdLevel = 0
        seeded = false
        draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard !seeded else { return }
        seeded = true
        center = NSPoint(x: bounds.midX, y: bounds.midY)
        let m = min(bounds.width, bounds.height)
        outerR = m * 0.34
        innerR = m * 0.225
    }

    private func addGem(_ g: Gem) {
        let kind = g.kind
        let cap = kind == 0 ? maxMelody : maxDrums
        if gems.filter({ $0.kind == kind }).count >= cap,
           let oldest = gems.enumerated().filter({ $0.element.kind == kind }).min(by: { $0.element.birth < $1.element.birth }) {
            gems.remove(at: oldest.offset)
        }
        gems.append(g)
    }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key(let s):
            // Set the note into the loop AT THE BEAM — press timing becomes rhythm.
            let hue = Int(s.unicodeScalars.reduce(5) { $0 &+ UInt32($1.value) }) % Self.hues.count
            addGem(Gem(angle: playAngle, key: s, hue: hue, kind: 0, birth: ctx.now))
            ctx.audio?.note(for: s, intensity: ctx.intensity)   // the press itself sounds now
        case .click(_, .left):
            addGem(Gem(angle: playAngle, key: "", hue: rng.int(Self.hues.count), kind: 1, birth: ctx.now))
            ctx.audio?.drip(intensity: 0.7)
        case .scroll(let dy):
            // The tempo crown: wind the loop shorter (faster) or longer.
            period = max(2.4, min(9, period - CGFloat(dy) * 0.18))
        default:
            break
        }
    }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        now = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        let dt = ctx.dt

        if ctx.leftButtonDown && !draining { holdLevel += (1 - holdLevel) * min(1, dt * 2.4) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 1.4) }

        // Advance the beam; double-time under a held hand.
        let prev = playAngle
        playAngle += 2 * .pi / period * (1 + holdLevel) * dt
        if playAngle >= 2 * .pi { playAngle -= 2 * .pi }

        // Strike gems the beam crossed this frame (mind the wraparound).
        for i in gems.indices {
            let a = gems[i].angle
            let crossed = prev <= playAngle
                ? (a > prev && a <= playAngle)
                : (a > prev || a <= playAngle)
            guard crossed else { continue }
            gems[i].hits += 1
            gems[i].lastHit = now
            let radius = gems[i].kind == 0 ? outerR : innerR
            bursts.append(Burst(angle: a, radius: radius, birth: now, hue: gems[i].hue))
            if gems[i].kind == 0 {
                ctx.audio?.note(for: gems[i].key, intensity: 0.5 + 0.4 * holdLevel)
            } else {
                ctx.audio?.drip(intensity: 0.55)
            }
        }
        gems.removeAll { $0.hits >= gemLives }
        bursts.removeAll { now - $0.birth > 1.1 }
    }

    func liveCount() -> Int { gems.count + bursts.count }

    // MARK: Draw

    private func ringStroke(_ ctx: CGContext, radius: CGFloat, cx: CGFloat, cy: CGFloat, width: CGFloat, alpha: CGFloat, w: CGFloat) {
        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        let path = CGPath(ellipseIn: rect, transform: nil)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.setLineWidth(width + 2.4)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha * (0.25 + 0.4 * w)).cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(blendColor(Self.ringColor, .black, 0.35 * w).withAlphaComponent(alpha).cgColor)
        ctx.strokePath()
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
        let cx = center.x - origin.x, cy = center.y - origin.y
        let w = inkWeight(bgMap, bgFallback, center)

        // The carousel: two rings + sixteen beat ticks.
        ringStroke(ctx, radius: outerR, cx: cx, cy: cy, width: 2, alpha: 0.55, w: w)
        ringStroke(ctx, radius: innerR, cx: cx, cy: cy, width: 1.6, alpha: 0.45, w: w)
        for t in 0..<16 {
            let a = CGFloat(t) / 16 * 2 * .pi
            let ticks = CGMutablePath()
            ticks.move(to: CGPoint(x: cx + cos(a) * (outerR + 6), y: cy + sin(a) * (outerR + 6)))
            ticks.addLine(to: CGPoint(x: cx + cos(a) * (outerR + (t % 4 == 0 ? 20 : 12)),
                                      y: cy + sin(a) * (outerR + (t % 4 == 0 ? 20 : 12))))
            ctx.setLineCap(.round); ctx.setLineWidth(t % 4 == 0 ? 2.4 : 1.4)
            ctx.setStrokeColor(blendColor(Self.ringColor, .black, 0.4 * w)
                .withAlphaComponent(t % 4 == 0 ? 0.6 : 0.35).cgColor)
            ctx.addPath(ticks); ctx.strokePath()
        }

        // The beam: a clock hand from the hub to past the outer ring, with a soft
        // light cone fading behind it (wide translucent strokes, not hairlines).
        let ba = playAngle
        for trail in stride(from: 3, through: 1, by: -1) {
            let ta = ba - CGFloat(trail) * 0.05
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx + cos(ta) * 26, y: cy + sin(ta) * 26))
            path.addLine(to: CGPoint(x: cx + cos(ta) * (outerR + 18), y: cy + sin(ta) * (outerR + 18)))
            ctx.setLineCap(.round)
            ctx.setLineWidth(CGFloat(3 + trail * 5))
            ctx.setStrokeColor(blendColor(Self.ringColor, .black, 0.4 * w)
                .withAlphaComponent(0.10 * (1 - 0.6 * w) + 0.05).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }
        let hand = CGMutablePath()
        hand.move(to: CGPoint(x: cx + cos(ba) * 26, y: cy + sin(ba) * 26))
        hand.addLine(to: CGPoint(x: cx + cos(ba) * (outerR + 24), y: cy + sin(ba) * (outerR + 24)))
        ctx.setLineCap(.round)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(blendColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1), .black, 0.45 * w)
            .withAlphaComponent(0.95).cgColor)
        ctx.addPath(hand); ctx.strokePath()
        // Beam tip glint on each ring.
        for r in [outerR, innerR] {
            let gx = cx + cos(ba) * r, gy = cy + sin(ba) * r
            let ga = 0.7 * (1 - 0.6 * w)
            if ga > 0.03 {
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                ctx.draw(Self.beamGlow, in: CGRect(x: gx - 16, y: gy - 16, width: 32, height: 32))
                ctx.setBlendMode(.normal); ctx.setAlpha(1)
            }
        }

        // Strike ripples: light expanding outward from struck gems.
        for b in bursts {
            let t = CGFloat((now - b.birth) / 1.1)
            let a = (1 - t) * (1 - t) * 0.8
            guard a > 0.03 else { continue }
            let bx = cx + cos(b.angle) * b.radius, by = cy + sin(b.angle) * b.radius
            let rr = 8 + t * 90
            let rect = CGRect(x: bx - rr, y: by - rr, width: rr * 2, height: rr * 2)
            let path = CGPath(ellipseIn: rect, transform: nil)
            ctx.setLineWidth(2.4 - 1.4 * t)
            ctx.setStrokeColor(blendColor(Self.hues[b.hue], .black, 0.35 * w).withAlphaComponent(a).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }

        // Gems: jewels on their rings, flaring when struck, dissolving with age.
        for g in gems {
            let radius = g.kind == 0 ? outerR : innerR
            let gx = cx + cos(g.angle) * radius, gy = cy + sin(g.angle) * radius
            let flare = max(0, 1 - CGFloat(now - g.lastHit) / 0.5)
            let lifeLeft = 1 - CGFloat(g.hits) / CGFloat(gemLives)
            let alpha = (0.5 + 0.45 * lifeLeft) * (g.kind == 0 ? 1 : 0.9)
            let size = (g.kind == 0 ? 10.5 : 8) * (1 + flare * 0.8)
            let gw = inkWeight(bgMap, bgFallback, NSPoint(x: gx + origin.x, y: gy + origin.y))
            if gw > 0.05 {
                ctx.setAlpha(alpha * 0.5 * gw)
                let dr = size * 1.4
                ctx.draw(Self.dark, in: CGRect(x: gx - dr, y: gy - dr, width: dr * 2, height: dr * 2))
            }
            ctx.setAlpha(alpha)
            ctx.draw(Self.cores[g.hue], in: CGRect(x: gx - size, y: gy - size, width: size * 2, height: size * 2))
            let ga = (0.4 + flare * 0.6) * alpha * (1 - 0.7 * gw)
            if ga > 0.02 {
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                let gr = size * 2.1
                ctx.draw(Self.glows[g.hue], in: CGRect(x: gx - gr, y: gy - gr, width: gr * 2, height: gr * 2))
                ctx.setBlendMode(.normal)
            }
        }

        // The escapement heart: a hub jewel beating with the loop (one pulse per beat
        // tick passing), swelling in double-time.
        let beatPhase = (playAngle / (2 * .pi) * 16).truncatingRemainder(dividingBy: 1)
        let beat = 1 + 0.18 * CGFloat(exp(-beatPhase * 5)) + holdLevel * 0.25
        let hubHue = Int(now * 0.5) % Self.hues.count
        let hubR = 17 * beat
        ctx.setAlpha(1)
        if w > 0.05 {
            ctx.setAlpha(0.55 * w)
            let dr = hubR * 1.5
            ctx.draw(Self.dark, in: CGRect(x: cx - dr, y: cy - dr, width: dr * 2, height: dr * 2))
            ctx.setAlpha(1)
        }
        ctx.draw(Self.cores[hubHue], in: CGRect(x: cx - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2))
        let hga = 0.6 * (1 - 0.7 * w)
        if hga > 0.03 {
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(hga)
            let gr = hubR * 2.6
            ctx.draw(Self.glows[hubHue], in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
