import AppKit

// CONSTELLATION — a calm scene of slowly drifting stars that connect with delicate
// light-lines when they (or the cursor) pass near each other, forming a living web.
// A keypress adds a star; a click sends a soft pulse of brightness rippling outward
// through the web. Lines use a mid-tone color so they read on light AND dark wallpaper;
// stars use the shared contrast sprite. No veil — the parent's real screen stays visible.
final class CalmConstellationScene: Scene {
    let name = "Constellation"
    let category = SceneCategory.calm
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

    private var stars: [Star] = []
    private var pulses: [Pulse] = []
    private var links: [UInt64: Link] = [:]
    private var nextId = 0
    private let ambientCount = 72
    private let maxStars = 150
    private let linkDist: CGFloat = 150
    private let linkFadeTau: CGFloat = 0.22
    private var rng = RNG(seed: 0xC047E)
    private var seededSize = CGSize.zero
    private var nowCache: TimeInterval = 0

    private func makeId() -> Int { defer { nextId += 1 }; return nextId }
    private func linkKey(_ a: Int, _ b: Int) -> UInt64 { (UInt64(max(a, b)) << 32) | UInt64(min(a, b)) }

    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.97, blue: 1.0, alpha: 1),   // soft white
        NSColor(srgbRed: 0.7, green: 0.85, blue: 1.0, alpha: 1),    // pale blue
        NSColor(srgbRed: 1.0, green: 0.9, blue: 0.7, alpha: 1),     // warm starlight
    ]
    private static let cores: [CGImage] = swatches.map { softContrastSprite($0) }
    private static let glows: [CGImage] = swatches.map { softGlowSprite($0) }
    // Pale blue line core (shows on dark); the contrast stroke's dark casing handles light bg.
    private static let lineColor = NSColor(srgbRed: 0.82, green: 0.89, blue: 1.0, alpha: 1)

    func reset() {
        stars.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        links.removeAll(keepingCapacity: true)
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
                              color: rng.int(Self.cores.count), size: rng.range(2.5, 5.5),
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
                                  color: rng.int(Self.cores.count), size: rng.range(3, 6),
                                  phase: rng.range(0, 6.28), life: Double(rng.range(8, 13)),
                                  birth: ctx.now, ambient: false, id: makeId()))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            if pulses.count < 6 { pulses.append(Pulse(pos: pt, birth: ctx.now)) }
            ctx.audio?.whoosh()
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        nowCache = ctx.now
        let dt = ctx.dt
        let cur = ctx.cursor
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

        // Maintain the link set with a temporal fade. Decay every link; refresh the ones
        // whose stars are currently in range (target = distance-based alpha, also fades in
        // from 0 as stars approach). Links that drop out of range (separation, wrap, or a
        // star despawning) are simply not refreshed, so they ease to 0 over ~linkFadeTau
        // using their last-known endpoints — no instant pop.
        let decay = CGFloat(exp(-dt / linkFadeTau))
        for k in Array(links.keys) { links[k]!.alpha *= decay }
        let t2 = linkDist * linkDist
        let n = stars.count
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
                } else {
                    links[key] = Link(alpha: target, a: sa, b: stars[b].pos)
                }
            }
        }
        links = links.filter { $0.value.alpha > 0.02 }
    }

    func liveCount() -> Int { stars.count + pulses.count }

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

        // 1) Links from the maintained set, batched into 12 alpha buckets (finer than 8 so
        // the fade reads smoothly), one contrast stroke per bucket.
        var buckets = [Int: CGMutablePath]()
        for link in links.values {
            let q = min(11, Int(link.alpha * 12))
            guard q >= 0, link.alpha > 0.02 else { continue }
            let path = buckets[q] ?? { let m = CGMutablePath(); buckets[q] = m; return m }()
            path.move(to: CGPoint(x: link.a.x - origin.x, y: link.a.y - origin.y))
            path.addLine(to: CGPoint(x: link.b.x - origin.x, y: link.b.y - origin.y))
        }
        for (q, path) in buckets {
            let a = CGFloat(q + 1) / 12
            // soft ink bleed under-stroke (glows on dark, harmless on light)…
            ctx.setBlendMode(.plusLighter); ctx.setLineCap(.round); ctx.setLineWidth(5)
            ctx.setStrokeColor(Self.lineColor.withAlphaComponent(a * 0.16).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setBlendMode(.normal)
            // …then a crisp contrast core so the brushy line still reads on light bg.
            strokeContrast(ctx, path, width: 1.6, alpha: a, coreColor: Self.lineColor)
        }

        // 2) Stars (contrast core + additive glow), brightened by nearby pulses + twinkle.
        for s in stars {
            let twinkle = 0.75 + 0.25 * CGFloat(sin(now * 1.1 + Double(s.phase)))
            var a = twinkle
            if !s.ambient {
                let age = now - s.birth
                a *= min(1, CGFloat(age / 1.0)) * max(0, min(1, CGFloat((s.life - age) / 1.5)))
            }
            let boost = pulseBoost(s.pos)
            let r = s.size * (1 + 0.6 * boost)
            let cx = s.pos.x - origin.x, cy = s.pos.y - origin.y
            ctx.setBlendMode(.normal); ctx.setAlpha(min(1, a))
            ctx.draw(Self.cores[s.color % Self.cores.count], in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(min(1, (0.4 + boost) * a))
            let gr = r * 2.2
            ctx.draw(Self.glows[s.color % Self.glows.count], in: CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2))
        }
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }
}
