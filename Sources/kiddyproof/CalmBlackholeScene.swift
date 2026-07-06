import AppKit

// BLACK HOLE — the cursor is a vacuum. Just MOVING pulls only nearby nodes; HOLDING the
// click (or a click spike) cranks suction ~100× and widens its reach to the whole field,
// hauling nodes in. Nodes that reach the hole are CAPTURED — held churning in the core —
// and stay trapped until released. A KEYPRESS is the opposite: a 100× negative-gravity
// burst that releases the captured core and blasts every node outward. The hole grows as
// it eats and is drawn as a real event horizon + accretion disk + photon ring.
final class CalmBlackholeScene: Scene {
    let name = "Black Hole"
    let category = SceneCategory.live
    let reactivity = Reactivity.calm
    let skin = CursorSkin.none          // we draw the hole ourselves
    let veil: CGFloat = 0
    var draining = false
    // Suction (boost 1→100) drives the swelling vacuum hum.
    var audioSwell: CGFloat { min(1, (boost - 1) / 99) }

    private struct Mote {
        var pos: NSPoint; var vel: NSPoint; var color: Int; var size: CGFloat
        var captured: Bool; var capFrac: CGFloat = 0; var capAng: CGFloat = 0   // orbit in the core
    }
    private var motes: [Mote] = []
    private var pulses: [TimeInterval] = []      // outward shockwave rings (keypress)
    private var boost: CGFloat = 1               // suction multiplier (≈100 while clicking)
    private var repelUntil: TimeInterval = 0     // negative-gravity burst window
    private var capturedCount = 0
    private let startCount = 90
    private var rng = RNG(seed: 0xB1AC4)
    private var seededSize = CGSize.zero
    private var hole = NSPoint.zero
    private var nowCache: TimeInterval = 0

    private let baseRadius: CGFloat = 200
    private let baseG: CGFloat = 72_000

    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.85, blue: 0.6, alpha: 1),
        NSColor(srgbRed: 0.7, green: 0.82, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.7, blue: 1.0, alpha: 1),
    ]
    private static let cores: [CGImage] = swatches.map { softContrastSprite($0) }
    private static let glows: [CGImage] = swatches.map { softGlowSprite($0) }
    private static let accretion = CGGradient(colorsSpace: sharedRGB, colors: [
        NSColor.clear.cgColor, NSColor.clear.cgColor,
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 0.95).cgColor,
        NSColor(srgbRed: 1.0, green: 0.85, blue: 0.4, alpha: 0.8).cgColor,
        NSColor(srgbRed: 0.5, green: 0.7, blue: 1.0, alpha: 0.28).cgColor, NSColor.clear.cgColor,
    ] as CFArray, locations: [0, 0.5, 0.58, 0.66, 0.82, 1])
    private static let lensing = CGGradient(colorsSpace: sharedRGB, colors: [
        NSColor(srgbRed: 0.5, green: 0.6, blue: 1.0, alpha: 0.18).cgColor,
        NSColor(srgbRed: 0.4, green: 0.5, blue: 1.0, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])

    func reset() {
        motes.removeAll(keepingCapacity: true); pulses.removeAll()
        boost = 1; repelUntil = 0; capturedCount = 0; seededSize = .zero; draining = false
    }

    private func seedIfNeeded(_ b: CGRect) {
        guard b.size != seededSize else { return }
        seededSize = b.size
        motes.removeAll(keepingCapacity: true)
        for _ in 0..<startCount {
            motes.append(Mote(pos: NSPoint(x: rng.range(b.minX, b.maxX), y: rng.range(b.minY, b.maxY)),
                              vel: NSPoint(x: rng.range(-16, 16), y: rng.range(-16, 16)),
                              color: rng.int(Self.cores.count), size: rng.range(3.5, 6.5), captured: false))
        }
    }

    private var eventR: CGFloat { 24 + min(CGFloat(capturedCount), 120) * 0.34 }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .click(_, .left):
            boost = 100                          // 100× suction spike (the swelling hum is the cue)
        case .key:
            repelUntil = ctx.now + 0.4           // 100× outward negative-gravity burst
            if pulses.count < 6 { pulses.append(ctx.now) }
            ctx.audio?.burst()                   // soft reverb-tailed release whoomph
        default: break
        }
    }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        nowCache = ctx.now
        hole = ctx.cursor
        let dt = ctx.dt
        // Hold sustains the gulp; otherwise it eases back to 1.
        if ctx.leftButtonDown { boost = max(boost, 100) } else { boost = 1 + (boost - 1) * CGFloat(exp(-dt / 0.6)) }
        if boost < 1 { boost = 1 }
        pulses.removeAll { ctx.now - $0 > 1.6 }

        let repelling = ctx.now < repelUntil
        let diag = sqrt(hypot2(NSPoint(x: ctx.bounds.width, y: ctx.bounds.height)))
        let reach2 = min(baseRadius * boost, diag) * min(baseRadius * boost, diag)
        let g = baseG * boost
        let eps2: CGFloat = 36 * 36
        let er = eventR
        var cap = 0

        for i in motes.indices {
            // CAPTURED = held kinematically on a slowly-churning orbit inside the core. No
            // velocity/forces → it is physically impossible to overshoot the centre and
            // shoot out the far side. Released only by a repel burst (below).
            if motes[i].captured && !repelling {
                cap += 1
                motes[i].capAng += 1.3 * dt
                let rr = er * motes[i].capFrac
                let tx = hole.x + cos(motes[i].capAng) * rr
                let ty = hole.y + sin(motes[i].capAng) * rr
                let l = min(1, dt * 9)
                motes[i].pos.x += (tx - motes[i].pos.x) * l
                motes[i].pos.y += (ty - motes[i].pos.y) * l
                motes[i].vel = .zero
                continue
            }

            let d = hole - motes[i].pos
            let dist2 = hypot2(d) + eps2
            let dist = sqrt(dist2)
            let nx = d.x / dist, ny = d.y / dist
            var v = motes[i].vel
            if repelling {
                motes[i].captured = false
                let outA = baseG * 100 / dist2          // negative gravity (×100)
                v.x -= nx * outA * dt; v.y -= ny * outA * dt
            } else if dist2 < reach2 {
                // Inverse-square pull PLUS a near-constant haul that scales with boost, so a
                // 100× click vacuums the WHOLE field inward (not just nearby nodes).
                let a = g / dist2 + (boost - 1) * 16
                v.x += nx * a * dt; v.y += ny * a * dt
                v.x += -ny * (g / dist2) * 0.12 * dt; v.y += nx * (g / dist2) * 0.12 * dt
                // Brake hard near the hole so a fast node can't whip straight through the
                // capture zone uncaught (the real cause of "breaks through the middle").
                let prox = max(0, 1 - dist / (er * 4.5))
                let brake = CGFloat(exp(-prox * 8 * dt))
                v.x *= brake; v.y *= brake
                if dist < er + 40 {                      // generous capture → flybys get caught
                    motes[i].captured = true
                    motes[i].capFrac = rng.range(0.16, 0.74)
                    motes[i].capAng = atan2(motes[i].pos.y - hole.y, motes[i].pos.x - hole.x)
                    motes[i].vel = .zero
                    cap += 1
                    continue
                }
            } else {
                v.x += rng.range(-6, 6) * dt; v.y += rng.range(-6, 6) * dt
                v.x *= exp(-0.5 * dt); v.y *= exp(-0.5 * dt)
            }
            let vmax: CGFloat = repelling ? 2000 : 1400
            let sp2 = hypot2(v)
            if sp2 > vmax * vmax { let s = vmax / sqrt(sp2); v.x *= s; v.y *= s }
            motes[i].vel = v
            motes[i].pos = motes[i].pos + v * dt

            // Bounce off the edges of the simulation bounds (the whole desktop across all
            // monitors) so blasted-out nodes stay in view instead of escaping forever.
            let b = ctx.bounds, m: CGFloat = 6, e: CGFloat = 0.85
            if motes[i].pos.x < b.minX + m { motes[i].pos.x = b.minX + m; motes[i].vel.x = abs(motes[i].vel.x) * e }
            else if motes[i].pos.x > b.maxX - m { motes[i].pos.x = b.maxX - m; motes[i].vel.x = -abs(motes[i].vel.x) * e }
            if motes[i].pos.y < b.minY + m { motes[i].pos.y = b.minY + m; motes[i].vel.y = abs(motes[i].vel.y) * e }
            else if motes[i].pos.y > b.maxY - m { motes[i].pos.y = b.maxY - m; motes[i].vel.y = -abs(motes[i].vel.y) * e }
        }
        capturedCount = cap
    }

    func liveCount() -> Int { motes.count + 1 }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let c = CGPoint(x: hole.x - origin.x, y: hole.y - origin.y)
        let er = eventR

        // 1) Free, infalling motes (behind the hole), brighter + streaked near the center.
        for m in motes where !m.captured {
            let dx = hole.x - m.pos.x, dy = hole.y - m.pos.y
            let dist = sqrt(dx * dx + dy * dy)
            let near = max(0, 1 - dist / (er * 6))
            let r = m.size * (1 + near)
            let mx = m.pos.x - origin.x, my = m.pos.y - origin.y
            if near > 0.25 {
                ctx.setAlpha(1)   // the previous mote's glow alpha would otherwise dim this streak
                ctx.setBlendMode(.plusLighter); ctx.setStrokeColor(Self.swatches[m.color % 3].withAlphaComponent(0.5 * near).cgColor)
                ctx.setLineWidth(r); ctx.setLineCap(.round)
                ctx.beginPath(); ctx.move(to: CGPoint(x: mx, y: my)); ctx.addLine(to: CGPoint(x: mx + dx * 0.18, y: my + dy * 0.18)); ctx.strokePath()
            }
            ctx.setBlendMode(.normal); ctx.setAlpha(0.85)
            ctx.draw(Self.cores[m.color % Self.cores.count], in: CGRect(x: mx - r, y: my - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.5 + 0.4 * near)
            let gr = r * 1.5
            ctx.draw(Self.glows[m.color % Self.glows.count], in: CGRect(x: mx - gr, y: my - gr, width: gr * 2, height: gr * 2))
        }
        ctx.setAlpha(1)

        // 2) Outward shockwave rings (keypress burst).
        for b in pulses {
            let t = CGFloat((nowCache - b) / 1.6)
            let rr = er + t * 520, a = (1 - t) * 0.55
            ctx.setBlendMode(.plusLighter); ctx.setStrokeColor(NSColor(srgbRed: 0.8, green: 0.85, blue: 1, alpha: a).cgColor)
            ctx.setLineWidth(3 * (1 - t) + 1); ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }

        // 3) The hole.
        let flare = 0.7 + min(0.35, (boost - 1) * 0.01)
        ctx.setBlendMode(.plusLighter)
        if let g = Self.lensing { ctx.drawRadialGradient(g, startCenter: c, startRadius: er, endCenter: c, endRadius: er * 5, options: []) }
        ctx.setAlpha(flare)
        if let g = Self.accretion { ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: er * 2.5, options: []) }
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal); ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - er, y: c.y - er, width: er * 2, height: er * 2))
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor(NSColor(srgbRed: 1, green: 0.9, blue: 0.75, alpha: 0.95).cgColor); ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - er * 1.04, y: c.y - er * 1.04, width: er * 2.08, height: er * 2.08))

        // 4) Captured core — the trapped nodes glow as a churning nucleus ON TOP of the hole.
        for m in motes where m.captured {
            let mx = m.pos.x - origin.x, my = m.pos.y - origin.y
            let gr = m.size * 1.8
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.9)
            ctx.draw(Self.glows[m.color % Self.glows.count], in: CGRect(x: mx - gr, y: my - gr, width: gr * 2, height: gr * 2))
            ctx.setAlpha(0.7)
            let r = m.size * 0.7
            ctx.draw(Self.cores[m.color % Self.cores.count], in: CGRect(x: mx - r, y: my - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal); ctx.setAlpha(1)
    }
}
