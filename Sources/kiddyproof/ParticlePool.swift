import AppKit

// A POD particle. No references → no ARC, lives in a contiguous array.
struct Particle {
    var pos: NSPoint
    var vel: NSPoint
    var birth: TimeInterval
    var life: TimeInterval        // total lifespan in seconds
    var size: CGFloat             // radius at birth
    var gravity: CGFloat          // downward accel (applied to vy), px/s²
    var drag: CGFloat             // exponential per-second velocity drag coefficient
    var color: UInt8              // index into the active palette
    var channel: UInt8            // Channel.rawValue, for per-channel quotas
    var additive: Bool            // plusLighter (glowy) vs normal
    var flicker: Bool = false     // strobe the alpha like a burning spark
}

// Fixed-capacity dense particle pool shared by all of a scene's channels.
//  - spawn() respects a global cap AND per-channel quotas so one channel can't
//    starve the others (the adversarial fix for "balls eat the letter budget").
//  - step() integrates with symplectic Euler + exponential drag, reaps via
//    swap-remove (O(n), zero allocation).
//  - draw() batches by (color, additive, quantized alpha) → a handful of
//    fillPath calls regardless of particle count (avoids the per-particle
//    gradient/scale slow path the design flagged as fatal).
final class ParticlePool {
    private(set) var items: [Particle]
    private(set) var count = 0
    let cap: Int
    private let quotas: [Int]
    private var perChannel: [Int]

    init(cap: Int, quotas: [Channel: Int]) {
        self.cap = cap
        items = [Particle](repeating: Self.dead, count: cap)
        var q = [Int](repeating: cap, count: Channel.allCases.count)
        for (c, v) in quotas { q[c.rawValue] = v }
        self.quotas = q
        perChannel = [Int](repeating: 0, count: Channel.allCases.count)
    }

    private static let dead = Particle(pos: .zero, vel: .zero, birth: 0, life: 0, size: 0,
                                       gravity: 0, drag: 0, color: 0, channel: 0, additive: false)

    func reset() {
        count = 0
        for i in perChannel.indices { perChannel[i] = 0 }
    }

    @discardableResult
    func spawn(_ p: Particle) -> Bool {
        let ch = Int(p.channel)
        if count >= cap || perChannel[ch] >= quotas[ch] { return false }
        items[count] = p
        count += 1
        perChannel[ch] += 1
        return true
    }

    func step(dt: CGFloat, now: TimeInterval) {
        var i = 0
        while i < count {
            if now - items[i].birth >= items[i].life {
                // swap-remove
                perChannel[Int(items[i].channel)] -= 1
                count -= 1
                if i != count { items[i] = items[count] }
                continue
            }
            // symplectic Euler: velocity first, then position.
            items[i].vel.y -= items[i].gravity * dt
            let d = exp(-items[i].drag * dt)
            items[i].vel.x *= d
            items[i].vel.y *= d
            items[i].pos.x += items[i].vel.x * dt
            items[i].pos.y += items[i].vel.y * dt
            i += 1
        }
    }

    // Batched draw. `paths` keyed by bucket = color*16 + alphaQ*2 + additive.
    func draw(into ctx: CGContext, origin: CGPoint, palette: Palette, now: TimeInterval) {
        guard count > 0 else { return }
        var paths = [Int: CGMutablePath]()
        paths.reserveCapacity(64)
        for i in 0..<count {
            let p = items[i]
            var frac = max(0, 1 - CGFloat((now - p.birth) / p.life))     // 1→0 over life
            if p.flicker {
                // Burning-spark strobe, phase-keyed off birth so each spark twinkles
                // on its own clock.
                frac *= 0.55 + 0.45 * CGFloat(sin(now * 21 + p.birth * 977))
            }
            let alphaQ = min(7, Int(max(0, frac) * 7.999))
            let r = p.size * (0.35 + 0.65 * frac)                        // shrink as it dies
            if r < 0.4 { continue }
            let key = Int(p.color) * 16 + alphaQ * 2 + (p.additive ? 1 : 0)
            let path = paths[key] ?? { let m = CGMutablePath(); paths[key] = m; return m }()
            let x = p.pos.x - origin.x, y = p.pos.y - origin.y
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for (key, path) in paths {
            let color = Int(key / 16)
            let alphaQ = (key % 16) / 2
            let additive = (key % 2) == 1
            ctx.setBlendMode(additive ? .plusLighter : .normal)
            let a = CGFloat(alphaQ + 1) / 8.0
            ctx.setFillColor(palette.colors[color % palette.colors.count].copy(alpha: a)!)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
    }
}
