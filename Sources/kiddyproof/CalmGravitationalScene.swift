import AppKit

// ORRERY — a living solar system (total rebuild of the old invisible "Gravitational").
// A radiant sun anchors ten glowing orbit lanes.
//   • Every KEY places a planet: the key chooses its lane and color; some planets
//     arrive with rings, some with a racing moon. A lane holds one planet — replaying
//     a lane swaps its planet in a burst of light, so the kid composes the system.
//   • CLICK launches a COMET from the fingertip: it slingshots around the sun under
//     real gravity, dragging a long tail, and burns out in a sparkle.
//   • CLICK-AND-HOLD is TIME-LAPSE: the whole system whirls at five-fold speed and
//     the sun swells with the effort; release and the years slow back to a drift.
//   • SCROLL zooms the universe nearer or farther — the only scene with a camera.
// A faint twinkling starfield sits behind everything. Adaptive-contrast throughout.
final class CalmGravitationalScene: Scene {
    let name = "Orrery"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Planet {
        var lane: Int
        var ang: CGFloat
        var hue: Int
        var size: CGFloat
        var hasRing: Bool
        var hasMoon: Bool
        var moonAng: CGFloat = 0
        var birth: TimeInterval
    }
    private struct Comet {
        var pos: NSPoint; var vel: NSPoint
        var trail: [NSPoint] = []
        var birth: TimeInterval
        var dying: TimeInterval = 0     // >0: burning out (perihelion sparkle done)
    }
    private struct Star { var p: NSPoint; var phase: CGFloat; var size: CGFloat }
    private struct Burst { var p: NSPoint; var birth: TimeInterval; var hue: Int }

    private var planets: [Planet] = []
    private var comets: [Comet] = []
    private var stars: [Star] = []
    private var bursts: [Burst] = []
    private let lanes = 10
    private var rng = RNG(seed: 0x0AA37)
    private var seeded = false
    private var now: TimeInterval = 0
    private var center = NSPoint.zero
    private var laneUnit: CGFloat = 60      // world-space gap between lanes

    // Camera + time.
    private var zoom: CGFloat = 1
    private var zoomTarget: CGFloat = 1
    private var holdLevel: CGFloat = 0      // time-lapse

    // Adaptive contrast cache.
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    private static let hues: [NSColor] = (0..<12).map {
        NSColor(hue: CGFloat($0) / 12, saturation: 0.7, brightness: 1.0, alpha: 1)
    }
    private static let cores: [CGImage] = hues.map { softContrastSprite($0) }
    private static let glows: [CGImage] = hues.map { softGlowSprite($0) }
    private static let sunCore = softContrastSprite(NSColor(srgbRed: 1.0, green: 0.85, blue: 0.45, alpha: 1))
    private static let sunGlow = softGlowSprite(NSColor(srgbRed: 1.0, green: 0.8, blue: 0.4, alpha: 1))
    private static let starSprite = softContrastSprite(NSColor(srgbRed: 0.8, green: 0.88, blue: 1.0, alpha: 1))
    private static let cometColor = NSColor(srgbRed: 0.75, green: 0.92, blue: 1.0, alpha: 1)
    private static let dark = inkSprite(NSColor(white: 0, alpha: 1))
    private static let ringColor = NSColor(srgbRed: 0.72, green: 0.8, blue: 0.95, alpha: 1)

    var audioSwell: CGFloat { holdLevel * 0.25 }

    func reset() {
        planets.removeAll(keepingCapacity: true)
        comets.removeAll(keepingCapacity: true)
        bursts.removeAll(keepingCapacity: true)
        zoom = 1; zoomTarget = 1; holdLevel = 0
        seeded = false
        draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard !seeded else { return }
        seeded = true
        center = NSPoint(x: bounds.midX, y: bounds.midY)
        laneUnit = min(bounds.width, bounds.height) * 0.4 / CGFloat(lanes)
        stars.removeAll(keepingCapacity: true)
        for _ in 0..<44 {
            stars.append(Star(p: NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                                         y: rng.range(bounds.minY, bounds.maxY)),
                              phase: rng.range(0, 6.28), size: rng.range(1.2, 2.8)))
        }
        // A starter system so the sky is never empty: three planets, one with a ring.
        for (lane, hue) in [(2, 4), (5, 0), (8, 8)] {
            planets.append(Planet(lane: lane, ang: rng.range(0, 6.28), hue: hue,
                                  size: rng.range(7, 12),
                                  hasRing: lane == 5, hasMoon: lane == 8, birth: now))
        }
    }

    private func laneRadius(_ lane: Int) -> CGFloat { (CGFloat(lane) + 2.2) * laneUnit * zoom }
    // Kepler-flavored: inner lanes race, outer lanes glide.
    private func laneSpeed(_ lane: Int) -> CGFloat { 0.5 / pow((CGFloat(lane) + 2.2) / 5, 1.5) }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key(let s):
            // Knuth-mix the key hash: a plain sum clusters neighboring letters into
            // the same few hues (the first build produced an all-pink system).
            let h = s.unicodeScalars.reduce(11) { $0 &+ UInt32($1.value) }
            let mixed = (h &* 2654435761) >> 7
            let lane = Int(mixed) % lanes
            let hue = Int(mixed >> 5) % Self.hues.count
            if let old = planets.firstIndex(where: { $0.lane == lane }) {
                bursts.append(Burst(p: planetPos(planets[old]), birth: ctx.now, hue: planets[old].hue))
                planets.remove(at: old)
            }
            planets.append(Planet(lane: lane, ang: rng.range(0, 6.28), hue: hue,
                                  size: rng.range(6, 13),
                                  hasRing: rng.unit() < 0.25, hasMoon: rng.unit() < 0.35,
                                  birth: ctx.now))
            ctx.audio?.note(for: s, intensity: ctx.intensity)
        case .click(let pt, .left):
            guard comets.count < 4 else { break }
            // Launch tangentially so the sun's gravity bends it into a slingshot.
            let d = pt - center
            let dist = max(60, sqrt(hypot2(d)))
            let n = NSPoint(x: d.x / dist, y: d.y / dist)
            let tangent = NSPoint(x: -n.y, y: n.x)
            let speed = rng.range(300, 430)
            comets.append(Comet(pos: pt,
                                vel: NSPoint(x: tangent.x * speed - n.x * 60,
                                             y: tangent.y * speed - n.y * 60),
                                birth: ctx.now))
            ctx.audio?.whoosh()
        case .scroll(let dy):
            zoomTarget = max(0.55, min(1.6, zoomTarget + CGFloat(dy) * 0.05))
        default:
            break
        }
    }

    private func planetPos(_ p: Planet) -> NSPoint {
        let r = laneRadius(p.lane)
        return NSPoint(x: center.x + cos(p.ang) * r, y: center.y + sin(p.ang) * r)
    }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        now = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        let dt = ctx.dt

        if ctx.leftButtonDown && !draining { holdLevel += (1 - holdLevel) * min(1, dt * 2) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 1.2) }
        zoom += (zoomTarget - zoom) * min(1, dt * 5)

        let timeScale = 1 + holdLevel * 4
        for i in planets.indices {
            planets[i].ang += laneSpeed(planets[i].lane) * timeScale * dt
            if planets[i].hasMoon { planets[i].moonAng += 2.6 * timeScale * dt }
        }

        // Comets: sun gravity, tail, perihelion sparkle, burn-out.
        let G: CGFloat = 2.4e6 * zoom
        var i = 0
        while i < comets.count {
            var c = comets[i]
            if c.dying == 0 {
                let d = center - c.pos
                let r2 = hypot2(d) + 40 * 40
                let r = sqrt(r2)
                let a = G / r2 * timeScale
                c.vel.x += d.x / r * a * dt
                c.vel.y += d.y / r * a * dt
                c.pos = c.pos + c.vel * (dt * CGFloat(timeScale))
                c.trail.append(c.pos)
                if c.trail.count > 52 { c.trail.removeFirst(c.trail.count - 52) }
                // Close pass: flare and begin the burn-out.
                if r < 70 * zoom {
                    c.dying = now
                    bursts.append(Burst(p: c.pos, birth: now, hue: 1))
                    ctx.audio?.ping()
                }
                // Long gone: fade without ceremony.
                let off = ctx.bounds.insetBy(dx: -320, dy: -320)
                if !off.contains(c.pos) || now - c.birth > 9 { c.dying = now }
            }
            if c.dying > 0, now - c.dying > 0.9 { comets.remove(at: i); continue }
            comets[i] = c
            i += 1
        }
        bursts.removeAll { now - $0.birth > 1.0 }
    }

    func liveCount() -> Int { planets.count + comets.count + bursts.count }

    // MARK: Draw

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
        let cx = center.x - origin.x, cy = center.y - origin.y
        let w = inkWeight(bgMap, bgFallback, center)

        // Starfield backdrop.
        for s in stars {
            let tw = 0.35 + 0.4 * CGFloat(sin(now * 0.9 + Double(s.phase)))
            let sw = inkWeight(bgMap, bgFallback, s.p)
            ctx.setAlpha(tw * (1 - 0.55 * sw) + 0.18 * sw)
            let img = sw > 0.5 ? Self.dark : Self.starSprite
            ctx.draw(img, in: CGRect(x: s.p.x - origin.x - s.size, y: s.p.y - origin.y - s.size,
                                     width: s.size * 2, height: s.size * 2))
        }
        ctx.setAlpha(1)

        // Orbit lanes (only occupied ones — the composition the kid built).
        for p in planets {
            let r = laneRadius(p.lane)
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            let path = CGPath(ellipseIn: rect, transform: nil)
            ctx.setLineCap(.round)
            ctx.setLineWidth(2.4)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.14 + 0.3 * w).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineWidth(1.1)
            ctx.setStrokeColor(blendColor(Self.hues[p.hue], Self.ringColor, 0.25)
                .withAlphaComponent(0.55).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }

        // The sun: white-hot center inside layered gold radiance (a single wide dim
        // glow read as muddy brown on black); time-lapse makes it labor.
        let beat = 0.9 + 0.1 * CGFloat(sin(now * 2.2)) + holdLevel * 0.3
        let sunR = 30 * zoom * beat
        if w < 0.95 {
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(0.4 * (1 - w))
            let gr = sunR * 3.0
            ctx.draw(Self.sunGlow, in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
            ctx.setAlpha(0.85 * (1 - w))    // tight, hot inner corona
            let gr2 = sunR * 1.6
            ctx.draw(Self.sunGlow, in: CGRect(x: cx - gr2, y: cy - gr2, width: gr2 * 2, height: gr2 * 2))
            ctx.setBlendMode(.normal)
        }
        if w > 0.05 {
            ctx.setAlpha(0.5 * w)
            let dr = sunR * 1.5
            ctx.draw(Self.dark, in: CGRect(x: cx - dr, y: cy - dr, width: dr * 2, height: dr * 2))
        }
        ctx.setAlpha(1)
        ctx.draw(Self.sunCore, in: CGRect(x: cx - sunR, y: cy - sunR, width: sunR * 2, height: sunR * 2))
        // White-hot heart.
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.98, blue: 0.9, alpha: 0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - sunR * 0.45, y: cy - sunR * 0.45, width: sunR * 0.9, height: sunR * 0.9))

        // Planets, moons, rings.
        for p in planets {
            let pos = planetPos(p)
            let px = pos.x - origin.x, py = pos.y - origin.y
            let size = p.size * zoom * min(1, CGFloat((now - p.birth) / 0.5) + 0.2)
            let pw = inkWeight(bgMap, bgFallback, pos)
            if pw > 0.05 {
                ctx.setAlpha(0.55 * pw)
                let dr = size * 1.45
                ctx.draw(Self.dark, in: CGRect(x: px - dr, y: py - dr, width: dr * 2, height: dr * 2))
            }
            ctx.setAlpha(0.95)
            ctx.draw(Self.cores[p.hue], in: CGRect(x: px - size, y: py - size, width: size * 2, height: size * 2))
            let ga = 0.5 * (1 - 0.7 * pw)
            if ga > 0.02 {
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                let gr = size * 1.9
                ctx.draw(Self.glows[p.hue], in: CGRect(x: px - gr, y: py - gr, width: gr * 2, height: gr * 2))
                ctx.setBlendMode(.normal)
            }
            if p.hasRing {
                // A Saturn ring: a tilted ellipse around the planet.
                ctx.saveGState()
                ctx.translateBy(x: px, y: py)
                ctx.rotate(by: 0.5)
                ctx.setLineWidth(1.6)
                ctx.setStrokeColor(blendColor(Self.hues[(p.hue + 3) % 12], .black, 0.3 * pw)
                    .withAlphaComponent(0.75).cgColor)
                ctx.strokeEllipse(in: CGRect(x: -size * 1.9, y: -size * 0.7, width: size * 3.8, height: size * 1.4))
                ctx.restoreGState()
            }
            if p.hasMoon {
                let mr = size * 2.3
                let mx = px + cos(p.moonAng) * mr, my = py + sin(p.moonAng) * mr
                let ms = max(2.2, size * 0.28)
                ctx.setAlpha(0.9)
                ctx.draw(Self.cores[(p.hue + 6) % 12], in: CGRect(x: mx - ms, y: my - ms, width: ms * 2, height: ms * 2))
            }
        }

        // Comets: bright head + long tapering tail; a dying comet fades as one.
        for c in comets {
            let fade = c.dying > 0 ? max(0, 1 - CGFloat(now - c.dying) / 0.9) : 1
            guard fade > 0.02, c.trail.count > 1 else { continue }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.trail[0].x - origin.x, y: c.trail[0].y - origin.y))
            for k in 1..<c.trail.count {
                path.addLine(to: CGPoint(x: c.trail[k].x - origin.x, y: c.trail[k].y - origin.y))
            }
            // Tapered tail: three nested strokes over the newest fractions of the
            // trail — wide and faint at the tip, bright and tight at the head.
            let cw = inkWeight(bgMap, bgFallback, c.pos)
            ctx.setLineCap(.round)
            ctx.setLineWidth(4.4)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.3 * cw * fade).cgColor)
            ctx.addPath(path); ctx.strokePath()
            for (fraction, width, alpha) in [(0.0, CGFloat(1.2), 0.3), (0.5, 2.0, 0.55), (0.78, 3.0, 0.85)] {
                let start = Int(Double(c.trail.count - 1) * fraction)
                guard start < c.trail.count - 1 else { continue }
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: c.trail[start].x - origin.x, y: c.trail[start].y - origin.y))
                for k in (start + 1)..<c.trail.count {
                    seg.addLine(to: CGPoint(x: c.trail[k].x - origin.x, y: c.trail[k].y - origin.y))
                }
                ctx.setLineWidth(width)
                ctx.setStrokeColor(blendColor(Self.cometColor, .black, 0.35 * cw)
                    .withAlphaComponent(alpha * fade).cgColor)
                ctx.addPath(seg); ctx.strokePath()
            }
            let hx = c.pos.x - origin.x, hy = c.pos.y - origin.y
            ctx.setAlpha(fade)
            ctx.draw(Self.cores[1], in: CGRect(x: hx - 5, y: hy - 5, width: 10, height: 10))
            let ga = 0.8 * (1 - 0.6 * cw) * fade
            if ga > 0.03 {
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                ctx.draw(Self.glows[1], in: CGRect(x: hx - 14, y: hy - 14, width: 28, height: 28))
                ctx.setBlendMode(.normal)
            }
        }

        // Bursts: a planet swapped out or a comet's perihelion — one expanding ring.
        for b in bursts {
            let t = CGFloat((now - b.birth) / 1.0)
            let a = (1 - t) * (1 - t) * 0.85
            guard a > 0.03 else { continue }
            let rr = 6 + t * 70
            let rect = CGRect(x: b.p.x - origin.x - rr, y: b.p.y - origin.y - rr, width: rr * 2, height: rr * 2)
            ctx.setLineWidth(2.2 - 1.2 * t)
            ctx.setStrokeColor(blendColor(Self.hues[b.hue], .black, 0.3 * w).withAlphaComponent(a).cgColor)
            ctx.strokeEllipse(in: rect)
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
