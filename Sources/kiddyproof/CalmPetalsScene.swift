import AppKit

// PETALS — calm blossoms drifting slowly down with a gentle side-to-side sway and slow
// tumble. A keypress releases a petal; a click is a soft gust that nudges nearby petals
// outward. Petals are colored ellipses with a dark edge so they read on light AND dark
// wallpaper. No veil.
final class CalmPetalsScene: Scene {
    let name = "Petals"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Petal {
        var pos: NSPoint; var gust: NSPoint
        var angle: CGFloat; var angVel: CGFloat; var size: CGFloat
        var color: Int; var phase: CGFloat; var swaySpeed: CGFloat; var fall: CGFloat
    }
    private var petals: [Petal] = []
    private let ambientCount = 42
    private let maxPetals = 80
    private var rng = RNG(seed: 0x9E7A15)
    private var seededSize = CGSize.zero

    private static let colors: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.72, blue: 0.82, alpha: 1),   // blossom pink
        NSColor(srgbRed: 0.98, green: 0.94, blue: 0.96, alpha: 1),  // near white
        NSColor(srgbRed: 1.0, green: 0.85, blue: 0.72, alpha: 1),   // peach
        NSColor(srgbRed: 0.86, green: 0.82, blue: 1.0, alpha: 1),   // lavender
    ]
    // Soft brush dabs + a dark bleed backing so the petals read on any wallpaper without
    // the old hard black edge.
    private static let inkStamps: [CGImage] = colors.map { inkSprite($0) }
    private static let inkDark = inkSprite(NSColor(white: 0, alpha: 1))

    func reset() { petals.removeAll(keepingCapacity: true); seededSize = .zero; draining = false }

    private func newPetal(_ bounds: CGRect, atTop: Bool, at: NSPoint? = nil) -> Petal {
        let p = at ?? NSPoint(x: rng.range(bounds.minX, bounds.maxX),
                              y: atTop ? bounds.maxY + rng.range(10, 80) : rng.range(bounds.minY, bounds.maxY))
        return Petal(pos: p, gust: .zero, angle: rng.range(0, 6.28), angVel: rng.range(-1.2, 1.2),
                     size: rng.range(14, 26), color: rng.int(Self.colors.count),
                     phase: rng.range(0, 6.28), swaySpeed: rng.range(0.5, 1.1), fall: rng.range(32, 60))
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard bounds.size != seededSize else { return }
        seededSize = bounds.size
        petals.removeAll(keepingCapacity: true)
        for _ in 0..<ambientCount { petals.append(newPetal(bounds, atTop: false)) }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            if petals.count < maxPetals {
                var pt = newPetal(ctx.bounds, atTop: false, at: ctx.cursor)
                pt.gust = NSPoint(x: rng.range(-40, 40), y: rng.range(30, 80))   // gentle puff up
                petals.append(pt)
            }
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            for i in petals.indices {
                let d = petals[i].pos - pt
                let dist = sqrt(hypot2(d))
                if dist < 190, dist > 1 {
                    let f = (1 - dist / 190) * 140
                    petals[i].gust.x += d.x / dist * f
                    petals[i].gust.y += d.y / dist * f + 40
                    petals[i].angVel += rng.range(-2, 2)
                }
            }
            ctx.audio?.whoosh()
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        let dt = ctx.dt
        let now = ctx.now
        for i in petals.indices {
            petals[i].gust.x *= exp(-2.2 * dt); petals[i].gust.y *= exp(-2.2 * dt)
            let vx = CGFloat(sin(now * Double(petals[i].swaySpeed) + Double(petals[i].phase))) * 26 + petals[i].gust.x
            let vy = -petals[i].fall + petals[i].gust.y
            petals[i].pos.x += vx * dt
            petals[i].pos.y += vy * dt
            petals[i].angle += petals[i].angVel * dt
            // recycle to the top once below the screen
            if petals[i].pos.y < ctx.bounds.minY - 40 {
                petals[i] = newPetal(ctx.bounds, atTop: true)
            }
            if petals[i].pos.x < ctx.bounds.minX - 40 { petals[i].pos.x = ctx.bounds.maxX + 40 }
            if petals[i].pos.x > ctx.bounds.maxX + 40 { petals[i].pos.x = ctx.bounds.minX - 40 }
        }
    }

    func liveCount() -> Int { petals.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        ctx.setBlendMode(.normal)
        for p in petals {
            // A soft brush dab: a round ink stamp squashed into a petal and rotated, with a
            // slightly larger dark stamp behind for a soft edge that reads on light bg. The
            // dab is nudged toward the tip so it reads as a teardrop, not a plain ellipse.
            let w = p.size * 1.25, h = p.size * 0.7
            ctx.saveGState()
            ctx.translateBy(x: p.pos.x - origin.x, y: p.pos.y - origin.y)
            ctx.rotate(by: p.angle)
            ctx.setAlpha(0.28)
            ctx.draw(Self.inkDark, in: CGRect(x: -w * 0.6, y: -h * 0.62, width: w * 1.2, height: h * 1.24))
            ctx.setAlpha(0.9)
            ctx.draw(Self.inkStamps[p.color % Self.inkStamps.count], in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            ctx.setAlpha(0.6)                                     // tip highlight → teardrop
            let tw = w * 0.5
            ctx.draw(Self.inkStamps[p.color % Self.inkStamps.count], in: CGRect(x: w * 0.18 - tw / 2, y: -h * 0.4, width: tw, height: h * 0.8))
            ctx.restoreGState()
        }
        ctx.setAlpha(1)
    }
}
