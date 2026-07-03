import AppKit

// FIREWORKS scene: keys=spark fountains, clicks=aerial shells that rise & detonate,
// move=smoke/ember trail (distance-gated), bg=night sky. All particles share one
// pool; shells are tracked separately because they detonate into the pool.
final class FireworksScene: Scene {
    let name = "Fireworks"
    let category = SceneCategory.energetic
    let reactivity = Reactivity.energetic
    let skin = CursorSkin.comet
    let veil: CGFloat = 0.35          // a deeper dusk for firework contrast; desktop still visible
    var draining = false

    static let palette = Palette(
        [(1, 0.85, 0.4), (1, 0.55, 0.2), (1, 0.3, 0.35), (0.4, 0.7, 1),
         (0.7, 0.4, 1), (0.4, 1, 0.6), (1, 1, 0.9), (1, 0.45, 0.7)])
    private var pool = ParticlePool(cap: 1800, quotas: [.keys: 600, .clicks: 1200, .move: 400])
    private var rng = RNG(seed: 0xF14E)

    private struct Shell { var pos: NSPoint; var vel: NSPoint; var detonateAt: TimeInterval; var color: UInt8 }
    private var shells = [Shell]()

    private struct Star { var x: CGFloat; var y: CGFloat; var base: CGFloat; var phase: CGFloat; var speed: CGFloat }
    private var stars = [Star]()
    private var lastBg = CGSize.zero

    private var smokeAnchor: NSPoint?
    private var lastBoom: TimeInterval = 0

    func reset() {
        pool.reset(); shells.removeAll(keepingCapacity: true)
        smokeAnchor = nil; draining = false
    }

    private func buildStars(_ size: CGSize) {
        guard size != lastBg else { return }
        lastBg = size
        stars.removeAll(keepingCapacity: true)
        var r = RNG(seed: 0x57A45)
        let n = 140
        for _ in 0..<n {
            stars.append(Star(x: r.range(0, size.width), y: r.range(size.height * 0.25, size.height),
                              base: r.range(0.2, 0.7), phase: r.range(0, 6.28), speed: r.range(0.6, 2.2)))
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            let m = Int(8 + 14 * ctx.intensity)
            let color = UInt8(rng.int(Self.palette.colors.count))
            for _ in 0..<m {
                let ang = rng.range(.pi / 3, 2 * .pi / 3)              // upward cone
                let spd = rng.range(220, 520) * (0.7 + 0.6 * ctx.intensity)
                pool.spawn(Particle(pos: ctx.cursor,
                                    vel: NSPoint(x: cos(ang) * spd, y: sin(ang) * spd),
                                    birth: ctx.now, life: Double(rng.range(0.5, 1.0)),
                                    size: rng.range(2.5, 5), gravity: 900, drag: 0.8,
                                    color: color, channel: UInt8(Channel.keys.rawValue), additive: true))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, let button):
            guard button == .left, shells.count < 14 else { return }
            shells.append(Shell(pos: pt, vel: NSPoint(x: rng.range(-40, 40), y: rng.range(620, 800)),
                                detonateAt: ctx.now + Double(rng.range(0.55, 0.9)),
                                color: UInt8(rng.int(Self.palette.colors.count))))
            ctx.audio?.whoosh()
        case .scroll:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String {
        if case let .key(s) = e.kind { return s }; return " "
    }

    func update(_ ctx: EffectContext) {
        buildStars(ctx.bounds.size)
        let dt = ctx.dt

        // Shells rise; detonate at apex or fuse.
        var i = 0
        while i < shells.count {
            shells[i].vel.y -= 900 * dt
            shells[i].pos = shells[i].pos + shells[i].vel * dt
            // rising trail
            pool.spawn(Particle(pos: shells[i].pos, vel: .zero, birth: ctx.now, life: 0.25,
                                size: 2.2, gravity: 0, drag: 1, color: 6,
                                channel: UInt8(Channel.clicks.rawValue), additive: true))
            if ctx.now >= shells[i].detonateAt || shells[i].vel.y <= 20 {
                detonate(shells[i], ctx); shells.remove(at: i)
            } else { i += 1 }
        }

        // Smoke/ember trail, distance-gated off the cursor.
        if let anchor = smokeAnchor {
            var d = sqrt(hypot2(ctx.cursor - anchor))
            var from = anchor
            while d > 16, !draining {
                let step = (ctx.cursor - from)
                let len = sqrt(hypot2(step))
                guard len > 0.001 else { break }
                from = from + step * (16 / len)
                pool.spawn(Particle(pos: from, vel: NSPoint(x: rng.range(-12, 12), y: rng.range(20, 60)),
                                    birth: ctx.now, life: Double(rng.range(0.7, 1.3)),
                                    size: rng.range(6, 12), gravity: -60, drag: 1.6, color: 6,
                                    channel: UInt8(Channel.move.rawValue), additive: true))
                d -= 16
            }
        }
        smokeAnchor = ctx.cursor

        pool.step(dt: dt, now: ctx.now)
    }

    private func detonate(_ shell: Shell, _ ctx: EffectContext) {
        let n = Int(60 + 80 * ctx.intensity)
        for k in 0..<n {
            let ang = CGFloat(k) * (2 * .pi / CGFloat(n)) + rng.range(-0.1, 0.1)
            let spd = rng.range(220, 360)
            pool.spawn(Particle(pos: shell.pos,
                                vel: NSPoint(x: cos(ang) * spd, y: sin(ang) * spd),
                                birth: ctx.now, life: Double(rng.range(0.8, 1.5)),
                                size: rng.range(2.5, 4.5), gravity: 320, drag: 0.6,
                                color: shell.color, channel: UInt8(Channel.clicks.rawValue), additive: true))
        }
        if ctx.now - lastBoom > 0.06 { ctx.audio?.boom(intensity: ctx.intensity); lastBoom = ctx.now }
    }

    func liveCount() -> Int { pool.count + shells.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        // Effects only — the dusk veil + real screen are behind us. Twinkle stars.
        let now = CACurrentMediaTime()
        ctx.setBlendMode(.plusLighter)
        for s in stars {
            let b = s.base + 0.35 * CGFloat(sin(now * Double(s.speed) + Double(s.phase)))
            guard b > 0.05 else { continue }
            ctx.setFillColor(NSColor(white: 1, alpha: min(1, b)).cgColor)
            ctx.fillEllipse(in: CGRect(x: s.x - origin.x - 1, y: s.y - origin.y - 1, width: 2, height: 2))
        }
        ctx.setBlendMode(.normal)
        // Shells.
        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1).cgColor)
        for s in shells {
            ctx.fillEllipse(in: CGRect(x: s.pos.x - origin.x - 2, y: s.pos.y - origin.y - 2, width: 4, height: 4))
        }
        ctx.setBlendMode(.normal)
        // Particles.
        pool.draw(into: ctx, origin: origin, palette: Self.palette, now: now)
    }
}
