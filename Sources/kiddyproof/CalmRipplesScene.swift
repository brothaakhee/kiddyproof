import AppKit

// RIPPLES — calm concentric waves spreading like raindrops on a still pond. A gentle
// ambient "rain" drops occasional ripples; the cursor leaves a soft wake as it moves;
// a keypress drops a ripple; a click sends a larger double ring. Rings use the contrast
// stroke so they read on light AND dark wallpaper. No veil.
final class CalmRipplesScene: Scene {
    let name = "Ripples"
    let category = SceneCategory.archived
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Ripple { let center: NSPoint; let birth: TimeInterval; let life: Double; let maxR: CGFloat; let color: Int; let width: CGFloat; let seed: CGFloat }
    private var ripples: [Ripple] = []
    private let maxRipples = 60
    private var rng = RNG(seed: 0x21FF1E)
    private var ambientAccum: Double = 0
    private var lastWake = NSPoint.zero

    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.78, green: 0.90, blue: 1.0, alpha: 1),   // ink blue-white
        NSColor(srgbRed: 0.55, green: 0.80, blue: 0.95, alpha: 1),  // pale blue ink
        NSColor(srgbRed: 0.55, green: 0.92, blue: 0.85, alpha: 1),  // teal ink
        NSColor(srgbRed: 0.74, green: 0.74, blue: 0.98, alpha: 1),  // periwinkle ink
    ]
    // Contrast dabs so the bleeding rings read on light AND dark wallpaper.
    private static let stamps: [CGImage] = palette.map { softContrastSprite($0) }

    func reset() { ripples.removeAll(keepingCapacity: true); ambientAccum = 0 }

    private func drop(_ center: NSPoint, _ now: TimeInterval, life: Double, maxR: CGFloat, width: CGFloat, concentric: Bool) {
        guard ripples.count < maxRipples else { return }
        let c = rng.int(Self.palette.count), seed = rng.range(0, 6.28)
        ripples.append(Ripple(center: center, birth: now, life: life, maxR: maxR, color: c, width: width, seed: seed))
        if concentric, ripples.count < maxRipples {
            ripples.append(Ripple(center: center, birth: now + 0.18, life: life, maxR: maxR * 0.62, color: c, width: width * 0.8, seed: seed + 1.7))
        }
    }

    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch event.kind {
        case .key:
            drop(ctx.cursor, ctx.now, life: 1.8, maxR: rng.range(80, 130), width: 1.6, concentric: false)
            ctx.audio?.note(for: keyString(event), intensity: ctx.intensity)
        case .click(let pt, .left):
            drop(pt, ctx.now, life: 2.6, maxR: rng.range(170, 240), width: 2.2, concentric: true)
            ctx.audio?.whoosh()
        default:
            break
        }
    }

    private func keyString(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        let now = ctx.now
        // Gentle ambient rain.
        if !draining {
            ambientAccum += ctx.dt
            let interval = 1.4 - 0.6 * Double(ctx.intensity)   // a touch more rain when busy (still gentle)
            if ambientAccum >= interval {
                ambientAccum = 0
                let p = NSPoint(x: rng.range(ctx.bounds.minX, ctx.bounds.maxX),
                                y: rng.range(ctx.bounds.minY, ctx.bounds.maxY))
                drop(p, now, life: 2.4, maxR: rng.range(110, 190), width: 1.6, concentric: false)
            }
            // Soft cursor wake.
            if sqrt(hypot2(ctx.cursor - lastWake)) > 44 {
                lastWake = ctx.cursor
                drop(ctx.cursor, now, life: 1.4, maxR: rng.range(50, 80), width: 1.2, concentric: false)
            }
        }
        ripples.removeAll { now - $0.birth >= $0.life }
    }

    func liveCount() -> Int { ripples.count }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let now = nowOrZero()
        ctx.setBlendMode(.normal)
        for r in ripples {
            let age = now - r.birth
            guard age >= 0 else { continue }
            let t = CGFloat(age / r.life)
            let radius = r.maxR * (1 - (1 - t) * (1 - t))      // ease-out expansion
            let a = (1 - t) * 0.62
            guard a > 0.02, radius > 1 else { continue }
            // Bleeding ink ring: soft dabs around the circle, thickening as they wobble.
            // The dab grows a touch as the ring expands so it reads as ink diffusing.
            let dab = r.width * 4 + 4 + radius * 0.014
            ctx.setAlpha(a)
            inkRing(ctx, cx: r.center.x - origin.x, cy: r.center.y - origin.y,
                    radius: radius, dab: dab, stamp: Self.stamps[r.color], seed: r.seed,
                    wobble: 0.045 + 0.03 * t)
        }
        ctx.setBlendMode(.normal); ctx.setAlpha(1)
    }

    private func nowOrZero() -> TimeInterval { CACurrentMediaTime() }
}
