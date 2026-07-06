import AppKit

// CONSTELLATION — a calm scene of slowly drifting stars that connect with delicate
// light-lines when they (or the cursor) pass near each other, forming a living web.
// A keypress adds a star; a click sends a soft pulse of brightness rippling outward;
// SCROLL sends shooting stars streaking across the sky; CLICK-AND-HOLD reveals a
// constellation — the nearest stars link into a glowing figure that dissolves back
// into the web on release.
//
// Two renderings, inverted for the wallpaper: in system DARK mode the web is starlight
// (bright cores + additive glow); in LIGHT mode it inverts into an ink-black web —
// near-black stars and lines that read like a spider's chart on paper. (The app cannot
// see the actual wallpaper without Screen Recording permission, so system appearance
// is the proxy; KP_TESTBG=white/gray forces ink, KP_TESTBG=black forces starlight.)
final class CalmConstellationScene: Scene {
    let name = "Constellation"
    let category = SceneCategory.live
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Star {
        var pos: NSPoint; var vel: NSPoint
        var color: Int; var size: CGFloat; var phase: CGFloat
        var life: Double; var birth: TimeInterval; var ambient: Bool
        var id: Int
    }
    private struct Pulse { let pos: NSPoint; let birth: TimeInterval }
    // A connection between two stars. Its strength decays when out of range so links
    // FADE out (over ~0.25s) instead of popping — even when a star wraps or despawns.
    private struct Link { var alpha: CGFloat; var a: NSPoint; var b: NSPoint }
    private struct Meteor { var pos: NSPoint; var vel: NSPoint; var birth: TimeInterval; var life: Double }

    private var stars: [Star] = []
    private var pulses: [Pulse] = []
    private var links: [UInt64: Link] = [:]
    private var meteors: [Meteor] = []
    private var nextId = 0
    private let ambientCount = 72
    private let maxStars = 150
    private let linkDist: CGFloat = 150
    private let linkFadeTau: CGFloat = 0.22
    private var rng = RNG(seed: 0xC047E)
    private var seededSize = CGSize.zero
    private var nowCache: TimeInterval = 0

    // Shooting-star budget charged by scrolling.
    private var meteorBudget: CGFloat = 0
    private var meteorDir: CGFloat = 1
    private var lastMeteor: TimeInterval = 0

    // Constellation reveal (hold): member star ids are locked at hold start so the
    // figure doesn't reshuffle mid-hold; it lingers briefly after release.
    private var figureIds: [Int] = []
    private var holdLevel: CGFloat = 0
    private var holding = false

    // Adaptive contrast: cached from the last update() so draw() can weigh starlight
    // vs ink PER ELEMENT (with the opt-in luminance map, a web spanning a dark
    // terminal and a white browser renders each star/line for what's behind it).
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3
    private var lastCursor = NSPoint.zero

    private func makeId() -> Int { defer { nextId += 1 }; return nextId }
    private func linkKey(_ a: Int, _ b: Int) -> UInt64 { (UInt64(max(a, b)) << 32) | UInt64(min(a, b)) }

    // Starlight set (dark wallpaper).
    private static let brightSwatches: [NSColor] = [
        NSColor(srgbRed: 0.92, green: 0.95, blue: 1.0, alpha: 1),   // starlight white
        NSColor(srgbRed: 0.62, green: 0.80, blue: 1.0, alpha: 1),   // pale blue
        NSColor(srgbRed: 1.0, green: 0.86, blue: 0.58, alpha: 1),   // warm starlight
    ]
    private static let brightCores: [CGImage] = brightSwatches.map { softContrastSprite($0) }
    private static let brightGlows: [CGImage] = brightSwatches.map { softGlowSprite($0) }
    private static let brightLine = NSColor(srgbRed: 0.82, green: 0.89, blue: 1.0, alpha: 1)
    private static let brightFigure = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1)

    // Ink set (light wallpaper): the same web as near-black ink on paper.
    private static let inkSwatches: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),  // ink navy
        NSColor(srgbRed: 0.16, green: 0.10, blue: 0.26, alpha: 1),  // ink violet
        NSColor(srgbRed: 0.05, green: 0.17, blue: 0.19, alpha: 1),  // ink teal
    ]
    private static let inkCores: [CGImage] = inkSwatches.map { inkSprite($0) }
    private static let inkLine = NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1)
    private static let inkFigure = NSColor(srgbRed: 0.38, green: 0.24, blue: 0.04, alpha: 1)

    // The reveal hums softly while it forms.
    var audioSwell: CGFloat { holdLevel * 0.25 }

    func reset() {
        stars.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        links.removeAll(keepingCapacity: true)
        meteors.removeAll(keepingCapacity: true)
        figureIds.removeAll(); holdLevel = 0; holding = false
        meteorBudget = 0; lastMeteor = 0
        nextId = 0; seededSize = .zero; draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard bounds.size != seededSize else { return }
        seededSize = bounds.size
        stars.removeAll(keepingCapacity: true)
        for _ in 0..<ambientCount {
            stars.append(Star(pos: NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                                           y: rng.range(bounds.minY, bounds.maxY)),
                              vel: NSPoint(x: rng.range(-10, 10), y: rng.range(-10, 10)),
                              color: rng.int(Self.brightCores.count), size: rng.range(2.5, 5.5),
                              phase: rng.range(0, 6.28), life: 0, birth: 0, ambient: true, id: makeId()))
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            if stars.count < maxStars {
                stars.append(Star(pos: ctx.cursor + NSPoint(x: rng.range(-18, 18), y: rng.range(-18, 18)),
                                  vel: NSPoint(x: rng.range(-8, 8), y: rng.range(-8, 8)),
                                  color: rng.int(Self.brightCores.count), size: rng.range(3, 6),
                                  phase: rng.range(0, 6.28), life: Double(rng.range(8, 13)),
                                  birth: ctx.now, ambient: false, id: makeId()))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            if pulses.count < 6 { pulses.append(Pulse(pos: pt, birth: ctx.now)) }
            ctx.audio?.ping()   // crystalline, not windy — this sky's own voice
        case .scroll(let dy):
            meteorBudget = min(3, meteorBudget + abs(CGFloat(dy)) * 0.2)
            meteorDir = dy >= 0 ? 1 : -1
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        nowCache = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        lastCursor = ctx.cursor
        let dt = ctx.dt
        let cur = ctx.cursor

        // Constellation reveal: lock the nearest stars at hold start.
        let wasHolding = holding
        holding = ctx.leftButtonDown && !draining
        if holding && !wasHolding { pickFigure(around: cur) }
        if holding { holdLevel += (1 - holdLevel) * min(1, dt * 2.4) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 1.6) }   // linger, then dissolve
        if wasHolding && !holding {
            if pulses.count < 6 { pulses.append(Pulse(pos: cur, birth: ctx.now)) }
            ctx.audio?.glimmer()
        }
        if holdLevel < 0.03 && !holding { figureIds.removeAll(keepingCapacity: true) }

        var i = 0
        while i < stars.count {
            if !stars[i].ambient, ctx.now - stars[i].birth >= stars[i].life { stars.remove(at: i); continue }
            var v = stars[i].vel
            v.x += rng.range(-5, 5) * dt
            v.y += rng.range(-5, 5) * dt
            // very gentle drift toward the cursor so the web breathes around it
            let d = cur - stars[i].pos
            let dist2 = hypot2(d)
            if dist2 > 25, dist2 < 260 * 260 {
                let dist = sqrt(dist2)
                let f = (30 + 50 * ctx.intensity) / max(80, dist)
                v.x += d.x / dist * f * dt; v.y += d.y / dist * f * dt
            }
            // figure members are tethered gently — the revealed shape tightens a touch
            if holdLevel > 0.05, figureIds.contains(stars[i].id), dist2 > 60 * 60 {
                let dist = sqrt(dist2)
                v.x += d.x / dist * 26 * holdLevel * dt
                v.y += d.y / dist * 26 * holdLevel * dt
            }
            v.x *= exp(-0.8 * dt); v.y *= exp(-0.8 * dt)
            let sp2 = hypot2(v)
            if sp2 > 45 * 45 { let s = 45 / sqrt(sp2); v.x *= s; v.y *= s }
            stars[i].vel = v
            var p = stars[i].pos + v * dt
            if p.x < ctx.bounds.minX - 30 { p.x = ctx.bounds.maxX + 30 }
            if p.x > ctx.bounds.maxX + 30 { p.x = ctx.bounds.minX - 30 }
            if p.y < ctx.bounds.minY - 30 { p.y = ctx.bounds.maxY + 30 }
            if p.y > ctx.bounds.maxY + 30 { p.y = ctx.bounds.minY - 30 }
            stars[i].pos = p
            i += 1
        }
        pulses.removeAll { ctx.now - $0.birth > 1.6 }

        // Shooting stars: spend the scroll budget, sparse and unhurried.
        if meteorBudget >= 1, ctx.now - lastMeteor > 0.45, meteors.count < 3 {
            meteorBudget -= 1
            lastMeteor = ctx.now
            let fromLeft = meteorDir > 0
            let x0 = fromLeft ? ctx.bounds.minX - 30 : ctx.bounds.maxX + 30
            let y0 = rng.range(ctx.bounds.midY, ctx.bounds.maxY - 40)
            let speed = rng.range(620, 900)
            meteors.append(Meteor(pos: NSPoint(x: x0, y: y0),
                                  vel: NSPoint(x: (fromLeft ? 1 : -1) * speed * 0.94, y: -speed * 0.34),
                                  birth: ctx.now, life: 3.5))
            ctx.audio?.whoosh()
        }
        meteorBudget *= exp(-CGFloat(dt) / 4)
        for m in meteors.indices { meteors[m].pos = meteors[m].pos + meteors[m].vel * CGFloat(dt) }
        meteors.removeAll {
            ctx.now - $0.birth > $0.life ||
            $0.pos.x < ctx.bounds.minX - 300 || $0.pos.x > ctx.bounds.maxX + 300 || $0.pos.y < ctx.bounds.minY - 100
        }

        maintainLinks(dt: CGFloat(dt))
    }

    // Nearest stars around the hold point, ordered by angle so the closed loop reads
    // as a figure instead of a scribble.
    private func pickFigure(around p: NSPoint) {
        let byDist = stars.enumerated()
            .map { (dist: hypot2($0.element.pos - p), idx: $0.offset) }
            .filter { $0.dist < 420 * 420 }
            .sorted { $0.dist < $1.dist }
            .prefix(7)
        let members = byDist.map { stars[$0.idx] }
            .sorted {
                atan2(Double($0.pos.y - p.y), Double($0.pos.x - p.x)) <
                atan2(Double($1.pos.y - p.y), Double($1.pos.x - p.x))
            }
        figureIds = members.map { $0.id }
    }

    // Link maintenance — the ORIGINAL semantics, uncapped: every in-range pair links,
    // which is what makes a key-mash erupt into a dense living web (the scene's best
    // moment). Decay all links, refresh the in-range ones, prune the faded — in that
    // order, exactly as before. (A per-star link cap was tried and walked back: it
    // starved the mash-web and picked survivors by iteration order.)
    private func maintainLinks(dt: CGFloat) {
        // ONE dictionary rebuild per frame (decay + prune together); the old
        // decay-pass + filter-pass copied the whole dict twice at 60fps.
        let decay = CGFloat(exp(-dt / linkFadeTau))
        links = links.compactMapValues { link in
            var l = link
            l.alpha *= decay
            return l.alpha > 0.02 ? l : nil
        }
        let t2 = linkDist * linkDist
        let n = stars.count
        // Soft ceiling: existing links always refresh (the mash-web stays dense and
        // alive), but NEW links stop forming past 3000 — the pathological all-pairs
        // cluster (~11k links, triple-stroked, per display) fell off the frame budget.
        var canGrow = links.count < 3000
        for a in 0..<n {
            let sa = stars[a].pos
            for b in (a + 1)..<n {
                let d2 = hypot2(stars[b].pos - sa)
                guard d2 < t2 else { continue }
                let target = (1 - d2 / t2) * 0.85
                let key = linkKey(stars[a].id, stars[b].id)
                if links[key] != nil {
                    links[key]!.alpha = max(links[key]!.alpha, target)
                    links[key]!.a = sa; links[key]!.b = stars[b].pos
                } else if canGrow {
                    links[key] = Link(alpha: target, a: sa, b: stars[b].pos)
                    canGrow = links.count < 3000
                }
            }
        }
    }

    func liveCount() -> Int { stars.count + pulses.count + meteors.count }

    // Extra brightness for a star sitting on an expanding pulse front.
    private func pulseBoost(_ p: NSPoint) -> CGFloat {
        var boost: CGFloat = 0
        for pulse in pulses {
            let age = nowCache - pulse.birth
            let frontR = CGFloat(age) * 320
            let band = sqrt(hypot2(p - pulse.pos)) - frontR
            let g = exp(-(band * band) / (2 * 55 * 55))      // gaussian around the front
            boost += g * CGFloat(max(0, 1 - age / 1.6)) * 0.9
        }
        return min(1, boost)
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let now = nowCache

        // 1) Links, batched into 12 alpha buckets — TWO bucket sets, starlight and
        // ink, each link split by the ink weight of the pixels behind its midpoint.
        // Over a mixed desktop the same web is glow where it crosses dark windows and
        // confident black ink where it crosses bright ones.
        var brightBuckets = [Int: CGMutablePath]()
        var inkBuckets = [Int: CGMutablePath]()
        for link in links.values {
            guard link.alpha > 0.02 else { continue }
            let mid = NSPoint(x: (link.a.x + link.b.x) / 2, y: (link.a.y + link.b.y) / 2)
            let w = inkWeight(bgMap, bgFallback, mid)
            func add(_ buckets: inout [Int: CGMutablePath], _ alpha: CGFloat) {
                let q = min(11, Int(alpha * 12))
                guard alpha > 0.03 else { return }
                let path = buckets[q] ?? { let m = CGMutablePath(); buckets[q] = m; return m }()
                path.move(to: CGPoint(x: link.a.x - origin.x, y: link.a.y - origin.y))
                path.addLine(to: CGPoint(x: link.b.x - origin.x, y: link.b.y - origin.y))
            }
            add(&brightBuckets, link.alpha * (1 - w))
            add(&inkBuckets, link.alpha * w)
        }
        for (q, path) in brightBuckets {
            let a = CGFloat(q + 1) / 12
            // soft bleed under-stroke (glows on dark)…
            ctx.setBlendMode(.plusLighter); ctx.setLineCap(.round); ctx.setLineWidth(5)
            ctx.setStrokeColor(Self.brightLine.withAlphaComponent(a * 0.16).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setBlendMode(.normal)
            // …then a crisp contrast core so the line still reads on light bg.
            strokeContrast(ctx, path, width: 1.6, alpha: a, coreColor: Self.brightLine)
        }
        for (q, path) in inkBuckets {
            let a = CGFloat(q + 1) / 12
            // Ink web on paper: one confident near-black line, no glow.
            ctx.setBlendMode(.normal); ctx.setLineCap(.round); ctx.setLineWidth(1.7)
            ctx.setStrokeColor(Self.inkLine.withAlphaComponent(a * 0.9).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }

        // 2) The revealed constellation: a closed golden figure through its members.
        if holdLevel > 0.03, figureIds.count > 2 {
            var pts: [CGPoint] = []
            for id in figureIds {
                if let s = stars.first(where: { $0.id == id }) {
                    pts.append(CGPoint(x: s.pos.x - origin.x, y: s.pos.y - origin.y))
                }
            }
            if pts.count > 2 {
                let path = CGMutablePath()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                let fa = holdLevel
                let w = inkWeight(bgMap, bgFallback, lastCursor)
                if fa * (1 - w) > 0.03 {
                    ctx.setBlendMode(.plusLighter); ctx.setLineCap(.round); ctx.setLineWidth(7)
                    ctx.setStrokeColor(Self.brightFigure.withAlphaComponent(fa * (1 - w) * 0.22).cgColor)
                    ctx.addPath(path); ctx.strokePath()
                    ctx.setBlendMode(.normal)
                    strokeContrast(ctx, path, width: 2.2, alpha: fa * (1 - w), coreColor: Self.brightFigure)
                }
                if fa * w > 0.03 {
                    ctx.setBlendMode(.normal); ctx.setLineCap(.round); ctx.setLineWidth(2.6)
                    ctx.setStrokeColor(Self.inkFigure.withAlphaComponent(fa * w * 0.95).cgColor)
                    ctx.addPath(path); ctx.strokePath()
                }
            }
        }

        // 3) Shooting stars: a bright head with a tapering trail of stamps behind it.
        for m in meteors {
            let dirLen = sqrt(hypot2(m.vel))
            guard dirLen > 1 else { continue }
            let dir = NSPoint(x: m.vel.x / dirLen, y: m.vel.y / dirLen)
            let fade = CGFloat(min(1, (m.life - (now - m.birth)) / 0.8))
            let steps = 9
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps - 1)
                let px = m.pos.x - dir.x * t * 170 - origin.x
                let py = m.pos.y - dir.y * t * 170 - origin.y
                let r = (5.5 - 3.8 * t)
                let a = (1 - t) * (1 - t) * 0.8 * fade
                let w = inkWeight(bgMap, bgFallback, NSPoint(x: px + origin.x, y: py + origin.y))
                if a * w > 0.02 {
                    ctx.setBlendMode(.normal); ctx.setAlpha(a * w)
                    ctx.draw(Self.inkCores[0], in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
                }
                if a * (1 - w) > 0.02 {
                    ctx.setBlendMode(.normal); ctx.setAlpha(a * (1 - w))
                    ctx.draw(Self.brightCores[2], in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
                    ctx.setBlendMode(.plusLighter); ctx.setAlpha(a * (1 - w) * 0.7)
                    let gr = r * 2
                    ctx.draw(Self.brightGlows[2], in: CGRect(x: px - gr, y: py - gr, width: gr * 2, height: gr * 2))
                }
            }
        }
        ctx.setAlpha(1)

        // 4) Stars, brightened by pulses + twinkle; figure members shine.
        for s in stars {
            let twinkle = 0.75 + 0.25 * CGFloat(sin(now * 1.1 + Double(s.phase)))
            var a = twinkle
            if !s.ambient {
                let age = now - s.birth
                a *= min(1, CGFloat(age / 1.0)) * max(0, min(1, CGFloat((s.life - age) / 1.5)))
            }
            let member = holdLevel > 0.03 && figureIds.contains(s.id)
            let boost = max(pulseBoost(s.pos), member ? holdLevel * 0.9 : 0)
            let r = s.size * (1 + 0.6 * boost)
            let cx = s.pos.x - origin.x, cy = s.pos.y - origin.y
            let w = inkWeight(bgMap, bgFallback, s.pos)
            if a * w > 0.02 {   // ink dot: solid, no glow, a touch larger to carry
                ctx.setBlendMode(.normal); ctx.setAlpha(min(1, a * w * (0.75 + 0.25 * boost)))
                let img = member ? Self.inkCores[1] : Self.inkCores[s.color % Self.inkCores.count]
                let ir = r * 1.5
                ctx.draw(img, in: CGRect(x: cx - ir, y: cy - ir, width: ir * 2, height: ir * 2))
            }
            if a * (1 - w) > 0.02 {   // starlight: contrast core + additive glow
                ctx.setBlendMode(.normal); ctx.setAlpha(min(1, a * (1 - w)))
                ctx.draw(Self.brightCores[s.color % Self.brightCores.count], in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(min(1, (0.4 + boost) * a * (1 - w)))
                let gr = r * 2.2
                ctx.draw(Self.brightGlows[s.color % Self.brightGlows.count], in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
            }
        }
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }
}
