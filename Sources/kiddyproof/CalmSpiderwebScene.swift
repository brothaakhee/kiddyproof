import AppKit

// SILK — the kid IS the spider. The screen starts empty; the cursor is a spinneret
// that lays a silk thread along every path it travels. Keys burst small silk stars at
// the cursor; a click PLUCKS the nearest thread (a vibration travels down it, with a
// plucked-string tone); CLICK-AND-HOLD gathers nearby silk elastically and lets it
// spring back with a wobble; SCROLL is a breeze the whole web sways under. The web is
// the child's own construction and persists for the whole session (oldest threads are
// recycled only at the cap). Dew catches the light along the threads.
// (Total rebuild of the old static radial "Spiderweb", which Constellation obsoleted.)
final class CalmSpiderwebScene: Scene {
    let name = "Silk"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Thread {
        var pts: [NSPoint]
        var normals: [NSPoint]        // per-point perpendicular, for sway/vibration
        var phase: CGFloat
        var pluckTime: TimeInterval = -9
        var pluckIdx: Int = 0
    }

    private var threads: [Thread] = []
    // The thread currently being spun lives OUTSIDE the array: key-stars and tufts
    // append finished threads, and the spinneret must never accidentally extend those.
    private var current: Thread?
    private var totalPoints = 0
    private let maxPoints = 2400
    private let sampleGap: CGFloat = 14
    private var rng = RNG(seed: 0x51C4)

    private var now: TimeInterval = 0
    private var cursor = NSPoint.zero
    private var breeze: CGFloat = 0

    // Elastic gather (hold) + spring-back on release.
    private var holdLevel: CGFloat = 0
    private var holding = false
    private var releaseTime: TimeInterval = -9
    private var releaseLevel: CGFloat = 0
    private var releaseCursor = NSPoint.zero

    // Adaptive contrast cache.
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    private static let silkBright = NSColor(srgbRed: 0.9, green: 0.94, blue: 1.0, alpha: 1)
    private static let silkInk = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1)
    private static let dewCore: CGImage = softContrastSprite(NSColor(srgbRed: 0.55, green: 0.85, blue: 1.0, alpha: 1))
    private static let dewGlow: CGImage = softGlowSprite(NSColor(srgbRed: 0.85, green: 0.95, blue: 1.0, alpha: 1))
    private static let dewDark: CGImage = inkSprite(NSColor(white: 0, alpha: 1))

    var audioSwell: CGFloat { holdLevel * 0.2 }

    func reset() {
        threads.removeAll(keepingCapacity: true)
        current = nil
        totalPoints = 0
        breeze = 0; holdLevel = 0; holding = false
        releaseTime = -9; releaseLevel = 0
        draining = false
    }

    // MARK: Spinning

    private func startCurrent(at p: NSPoint) {
        if let c = current, c.pts.count > 1 { threads.append(c) }
        else if let c = current { totalPoints -= c.pts.count }   // drop a 1-point stub
        current = Thread(pts: [p], normals: [NSPoint(x: 0, y: 1)], phase: rng.range(0, 6.28))
        totalPoints += 1
    }

    private func extendCurrent(to p: NSPoint) {
        guard var c = current, var last = c.pts.last else { startCurrent(at: p); return }
        let d = p - last
        let len = sqrt(hypot2(d))
        guard len >= sampleGap else { return }
        // A teleport (display change, clamp jump) breaks the thread rather than
        // slashing a straight line across the screen.
        if len > 90 { startCurrent(at: p); return }
        // Long threads split so plucks and sways stay local and paths stay cheap.
        if c.pts.count >= 140 { startCurrent(at: last); c = current! }
        let n = NSPoint(x: -d.y / len, y: d.x / len)
        var step = last
        while sqrt(hypot2(p - step)) >= sampleGap {
            step = step + (p - step).normalized() * sampleGap
            c.pts.append(step); c.normals.append(n)
            totalPoints += 1
            last = step
        }
        current = c
        enforceCap()
    }

    private func enforceCap() {
        while totalPoints > maxPoints, !threads.isEmpty {
            totalPoints -= threads.removeFirst().pts.count   // oldest silk is re-spun
        }
    }

    // MARK: Input

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key:
            // A silk star: short threads radiating from the cursor.
            for _ in 0..<6 {
                let ang = rng.range(0, 6.28)
                let len = rng.range(55, 110)
                let dir = NSPoint(x: cos(ang), y: sin(ang))
                let n = NSPoint(x: -dir.y, y: dir.x)
                var t = Thread(pts: [], normals: [], phase: rng.range(0, 6.28))
                var s: CGFloat = 0
                while s <= len {
                    t.pts.append(ctx.cursor + dir * s); t.normals.append(n)
                    totalPoints += 1
                    s += sampleGap
                }
                threads.append(t)
            }
            enforceCap()
            ctx.audio?.note(for: ks(e), intensity: ctx.intensity)
        case .click(let pt, .left):
            // Pluck the nearest thread; if no silk is close, a tiny tuft appears (a
            // click must never do nothing).
            if let (ti, pi) = nearestPoint(to: pt, within: 130) {
                if ti == -1 { current?.pluckTime = ctx.now; current?.pluckIdx = pi }
                else { threads[ti].pluckTime = ctx.now; threads[ti].pluckIdx = pi }
            } else {
                for _ in 0..<3 {
                    let ang = rng.range(0, 6.28)
                    let dir = NSPoint(x: cos(ang), y: sin(ang))
                    let n = NSPoint(x: -dir.y, y: dir.x)
                    var t = Thread(pts: [], normals: [], phase: rng.range(0, 6.28))
                    for k in 0...4 { t.pts.append(pt + dir * (CGFloat(k) * sampleGap)); t.normals.append(n); totalPoints += 1 }
                    threads.append(t)
                }
                enforceCap()
            }
            ctx.audio?.pluck(intensity: ctx.intensity)
        case .scroll(let dy):
            breeze = max(-1.6, min(1.6, breeze + CGFloat(dy) * 0.15))
        default: break
        }
    }
    private func ks(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    // Thread index -1 means "the thread currently being spun".
    private func nearestPoint(to p: NSPoint, within: CGFloat) -> (Int, Int)? {
        var best: (Int, Int)? = nil
        var bestD = within * within
        for (ti, t) in threads.enumerated() {
            for (pi, q) in t.pts.enumerated() {
                let d2 = hypot2(q - p)
                if d2 < bestD { bestD = d2; best = (ti, pi) }
            }
        }
        if let c = current {
            for (pi, q) in c.pts.enumerated() {
                let d2 = hypot2(q - p)
                if d2 < bestD { bestD = d2; best = (-1, pi) }
            }
        }
        return best
    }

    // MARK: Update

    func update(_ ctx: EffectContext) {
        now = ctx.now
        cursor = ctx.cursor
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        breeze *= exp(-ctx.dt / 1.8)

        // The spinneret: silk follows wherever the cursor travels.
        if current == nil { startCurrent(at: ctx.cursor) }
        extendCurrent(to: ctx.cursor)

        // Elastic gather.
        let wasHolding = holding
        holding = ctx.leftButtonDown && !draining
        if holding { holdLevel += (1 - holdLevel) * min(1, ctx.dt * 3) }
        else { holdLevel += (0 - holdLevel) * min(1, ctx.dt * 6) }
        if wasHolding && !holding {
            releaseTime = now; releaseLevel = 1; releaseCursor = cursor
            ctx.audio?.pluck(intensity: 0.5)   // the whole web twangs free
        }
    }

    func liveCount() -> Int { threads.count + (current != nil ? 1 : 0) }

    // MARK: Draw

    // Display-time displacement of a silk point: gentle sway + breeze lean + pluck
    // wave traveling outward + elastic gather / springy release.
    private func displaced(_ t: Thread, _ i: Int) -> NSPoint {
        var p = t.pts[i]
        let n = t.normals[i]
        let sway = CGFloat(sin(now * 0.8 + Double(t.phase) + Double(i) * 0.25)) * (2.5 + 7 * abs(breeze))
        p.x += n.x * sway + breeze * 10 * CGFloat(sin(now * 0.6 + Double(t.phase)))
        p.y += n.y * sway

        let sincePluck = now - t.pluckTime
        if sincePluck < 1.4 {
            let dist = CGFloat(abs(i - t.pluckIdx))
            let amp = 10 * CGFloat(exp(-sincePluck * 2.4)) * exp(-dist * 0.055)
            p.x += n.x * amp * CGFloat(sin(Double(dist) * 0.55 - sincePluck * 20))
            p.y += n.y * amp * CGFloat(sin(Double(dist) * 0.55 - sincePluck * 20))
        }

        // Gather: silk near the held cursor stretches toward it; on release the pull
        // rings down through a damped overshoot (springs past rest, wobbles home).
        var pull: CGFloat = holdLevel * 0.55
        if !holding {
            let ts = now - releaseTime
            if ts < 1.2 { pull = releaseLevel * 0.55 * CGFloat(cos(ts * 11) * exp(-ts * 3.4)) }
        }
        if abs(pull) > 0.01 {
            let anchor = holding ? cursor : releaseCursor
            let d = anchor - p
            let dist = sqrt(hypot2(d))
            if dist < 180, dist > 1 {
                let k = (1 - dist / 180) * pull
                p.x += d.x * k; p.y += d.y * k
            }
        }
        return p
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        var all = threads
        if let c = current, c.pts.count > 1 { all.append(c) }
        for t in all where t.pts.count > 1 {
            let path = CGMutablePath()
            var first = displaced(t, 0)
            path.move(to: CGPoint(x: first.x - origin.x, y: first.y - origin.y))
            for i in 1..<t.pts.count {
                let p = displaced(t, i)
                path.addLine(to: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
            }
            let mid = t.pts[t.pts.count / 2]
            let w = inkWeight(bgMap, bgFallback, mid)
            let vibrating = now - t.pluckTime < 1.4
            let baseA: CGFloat = vibrating ? 0.85 : 0.55
            if baseA * (1 - w) > 0.03 {
                strokeContrast(ctx, path, width: vibrating ? 1.4 : 0.9,
                               alpha: baseA * (1 - w), coreColor: Self.silkBright)
            }
            if baseA * w > 0.03 {
                ctx.setBlendMode(.normal); ctx.setLineCap(.round)
                ctx.setLineWidth(vibrating ? 1.6 : 1.1)
                ctx.setStrokeColor(Self.silkInk.withAlphaComponent(baseA * w).cgColor)
                ctx.addPath(path); ctx.strokePath()
            }

            // Dew: sparse droplets riding the silk, twinkling.
            for i in stride(from: 3, to: t.pts.count, by: 11) {
                let p = displaced(t, i)
                let x = p.x - origin.x, y = p.y - origin.y
                let twinkle = 0.55 + 0.45 * CGFloat(sin(now * 1.3 + Double(t.phase) + Double(i)))
                let iw = inkWeight(bgMap, bgFallback, p)
                let rad: CGFloat = 3.2
                if iw > 0.05 {
                    ctx.setBlendMode(.normal); ctx.setAlpha(0.5 * twinkle * iw)
                    ctx.draw(Self.dewDark, in: CGRect(x: x - rad * 1.4, y: y - rad * 1.4, width: rad * 2.8, height: rad * 2.8))
                }
                ctx.setBlendMode(.normal); ctx.setAlpha(0.8 * twinkle)
                ctx.draw(Self.dewCore, in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
                let ga = 0.4 * twinkle * (1 - 0.7 * iw)
                if ga > 0.02 {
                    ctx.setBlendMode(.plusLighter); ctx.setAlpha(ga)
                    ctx.draw(Self.dewGlow, in: CGRect(x: x - rad * 2, y: y - rad * 2, width: rad * 4, height: rad * 4))
                }
            }
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}

private extension NSPoint {
    func normalized() -> NSPoint {
        let l = sqrt(x * x + y * y)
        return l > 0 ? NSPoint(x: x / l, y: y / l) : NSPoint(x: 1, y: 0)
    }
}
