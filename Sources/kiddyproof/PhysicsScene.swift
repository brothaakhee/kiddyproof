import AppKit

// PHYSICS PLAYGROUND: keys=falling letters that stack, clicks=bouncy balls that
// collide, move=cursor gravity attractor. One shared world so mixed body types
// collide consistently. Stability comes from: semi-implicit (symplectic) Euler,
// fixed 1/120 timestep with ≤4 substeps, spatial-hash broadphase (O(n)),
// Plummer-softened attractor (no NaN), and a global speed clamp (no tunneling).
final class PhysicsScene: Scene {
    let name = "Physics Playground"
    let category = SceneCategory.energetic
    let reactivity = Reactivity.energetic
    let skin = CursorSkin.blackHole
    let veil: CGFloat = 0.3           // dusk; the parent's real screen stays visible behind the bodies
    var draining = false

    static let palette = Palette(
        [(1, 0.4, 0.4), (1, 0.75, 0.3), (1, 0.95, 0.45), (0.45, 0.85, 0.5),
         (0.4, 0.7, 1), (0.6, 0.5, 1), (1, 0.6, 0.85), (0.95, 0.95, 1)])

    struct Body {
        var pos: NSPoint; var vel: NSPoint
        var radius: CGFloat; var invMass: CGFloat; var restitution: CGFloat
        var color: UInt8; var channel: UInt8
        var ch: Character?       // letter glyph; nil = ball
        var angle: CGFloat; var angVel: CGFloat
    }

    private var bodies = [Body]()
    private let maxBodies = 380
    private var letterCount = 0, ballCount = 0
    private let letterCap = 160, ballCap = 240

    private let gravity: CGFloat = 1500
    private let vMax: CGFloat = 2600
    private let h: CGFloat = 1.0 / 120.0
    private var accumulator: CGFloat = 0
    private var rng = RNG(seed: 0xB0D1E5)

    // spatial hash scratch, reused
    private var grid = [Int: [Int]]()
    private var collisionsThisFrame = 0

    func reset() {
        bodies.removeAll(keepingCapacity: true)
        grid.removeAll(keepingCapacity: true)
        letterCount = 0; ballCount = 0; accumulator = 0; draining = false
    }

    // At the caps the world RECYCLES (oldest body of that kind vanishes to make room)
    // instead of going dead: a mashing toddler fills the letter cap in seconds, and a
    // scene that stops responding — no visual, no sound — reads as broken.
    private func recycleOldest(letter: Bool) {
        if let i = bodies.firstIndex(where: { ($0.ch != nil) == letter }) {
            bodies.remove(at: i)
            if letter { letterCount -= 1 } else { ballCount -= 1 }
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key(let s):
            let ch = s.first ?? "?"
            guard !ch.isWhitespace else { return }
            if letterCount >= letterCap || bodies.count >= maxBodies { recycleOldest(letter: true) }
            guard letterCount < letterCap, bodies.count < maxBodies else { return }
            bodies.append(Body(pos: NSPoint(x: ctx.cursor.x + rng.range(-30, 30), y: ctx.bounds.maxY - 40),
                               vel: NSPoint(x: rng.range(-40, 40), y: rng.range(-60, 0)),
                               radius: 26, invMass: 1.0 / 1.4, restitution: 0.15,
                               color: UInt8(rng.int(Self.palette.colors.count)),
                               channel: UInt8(Channel.keys.rawValue), ch: ch,
                               angle: rng.range(-0.4, 0.4), angVel: rng.range(-3, 3)))
            letterCount += 1
            ctx.audio?.note(for: s, intensity: ctx.intensity)
        case .click(let pt, let button):
            guard button == .left else { return }
            if ballCount >= ballCap || bodies.count >= maxBodies { recycleOldest(letter: false) }
            guard ballCount < ballCap, bodies.count < maxBodies else { return }
            let r = rng.range(18, 30)
            bodies.append(Body(pos: pt, vel: NSPoint(x: rng.range(-260, 260), y: rng.range(-100, 320)),
                               radius: r, invMass: 1.0 / Double(r * 0.12), restitution: 0.72,
                               color: UInt8(rng.int(Self.palette.colors.count)),
                               channel: UInt8(Channel.clicks.rawValue), ch: nil,
                               angle: 0, angVel: 0))
            ballCount += 1
            ctx.audio?.bonk(intensity: ctx.intensity)
        case .scroll:
            break
        }
    }

    func update(_ ctx: EffectContext) {
        collisionsThisFrame = 0
        accumulator += ctx.dt
        var sub = 0
        while accumulator >= h && sub < 4 {
            substep(h, ctx)
            accumulator -= h
            sub += 1
        }
        if sub == 4 { accumulator = 0 }     // drop backlog (spiral-of-death guard)
    }

    private func substep(_ h: CGFloat, _ ctx: EffectContext) {
        let floorY = ctx.bounds.minY + 4
        let minX = ctx.bounds.minX, maxX = ctx.bounds.maxX
        // attractor strength scales with intensity; modest so letters still stack.
        let G: CGFloat = 1.2e6 * (0.3 + 0.7 * ctx.intensity)
        let eps2: CGFloat = 64 * 64

        // integrate
        for i in bodies.indices {
            var v = bodies[i].vel
            v.y -= gravity * h
            let d = ctx.cursor - bodies[i].pos
            let r2 = hypot2(d) + eps2
            let f = G / (r2 * sqrt(r2))           // Plummer-softened, bounded
            v.x += d.x * f * h
            v.y += d.y * f * h
            let sp2 = hypot2(v)
            if sp2 > vMax * vMax { let s = vMax / sqrt(sp2); v.x *= s; v.y *= s }
            bodies[i].vel = v
            bodies[i].pos = bodies[i].pos + v * h
            bodies[i].angle += bodies[i].angVel * h
            bodies[i].angVel *= exp(-0.8 * h)
        }

        collide()

        // floor + walls
        for i in bodies.indices {
            let r = bodies[i].radius
            if bodies[i].pos.y - r < floorY {
                bodies[i].pos.y = floorY + r
                if bodies[i].vel.y < 0 { bodies[i].vel.y = -bodies[i].vel.y * bodies[i].restitution }
                bodies[i].vel.x *= 0.86       // floor friction
                bodies[i].angVel *= 0.7
            }
            if bodies[i].pos.x - r < minX { bodies[i].pos.x = minX + r; bodies[i].vel.x = abs(bodies[i].vel.x) * bodies[i].restitution }
            if bodies[i].pos.x + r > maxX { bodies[i].pos.x = maxX - r; bodies[i].vel.x = -abs(bodies[i].vel.x) * bodies[i].restitution }
        }
    }

    private func collide() {
        guard bodies.count > 1 else { return }
        let cell: CGFloat = 110
        // Shed stale cells instead of keeping every key ever visited alive (and
        // rewriting each with a fresh empty array) — thousands of dictionary writes
        // per frame otherwise.
        grid.removeAll(keepingCapacity: true)
        @inline(__always) func key(_ p: NSPoint) -> Int {
            let cx = Int(floor(p.x / cell)), cy = Int(floor(p.y / cell))
            return cx &* 73856093 ^ cy &* 19349663
        }
        for i in bodies.indices { grid[key(bodies[i].pos), default: []].append(i) }

        for i in bodies.indices {
            let cx = Int(floor(bodies[i].pos.x / cell)), cy = Int(floor(bodies[i].pos.y / cell))
            for ox in -1...1 { for oy in -1...1 {
                let k = (cx + ox) &* 73856093 ^ (cy + oy) &* 19349663
                guard let bucket = grid[k] else { continue }
                for j in bucket where j > i {
                    resolve(i, j)
                }
            }}
        }
    }

    private func resolve(_ i: Int, _ j: Int) {
        let n = bodies[j].pos - bodies[i].pos
        let dist2 = hypot2(n)
        let rsum = bodies[i].radius + bodies[j].radius
        guard dist2 < rsum * rsum, dist2 > 0.0001 else { return }
        let dist = sqrt(dist2)
        let nx = n.x / dist, ny = n.y / dist
        let pen = rsum - dist
        let imA = bodies[i].invMass, imB = bodies[j].invMass
        let imSum = imA + imB
        guard imSum > 0 else { return }
        // positional correction (slop)
        let corr = max(pen - 0.5, 0) / imSum
        bodies[i].pos.x -= nx * corr * imA; bodies[i].pos.y -= ny * corr * imA
        bodies[j].pos.x += nx * corr * imB; bodies[j].pos.y += ny * corr * imB
        // impulse
        let rvx = bodies[j].vel.x - bodies[i].vel.x, rvy = bodies[j].vel.y - bodies[i].vel.y
        let relN = rvx * nx + rvy * ny
        if relN < 0 {
            let e = min(bodies[i].restitution, bodies[j].restitution)
            let jimp = -(1 + e) * relN / imSum
            bodies[i].vel.x -= nx * jimp * imA; bodies[i].vel.y -= ny * jimp * imA
            bodies[j].vel.x += nx * jimp * imB; bodies[j].vel.y += ny * jimp * imB
            let spin = (rvx * ny - rvy * nx) * 0.01
            bodies[i].angVel -= spin; bodies[j].angVel += spin
            collisionsThisFrame += 1
        }
    }

    func liveCount() -> Int { bodies.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        // Effects only — the dusk veil + real screen are behind us.
        ctx.setBlendMode(.normal)
        // floor line
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(2)
        ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 6)); ctx.addLine(to: CGPoint(x: bounds.width, y: 6)); ctx.strokePath()
        for b in bodies {
            let c = CGPoint(x: b.pos.x - origin.x, y: b.pos.y - origin.y)
            let color = Self.palette.colors[Int(b.color) % Self.palette.colors.count]
            if let ch = b.ch {
                drawGlyph(ch, at: c, radius: b.radius, angle: b.angle, color: color, ctx: ctx)
            } else {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: c.x - b.radius, y: c.y - b.radius, width: b.radius * 2, height: b.radius * 2))
                ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - b.radius * 0.4, y: c.y + b.radius * 0.1, width: b.radius * 0.5, height: b.radius * 0.5))
            }
        }
    }

    // --- glyph cache: render each character once into an alpha mask image. ---
    private static var glyphCache = [Character: CGImage]()
    private func drawGlyph(_ ch: Character, at c: CGPoint, radius: CGFloat, angle: CGFloat, color: CGColor, ctx: CGContext) {
        let img = Self.glyph(ch)
        let side = radius * 2.4
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: angle)
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        ctx.clip(to: rect, mask: img)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private static func glyph(_ ch: Character) -> CGImage {
        if let img = glyphCache[ch] { return img }
        let px = 96
        let cs = CGColorSpaceCreateDeviceGray()
        let bm = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px,
                           space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        bm.setFillColor(CGColor(gray: 0, alpha: 1)); bm.fill(CGRect(x: 0, y: 0, width: px, height: px))
        let s = String(ch).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 78, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let astr = NSAttributedString(string: s, attributes: attrs)
        let size = astr.size()
        let ns = NSGraphicsContext(cgContext: bm, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        astr.draw(at: NSPoint(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let img = bm.makeImage()!
        glyphCache[ch] = img
        return img
    }
}
