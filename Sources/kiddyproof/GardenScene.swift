import AppKit

// GARDEN — the child grows a living garden and turns its seasons.
//   • CLICK plants a seed: a vine sprouts and climbs with an organic wander,
//     unfolding leaves as it goes and crowning itself with a flower.
//   • Every KEY blossoms a flower in that key's own color on the nearest vine
//     (mash the keyboard, carpet the garden in bloom).
//   • CLICK-AND-HOLD is sunshine: growth quickens, buds open toward the warmth,
//     and pollen sparks drift up through the light.
//   • SCROLL turns the WHEEL OF SEASONS — spring blossoms, deep summer green,
//     gold-and-ember autumn with falling leaves, bare frosted winter with snow —
//     the whole garden repaints live as the wheel turns.
//   • A little butterfly rides the cursor, flapping while you move, settling
//     when you rest.
// The garden persists for the whole session; oldest vines make way at the cap.
final class GardenScene: Scene {
    let name = "Garden"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    // MARK: Structure

    private struct Flower {
        var pointIdx: Int          // anchor on the vine
        var hue: Int
        var birth: TimeInterval
        var size: CGFloat
        var phase: CGFloat
    }
    private struct Vine {
        var pts: [NSPoint] = []
        var dir: CGFloat           // current growth heading (radians, π/2 = up)
        var target: Int            // how many points it wants
        var flowers: [Flower] = []
        var phase: CGFloat
        var doneAt: TimeInterval = 0
    }
    private struct Fall {          // falling leaf / snowflake
        var p: NSPoint; var vx: CGFloat; var vy: CGFloat
        var spin: CGFloat; var spinV: CGFloat
        var birth: TimeInterval; var life: Double
        var hue: Int               // -1 = snow
        var size: CGFloat
    }
    private struct Pollen { var p: NSPoint; var vy: CGFloat; var birth: TimeInterval; var life: Double }

    private struct Grass { var x: CGFloat; var h: CGFloat; var lean: CGFloat; var phase: CGFloat }

    private var vines: [Vine] = []
    private var falls: [Fall] = []
    private var pollen: [Pollen] = []
    private var grass: [Grass] = []
    private let maxVines = 14
    private let segment: CGFloat = 11
    private var rng = RNG(seed: 0x6A2DE)
    private var seeded = false
    private var now: TimeInterval = 0
    private var bounds = CGRect.zero

    // Season wheel: 0 spring, 1 summer, 2 autumn, 3 winter (wraps at 4).
    private var season: CGFloat = 0
    private var lastSeasonQuarter = 0

    // Sunshine hold.
    private var holdLevel: CGFloat = 0
    private var sunPos = NSPoint.zero

    // Butterfly.
    private var flyPos = NSPoint.zero
    private var flyVel = NSPoint.zero
    private var flap: CGFloat = 0

    // Adaptive contrast cache.
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    // MARK: Palette

    private static let flowerHues: [NSColor] = (0..<12).map {
        NSColor(hue: CGFloat($0) / 12, saturation: 0.72, brightness: 1.0, alpha: 1)
    }
    private static let flowerCores: [CGImage] = flowerHues.map { softContrastSprite($0) }
    private static let flowerGlows: [CGImage] = flowerHues.map { softGlowSprite($0) }
    private static let leafSpring = inkSprite(NSColor(srgbRed: 0.45, green: 0.85, blue: 0.4, alpha: 1))
    private static let leafSummer = inkSprite(NSColor(srgbRed: 0.16, green: 0.6, blue: 0.3, alpha: 1))
    private static let leafGold = inkSprite(NSColor(srgbRed: 1.0, green: 0.72, blue: 0.2, alpha: 1))
    private static let leafEmber = inkSprite(NSColor(srgbRed: 0.95, green: 0.4, blue: 0.2, alpha: 1))
    private static let snowSprite = softContrastSprite(NSColor(srgbRed: 0.85, green: 0.93, blue: 1.0, alpha: 1))
    private static let sunGlow = softGlowSprite(NSColor(srgbRed: 1.0, green: 0.85, blue: 0.45, alpha: 1))
    private static let dark = inkSprite(NSColor(white: 0, alpha: 1))

    var audioSwell: CGFloat { holdLevel * 0.25 }

    func reset() {
        vines.removeAll(keepingCapacity: true)
        falls.removeAll(keepingCapacity: true)
        pollen.removeAll(keepingCapacity: true)
        season = 0; lastSeasonQuarter = 0
        // Dev aid: KP_SEASON=0…3.99 previews any point on the wheel (the demo
        // harness can't scroll, and the visual-verification loop needs all seasons).
        if let s = ProcessInfo.processInfo.environment["KP_SEASON"], let v = Double(s) {
            season = CGFloat(v.truncatingRemainder(dividingBy: 4))
            lastSeasonQuarter = Int(season)
        }
        holdLevel = 0; flap = 0
        seeded = false
        draining = false
    }

    // MARK: Planting & growth

    private func plant(atX x: CGFloat, _ t: TimeInterval) {
        if vines.count >= maxVines { vines.removeFirst() }
        var v = Vine(pts: [NSPoint(x: x, y: bounds.minY - 4)],
                     dir: .pi / 2 + rng.range(-0.25, 0.25),
                     target: Int(rng.range(24, 46)),
                     phase: rng.range(0, 6.28))
        v.pts.reserveCapacity(v.target)
        vines.append(v)
        _ = t
    }

    private func grow(_ dt: CGFloat) {
        // Sunshine quickens the whole garden; winter slows it to a crawl.
        let winter = seasonWeight(3)
        let rate = (6 + holdLevel * 18) * (1 - winter * 0.85)   // points/second
        for i in vines.indices {
            guard vines[i].pts.count < vines[i].target else {
                if vines[i].doneAt == 0 {
                    vines[i].doneAt = now
                    // Crown: every finished vine blooms at its tip.
                    vines[i].flowers.append(Flower(pointIdx: vines[i].pts.count - 1,
                                                   hue: rng.int(Self.flowerHues.count),
                                                   birth: now, size: rng.range(13, 19),
                                                   phase: rng.range(0, 6.28)))
                }
                continue
            }
            // Fractional growth via probability keeps all vines advancing smoothly.
            if rng.unit() < rate * dt {
                var v = vines[i]
                let last = v.pts[v.pts.count - 1]
                // Organic wander with an upward bias; sunshine leans growth toward the sun.
                v.dir += rng.range(-0.3, 0.3)
                v.dir += (CGFloat.pi / 2 - v.dir) * 0.12
                if holdLevel > 0.1 {
                    let toSun = atan2(sunPos.y - last.y, sunPos.x - last.x)
                    var d = toSun - v.dir
                    while d > .pi { d -= 2 * .pi }
                    while d < -.pi { d += 2 * .pi }
                    v.dir += d * 0.1 * holdLevel
                }
                v.pts.append(NSPoint(x: last.x + cos(v.dir) * segment,
                                     y: last.y + sin(v.dir) * segment))
                vines[i] = v
            }
        }
    }

    // MARK: Input

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key(let s):
            // A flower in this key's own color, on the nearest vine to the cursor.
            let hue = Int(s.unicodeScalars.reduce(3) { $0 &+ UInt32($1.value) }) % Self.flowerHues.count
            if let (vi, pi) = nearestVinePoint(to: ctx.cursor, within: 420) {
                if vines[vi].flowers.count < 24 {
                    vines[vi].flowers.append(Flower(pointIdx: pi, hue: hue,
                                                    birth: ctx.now, size: rng.range(9, 15),
                                                    phase: rng.range(0, 6.28)))
                }
            } else {
                plant(atX: ctx.cursor.x + rng.range(-30, 30), ctx.now)
            }
            ctx.audio?.note(for: s, intensity: ctx.intensity)
        case .click(let pt, .left):
            plant(atX: pt.x, ctx.now)
            ctx.audio?.drip(intensity: 0.5)   // the seed drops in
        case .scroll(let dy):
            // The wheel of seasons — continuous, wrapping, chiming each quarter.
            season += CGFloat(dy) * 0.045
            while season < 0 { season += 4 }
            while season >= 4 { season -= 4 }
            let q = Int(season)
            if q != lastSeasonQuarter {
                lastSeasonQuarter = q
                pulseSeason(q, ctx)
                ctx.audio?.glimmer()
            }
        default:
            break
        }
    }

    private func nearestVinePoint(to p: NSPoint, within: CGFloat) -> (Int, Int)? {
        var best: (Int, Int)? = nil
        var bestD = within * within
        for (vi, v) in vines.enumerated() {
            for (pi, q) in v.pts.enumerated() {
                let d2 = hypot2(q - p)
                if d2 < bestD { bestD = d2; best = (vi, pi) }
            }
        }
        return best
    }

    // Entering autumn sheds a burst of leaves; entering winter, the first snow.
    private func pulseSeason(_ q: Int, _ ctx: EffectContext) {
        if q == 2 {
            for v in vines {
                for (pi, p) in v.pts.enumerated() where pi % 4 == 2 && rng.unit() < 0.5 {
                    spawnFall(at: p, hue: rng.unit() < 0.5 ? -2 : -3)
                }
            }
        }
    }

    private func spawnFall(at p: NSPoint, hue: Int) {
        guard falls.count < 90 else { return }
        falls.append(Fall(p: p, vx: rng.range(-14, 14), vy: rng.range(-46, -22),
                          spin: rng.range(0, 6.28), spinV: rng.range(-3, 3),
                          birth: now, life: Double(rng.range(3.5, 6)),
                          hue: hue, size: hue == -1 ? rng.range(2.5, 4.5) : rng.range(5, 8)))
    }

    // MARK: Update

    private func seasonWeight(_ q: Int) -> CGFloat {
        // Triangular weight of quarter q at the current season position (wrapping).
        var d = abs(season - CGFloat(q))
        d = min(d, 4 - d)
        return max(0, 1 - d)
    }

    func update(_ ctx: EffectContext) {
        now = ctx.now
        bounds = ctx.bounds
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        let dt = ctx.dt

        if !seeded {
            seeded = true
            for _ in 0..<5 { plant(atX: rng.range(bounds.minX + 100, bounds.maxX - 100), now) }
            // Grass: a soft meadow line rooting the garden to the screen's bottom edge.
            grass.removeAll(keepingCapacity: true)
            var x = bounds.minX + 6
            while x < bounds.maxX {
                grass.append(Grass(x: x, h: rng.range(14, 42), lean: rng.range(-0.35, 0.35),
                                   phase: rng.range(0, 6.28)))
                x += rng.range(14, 30)
            }
        }

        if ctx.leftButtonDown && !draining { holdLevel += (1 - holdLevel) * min(1, dt * 2.2) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 2.5) }
        sunPos = ctx.cursor

        grow(dt)

        // Ambient weather: autumn sheds leaves, winter snows.
        let autumn = seasonWeight(2), winter = seasonWeight(3)
        if autumn > 0.2, rng.unit() < autumn * dt * 4, let v = vines.randomElementIdx(&rng) {
            let pts = vines[v].pts
            if pts.count > 4 { spawnFall(at: pts[Int(rng.range(2, CGFloat(pts.count - 1)))], hue: rng.unit() < 0.5 ? -2 : -3) }
        }
        if winter > 0.2, rng.unit() < winter * dt * 10 {
            spawnFall(at: NSPoint(x: rng.range(bounds.minX, bounds.maxX), y: bounds.maxY + 10), hue: -1)
        }
        for i in falls.indices {
            falls[i].vy = max(falls[i].vy - 26 * dt, falls[i].hue == -1 ? -46 : -78)
            falls[i].p.x += (falls[i].vx + CGFloat(sin(now * 1.4 + Double(falls[i].spin))) * 16) * dt
            falls[i].p.y += falls[i].vy * dt
            falls[i].spin += falls[i].spinV * dt
        }
        falls.removeAll { now - $0.birth > $0.life || $0.p.y < bounds.minY - 20 }

        // Sunshine pollen.
        if holdLevel > 0.3, rng.unit() < dt * 14 * holdLevel, pollen.count < 40 {
            pollen.append(Pollen(p: sunPos + NSPoint(x: rng.range(-70, 70), y: rng.range(-40, 20)),
                                 vy: rng.range(18, 44), birth: now, life: Double(rng.range(1.2, 2.2))))
        }
        for i in pollen.indices { pollen[i].p.y += pollen[i].vy * CGFloat(dt) }
        pollen.removeAll { now - $0.birth > $0.life }

        // Butterfly: eased chase with a figure-of-eight idle bob.
        let bob = NSPoint(x: CGFloat(sin(now * 2.1)) * 14, y: CGFloat(sin(now * 4.2)) * 8 + 22)
        let targetP = ctx.cursor + bob
        let d = targetP - flyPos
        flyVel.x += d.x * 4 * dt; flyVel.y += d.y * 4 * dt
        flyVel.x *= exp(-2.6 * dt); flyVel.y *= exp(-2.6 * dt)
        flyPos = flyPos + flyVel * dt
        let speed = sqrt(hypot2(flyVel))
        flap += (3 + min(14, speed * 0.06)) * dt
    }

    func liveCount() -> Int { vines.count + falls.count + pollen.count }

    // MARK: Draw

    private func seasonStem() -> NSColor {
        let sp = seasonWeight(0), su = seasonWeight(1), au = seasonWeight(2), wi = seasonWeight(3)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        func add(_ c: (CGFloat, CGFloat, CGFloat), _ w: CGFloat) { r += c.0 * w; g += c.1 * w; b += c.2 * w }
        add((0.32, 0.62, 0.3), sp); add((0.16, 0.45, 0.22), su)
        add((0.5, 0.35, 0.16), au); add((0.42, 0.38, 0.36), wi)
        let t = max(0.001, sp + su + au + wi)
        return NSColor(srgbRed: r / t, green: g / t, blue: b / t, alpha: 1)
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
        let sp = seasonWeight(0), su = seasonWeight(1), au = seasonWeight(2), wi = seasonWeight(3)
        let stemColor = seasonStem()

        // The meadow line: swaying grass blades along the bottom, season-tinted —
        // the garden grows out of somewhere, not from thin air.
        if !grass.isEmpty {
            let path = CGMutablePath()
            for g in grass {
                let gx = g.x - origin.x
                let gy = self.bounds.minY - origin.y
                let bend = g.lean + CGFloat(sin(now * 0.9 + Double(g.phase))) * 0.18
                let tipX = gx + bend * g.h, tipY = gy + g.h * (1 - wi * 0.35)
                path.move(to: CGPoint(x: gx, y: gy))
                path.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                                  control: CGPoint(x: gx + bend * g.h * 0.3, y: gy + g.h * 0.6))
            }
            let gw = inkWeight(bgMap, bgFallback, NSPoint(x: self.bounds.midX, y: self.bounds.minY + 20))
            ctx.setLineCap(.round); ctx.setLineWidth(2.2)
            ctx.setStrokeColor(blendColor(stemColor, .black, 0.25 + 0.3 * gw).withAlphaComponent(0.5).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineWidth(1.2)
            ctx.setStrokeColor(blendColor(stemColor, .white, 0.22 * (1 - gw)).withAlphaComponent(0.8).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }

        // Sunshine halo beneath everything.
        if holdLevel > 0.03 {
            let sr = 150 * holdLevel
            let sx = sunPos.x - origin.x, sy = sunPos.y - origin.y
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.5 * holdLevel)
            ctx.draw(Self.sunGlow, in: CGRect(x: sx - sr, y: sy - sr, width: sr * 2, height: sr * 2))
            ctx.setBlendMode(.normal); ctx.setAlpha(1)
        }

        for v in vines {
            guard v.pts.count > 1 else { continue }
            // Stem: swaying polyline, thicker at the root, season-tinted.
            let sway = CGFloat(sin(now * 0.7 + Double(v.phase))) * 4
            let path = CGMutablePath()
            for (i, p) in v.pts.enumerated() {
                let t = CGFloat(i) / CGFloat(max(1, v.pts.count - 1))
                let x = p.x - origin.x + sway * t * t
                let y = p.y - origin.y
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let rootP = v.pts[0]
            let w = inkWeight(bgMap, bgFallback, NSPoint(x: rootP.x, y: rootP.y + 120))
            ctx.setAlpha(1); ctx.setBlendMode(.normal); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setLineWidth(4.4)
            ctx.setStrokeColor(blendColor(stemColor, .black, 0.3 + 0.25 * w).withAlphaComponent(0.55).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineWidth(2.4)
            ctx.setStrokeColor(blendColor(stemColor, .white, 0.18 * (1 - w)).withAlphaComponent(0.9).cgColor)
            ctx.addPath(path); ctx.strokePath()

            // Leaves: alternating dabs; species by season blend; winter sheds them.
            let leafAlpha = (1 - wi * 0.9)
            if leafAlpha > 0.05 {
                for i in stride(from: 2, to: v.pts.count, by: 3) {
                    let p = v.pts[i]
                    let side: CGFloat = (i / 3) % 2 == 0 ? 1 : -1
                    let lx = p.x - origin.x + sway * 0.5, ly = p.y - origin.y
                    let ls = 9 + CGFloat((i * 7) % 6)
                    let wob = CGFloat(sin(now * 1.1 + Double(v.phase) + Double(i))) * 0.2
                    ctx.saveGState()
                    ctx.translateBy(x: lx, y: ly)
                    ctx.rotate(by: side * (0.7 + wob))
                    // Crossfade leaf species with the season wheel.
                    func leaf(_ img: CGImage, _ a: CGFloat) {
                        guard a > 0.03 else { return }
                        ctx.setAlpha(a * leafAlpha)
                        ctx.draw(img, in: CGRect(x: 0, y: -ls * 0.35, width: ls * 2.1, height: ls * 0.9))
                    }
                    leaf(Self.leafSpring, sp * 0.95)
                    leaf(Self.leafSummer, su * 0.95)
                    leaf((i % 8 == 3) ? Self.leafEmber : Self.leafGold, au * 0.95)
                    ctx.restoreGState()
                }
            }

            // Flowers: unfurl on bloom, close toward winter, warm to the sunshine.
            for f in v.flowers {
                guard f.pointIdx < v.pts.count else { continue }
                let p = v.pts[f.pointIdx]
                let open = min(1, CGFloat((now - f.birth) / 1.1))
                let winterClose = 1 - wi * 0.75
                let sunWarm: CGFloat = holdLevel > 0.1 && hypot2(p - sunPos) < 220 * 220 ? 1.25 : 1
                let size = f.size * open * winterClose * sunWarm
                guard size > 1.5 else { continue }
                let fx = p.x - origin.x + sway * 0.6, fy = p.y - origin.y
                let fw = inkWeight(bgMap, bgFallback, p)
                ctx.setAlpha(1)
                // Six petal dabs around a golden heart.
                for k in 0..<6 {
                    let a = CGFloat(k) / 6 * 2 * .pi + f.phase + CGFloat(sin(now * 0.5 + Double(f.phase))) * 0.1
                    let px = fx + cos(a) * size * 0.62, py = fy + sin(a) * size * 0.62
                    let pr = size * 0.5
                    if fw > 0.05 {
                        ctx.setAlpha(0.45 * fw)
                        ctx.draw(Self.dark, in: CGRect(x: px - pr * 1.25, y: py - pr * 1.25, width: pr * 2.5, height: pr * 2.5))
                    }
                    ctx.setAlpha(0.92)
                    ctx.draw(Self.flowerCores[f.hue], in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
                }
                let ga = 0.5 * (1 - 0.75 * fw)
                if ga > 0.02 {
                    ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                    let gr = size * 1.5
                    ctx.draw(Self.flowerGlows[f.hue], in: CGRect(x: fx - gr, y: fy - gr, width: gr * 2, height: gr * 2))
                    ctx.setBlendMode(.normal)
                }
                ctx.setAlpha(0.95)
                let hr = size * 0.34
                ctx.draw(Self.flowerCores[(f.hue + 2) % 12], in: CGRect(x: fx - hr, y: fy - hr, width: hr * 2, height: hr * 2))
            }
        }

        // Falling leaves & snow.
        ctx.setAlpha(1)
        for f in falls {
            let t = CGFloat((now - f.birth) / f.life)
            let a = (1 - t) * 0.85
            guard a > 0.03 else { continue }
            let x = f.p.x - origin.x, y = f.p.y - origin.y
            if f.hue == -1 {
                ctx.setAlpha(a)
                ctx.draw(Self.snowSprite, in: CGRect(x: x - f.size, y: y - f.size, width: f.size * 2, height: f.size * 2))
            } else {
                ctx.saveGState()
                ctx.translateBy(x: x, y: y)
                ctx.rotate(by: f.spin)
                ctx.setAlpha(a)
                let img = f.hue == -2 ? Self.leafGold : Self.leafEmber
                ctx.draw(img, in: CGRect(x: -f.size, y: -f.size * 0.4, width: f.size * 2, height: f.size * 0.8))
                ctx.restoreGState()
            }
        }

        // Pollen sparks rising through the sunshine.
        ctx.setBlendMode(.plusLighter)
        for s in pollen {
            let t = CGFloat((now - s.birth) / s.life)
            let a = (1 - t) * 0.7
            guard a > 0.03 else { continue }
            ctx.setAlpha(a)
            let r: CGFloat = 3
            ctx.draw(Self.sunGlow, in: CGRect(x: s.p.x - origin.x - r, y: s.p.y - origin.y - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal); ctx.setAlpha(1)

        // The butterfly: two flapping wing pairs + a tiny body, colors drifting slowly,
        // with a soft halo so the companion is unmissable.
        let bx = flyPos.x - origin.x, by = flyPos.y - origin.y
        let wingSpread = 0.3 + 0.7 * abs(sin(flap))
        let hue = Int(now * 0.35) % Self.flowerHues.count
        let bw2 = inkWeight(bgMap, bgFallback, flyPos)
        let halo = 0.5 * (1 - 0.7 * bw2)
        if halo > 0.03 {
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(halo)
            ctx.draw(Self.flowerGlows[hue], in: CGRect(x: bx - 24, y: by - 24, width: 48, height: 48))
            ctx.setBlendMode(.normal)
        }
        for side in [CGFloat(1), -1] {
            // Fore + hind wing per side, hind slightly smaller and lower.
            let wx = bx + side * 10 * wingSpread
            ctx.setAlpha(0.95)
            ctx.draw(Self.flowerCores[hue], in: CGRect(x: wx - 11, y: by - 7, width: 22, height: 15))
            ctx.setAlpha(0.8)
            let hx = bx + side * 7 * wingSpread
            ctx.draw(Self.flowerCores[(hue + 3) % 12], in: CGRect(x: hx - 8, y: by - 14, width: 16, height: 11))
        }
        ctx.setAlpha(0.95)
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: bx - 1.8, y: by - 7, width: 3.6, height: 14))
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}

private extension Array {
    // Uniform random index helper that plays nice with the scene RNG.
    func randomElementIdx(_ rng: inout RNG) -> Int? {
        isEmpty ? nil : Int(rng.range(0, CGFloat(count) - 0.001))
    }
}
