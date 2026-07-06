import AppKit

// FIREWORKS: keys = spark fountains, the cursor is a SPARKLER (a burning wand tip of
// tiny flickering embers), and the mouse button is the SHOT: tap for a shell, HOLD TO
// CHARGE — the muzzle orb at the cursor swells and crackles as energy builds, and
// release fires a round whose size matches the charge, up to a double-ring monster.
// Six shell types keep the sky varied: peony, ring, willow, palm, crossette (splits
// mid-air into a volley of mini-bursts), and strobe. All sparks flicker and shrink
// as they burn out. bg = twinkling night sky over a deeper dusk veil.
final class FireworksScene: Scene {
    let name = "Fireworks"
    let category = SceneCategory.live
    let reactivity = Reactivity.energetic
    let skin = CursorSkin.comet
    let veil: CGFloat = 0.35          // a deeper dusk for firework contrast; desktop still visible
    var draining = false

    static let palette = Palette(
        [(1, 0.85, 0.4), (1, 0.55, 0.2), (1, 0.3, 0.35), (0.4, 0.7, 1),
         (0.7, 0.4, 1), (0.4, 1, 0.6), (1, 1, 0.9), (1, 0.45, 0.7)])
    private var pool = ParticlePool(cap: 2200, quotas: [.keys: 600, .clicks: 1500, .move: 340])
    private var rng = RNG(seed: 0xF14E)

    private enum ShellKind: CaseIterable { case peony, ring, willow, palm, crossette, strobe }
    private struct Shell {
        var pos: NSPoint; var vel: NSPoint
        var detonateAt: TimeInterval
        var color: UInt8
        var kind: ShellKind
        var power: CGFloat          // 0 tap … 1 fully charged
        var mini: Bool = false      // crossette fragment
    }
    private var shells = [Shell]()

    private struct Star { var x: CGFloat; var y: CGFloat; var base: CGFloat; var phase: CGFloat; var speed: CGFloat }
    private var stars = [Star]()
    private var lastBg = CGRect.zero

    private var smokeAnchor: NSPoint?
    private var lastBoom: TimeInterval = 0

    // Charge state: button down = charging; release fires with the built-up power.
    private var charging = false
    private var chargeStart: TimeInterval = 0
    private var chargeLevel: CGFloat = 0
    // A press+release completing INSIDE one frame is invisible to the sampled
    // leftButtonDown edge — the .click event records it so no tap ever fires nothing.
    private var tapPending: NSPoint?

    var audioSwell: CGFloat { chargeLevel * 0.3 }

    func reset() {
        pool.reset(); shells.removeAll(keepingCapacity: true)
        smokeAnchor = nil
        charging = false; chargeLevel = 0; tapPending = nil
        draining = false
    }

    private func buildStars(_ bounds: CGRect) {
        guard bounds != lastBg else { return }
        lastBg = bounds
        stars.removeAll(keepingCapacity: true)
        var r = RNG(seed: 0x57A45)
        // Absolute union-bounds coords: on multi-display setups the union origin is
        // not (0,0), and 0-based stars all slid into one corner.
        for _ in 0..<140 {
            stars.append(Star(x: r.range(bounds.minX, bounds.maxX),
                              y: r.range(bounds.minY + bounds.height * 0.25, bounds.maxY),
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
                                    size: rng.range(2, 4), gravity: 900, drag: 0.8,
                                    color: color, channel: UInt8(Channel.keys.rawValue),
                                    additive: true, flicker: true))
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            tapPending = pt   // consumed in update(): either the hold takes over, or
                              // a sub-frame tap fires a minimum-power shell
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String {
        if case let .key(s) = e.kind { return s }; return " "
    }

    private func launchShell(from p: NSPoint, power: CGFloat, _ ctx: EffectContext) {
        guard shells.count < 16 else { return }
        let kind = ShellKind.allCases[rng.int(ShellKind.allCases.count)]
        let rise = 620 + power * 260
        shells.append(Shell(pos: p, vel: NSPoint(x: rng.range(-40, 40), y: rng.range(rise, rise + 180)),
                            detonateAt: ctx.now + Double(rng.range(0.55, 0.9)),
                            color: UInt8(rng.int(Self.palette.colors.count)),
                            kind: kind, power: power))
        ctx.audio?.whoosh()
    }

    func update(_ ctx: EffectContext) {
        buildStars(ctx.bounds)
        let dt = ctx.dt

        // Charge/fire: hold builds power (the muzzle orb swells), release SHOOTS.
        if ctx.leftButtonDown && !draining {
            if !charging { charging = true; chargeStart = ctx.now }
            tapPending = nil   // the hold owns this press now
            chargeLevel = min(1, CGFloat((ctx.now - chargeStart) / 1.2))
            // Crackle off the muzzle while charging.
            if rng.unit() < dt * (6 + 30 * chargeLevel) {
                let ang = rng.range(0, 2 * .pi)
                pool.spawn(Particle(pos: ctx.cursor,
                                    vel: NSPoint(x: cos(ang) * rng.range(40, 140), y: sin(ang) * rng.range(40, 140) + 40),
                                    birth: ctx.now, life: Double(rng.range(0.25, 0.5)),
                                    size: rng.range(1.5, 2.8), gravity: 300, drag: 1.2,
                                    color: 6, channel: UInt8(Channel.move.rawValue),
                                    additive: true, flicker: true))
            }
        } else if charging {
            charging = false
            if !draining { launchShell(from: ctx.cursor, power: chargeLevel, ctx) }
            chargeLevel = 0
        } else if let pt = tapPending {
            // The press and release both happened between frames: still a shot.
            tapPending = nil
            if !draining { launchShell(from: pt, power: 0, ctx) }
        }

        // Shells rise; detonate at apex or fuse.
        var i = 0
        while i < shells.count {
            shells[i].vel.y -= 900 * dt
            shells[i].pos = shells[i].pos + shells[i].vel * dt
            // rising trail
            pool.spawn(Particle(pos: shells[i].pos, vel: .zero, birth: ctx.now, life: 0.25,
                                size: shells[i].mini ? 1.4 : 2.2, gravity: 0, drag: 1, color: 6,
                                channel: UInt8(Channel.clicks.rawValue), additive: true))
            // Minis detonate on their FUSE only: ~37% of crossette fragments launch
            // with vel.y <= 20 and the apex test popped them the same frame they
            // spawned, collapsing the volley into one clumped flash.
            if ctx.now >= shells[i].detonateAt || (!shells[i].mini && shells[i].vel.y <= 20) {
                detonate(shells[i], ctx); shells.remove(at: i)
            } else { i += 1 }
        }

        // The sparkler: the moving cursor is a burning wand tip — tiny, dense,
        // flickering white-gold embers with a little fall, never grey smoke.
        if let anchor = smokeAnchor {
            var d = sqrt(hypot2(ctx.cursor - anchor))
            var from = anchor
            while d > 7, !draining {
                let step = (ctx.cursor - from)
                let len = sqrt(hypot2(step))
                guard len > 0.001 else { break }
                from = from + step * (7 / len)
                pool.spawn(Particle(pos: from,
                                    vel: NSPoint(x: rng.range(-70, 70), y: rng.range(-30, 90)),
                                    birth: ctx.now, life: Double(rng.range(0.25, 0.6)),
                                    size: rng.range(1.5, 3), gravity: 260, drag: 1.0,
                                    color: rng.unit() < 0.6 ? 6 : 0,
                                    channel: UInt8(Channel.move.rawValue),
                                    additive: true, flicker: true))
                d -= 7
            }
        }
        smokeAnchor = ctx.cursor

        pool.step(dt: dt, now: ctx.now)
    }

    // MARK: Shell chemistry — six kinds, each with its own physics signature.

    private func detonate(_ shell: Shell, _ ctx: EffectContext) {
        // A crossette fragment pops as one small peony — and never re-splits.
        if shell.mini {
            burstRing(shell.pos, n: 22, spd: 160...260, life: 0.5...0.9,
                      size: 2.5...4, gravity: 300, drag: 0.6, color: shell.color, jitter: 0.5)
            if ctx.now - lastBoom > 0.06 { ctx.audio?.boom(intensity: 0.3); lastBoom = ctx.now }
            return
        }
        let boost = 1 + shell.power * 1.4          // charged rounds are monsters
        switch shell.kind {
        case .peony:
            burstRing(shell.pos, n: Int((60 + 80 * ctx.intensity) * boost),
                      spd: 260...440, life: 0.8...1.4, size: 3...5,
                      gravity: 320, drag: 0.6, color: shell.color, jitter: 0.6)
        case .ring:
            // A crisp expanding circle: narrow speed band, no jitter.
            burstRing(shell.pos, n: Int(90 * boost), spd: 360...395, life: 1.0...1.3,
                      size: 3...4.5, gravity: 240, drag: 0.5, color: shell.color, jitter: 0.02)
        case .willow:
            // Long-lived golden strands that droop like the tree.
            burstRing(shell.pos, n: Int(55 * boost), spd: 170...280, life: 1.9...2.6,
                      size: 3.5...5, gravity: 480, drag: 0.35, color: 0, jitter: 0.4)
        case .palm:
            // A few thick rising arms + a soft fill.
            burstRing(shell.pos, n: Int(11 * boost), spd: 330...430, life: 1.2...1.6,
                      size: 6.5...9, gravity: 380, drag: 0.5, color: 1, jitter: 0.1)
            burstRing(shell.pos, n: Int(26 * boost), spd: 110...210, life: 0.8...1.2,
                      size: 3...4.5, gravity: 300, drag: 0.7, color: 1, jitter: 0.8)
        case .crossette:
            // Split into a volley of mini-shells that pop on their own fuses,
            // bounded by a total-shells budget so stacked crossettes can't crowd
            // out the player's own shots.
            for _ in 0..<max(0, min(Int(9 * boost), 32 - shells.count)) {
                let ang = rng.range(0, 2 * .pi)
                let spd = rng.range(190, 300)
                shells.append(Shell(pos: shell.pos,
                                    vel: NSPoint(x: cos(ang) * spd, y: sin(ang) * spd + 120),
                                    detonateAt: ctx.now + Double(rng.range(0.3, 0.55)),
                                    color: UInt8(rng.int(Self.palette.colors.count)),
                                    kind: .crossette, power: 0, mini: true))
            }
        case .strobe:
            // A hanging cloud of white strobes: quick stop, long twinkle.
            burstRing(shell.pos, n: Int(55 * boost), spd: 190...340, life: 1.4...2.0,
                      size: 3...4.5, gravity: 140, drag: 1.3, color: 6, jitter: 0.9)
        }
        // Charged rounds fire a second, faster wave for the double-ring look.
        if shell.power > 0.55, shell.kind != .crossette {
            burstRing(shell.pos, n: Int(70 * shell.power), spd: 480...600, life: 0.7...1.1,
                      size: 3...4.5, gravity: 300, drag: 0.65,
                      color: UInt8(rng.int(Self.palette.colors.count)), jitter: 0.15)
        }
        if ctx.now - lastBoom > 0.06 {
            ctx.audio?.boom(intensity: shell.mini ? 0.3 : min(1, ctx.intensity + shell.power))
            lastBoom = ctx.now
        }
    }

    private func burstRing(_ pos: NSPoint, n: Int, spd: ClosedRange<CGFloat>, life: ClosedRange<Double>,
                           size: ClosedRange<CGFloat>, gravity: CGFloat, drag: CGFloat,
                           color: UInt8, jitter: CGFloat) {
        for k in 0..<n {
            let ang = CGFloat(k) * (2 * .pi / CGFloat(max(1, n))) + rng.range(-jitter, jitter)
            let s = rng.range(spd.lowerBound, spd.upperBound)
            pool.spawn(Particle(pos: pos,
                                vel: NSPoint(x: cos(ang) * s, y: sin(ang) * s),
                                birth: CACurrentMediaTime(), life: Double(rng.range(CGFloat(life.lowerBound), CGFloat(life.upperBound))),
                                size: rng.range(size.lowerBound, size.upperBound),
                                gravity: gravity, drag: drag,
                                color: color, channel: UInt8(Channel.clicks.rawValue),
                                additive: true, flicker: true))
        }
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
        // Shells.
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1).cgColor)
        for s in shells {
            let r: CGFloat = s.mini ? 1.6 : 2
            ctx.fillEllipse(in: CGRect(x: s.pos.x - origin.x - r, y: s.pos.y - origin.y - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal)
        // Particles.
        pool.draw(into: ctx, origin: origin, palette: Self.palette, now: now)

        // The charging muzzle: a swelling golden orb crackling at the cursor.
        if chargeLevel > 0.02 {
            let cx = smokeAnchor.map { $0.x - origin.x } ?? 0
            let cy = smokeAnchor.map { $0.y - origin.y } ?? 0
            let pulse = 1 + 0.08 * CGFloat(sin(now * 18))
            let r = (6 + 22 * chargeLevel) * pulse
            ctx.setBlendMode(.plusLighter)
            ctx.setFillColor(NSColor(srgbRed: 1, green: 0.8, blue: 0.35, alpha: 0.55).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r * 1.7, y: cy - r * 1.7, width: r * 3.4, height: r * 3.4))
            ctx.setFillColor(NSColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.normal)
        }
    }
}
