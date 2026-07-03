import AppKit

// SPIDERWEB — a delicate radial web (spokes + rings) that sways gently and deforms under
// the cursor like a fingertip pressing silk. Dew drops catch the light on the threads; a
// click sends a soft ripple traveling outward through the web; a keypress leaves a dew
// sparkle. Threads use the contrast stroke so the web reads on any wallpaper.
final class CalmSpiderwebScene: Scene {
    let name = "Spiderweb"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private let spokes = 16
    private let rings = 8
    private var pulses: [TimeInterval] = []        // ripple birth times (centered at the web origin)
    private var sparkles: [(p: NSPoint, t: TimeInterval)] = []
    private var center = NSPoint.zero
    private var maxR: CGFloat = 1
    private var now: TimeInterval = 0
    private var intensity: CGFloat = 0

    private static let threadCore = NSColor(srgbRed: 0.9, green: 0.94, blue: 1.0, alpha: 1)
    private static let dewCore: CGImage = softContrastSprite(NSColor(srgbRed: 0.85, green: 0.95, blue: 1.0, alpha: 1))
    private static let dewGlow: CGImage = softGlowSprite(NSColor(srgbRed: 0.85, green: 0.95, blue: 1.0, alpha: 1))

    func reset() { pulses.removeAll(); sparkles.removeAll(); draining = false }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key:
            sparkles.append((ctx.cursor, ctx.now)); ctx.audio?.note(for: ks(e), intensity: ctx.intensity)
        case .click(_, .left):
            if pulses.count < 5 { pulses.append(ctx.now) }; ctx.audio?.whoosh()
        default: break
        }
    }
    private func ks(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        now = ctx.now
        intensity = ctx.intensity
        center = NSPoint(x: ctx.bounds.midX, y: ctx.bounds.midY)
        maxR = min(ctx.bounds.width, ctx.bounds.height) * 0.46
        cursor = ctx.cursor
        pulses.removeAll { ctx.now - $0 > 2.2 }
        sparkles.removeAll { ctx.now - $0.t > 1.6 }
    }
    private var cursor = NSPoint.zero

    func liveCount() -> Int { 1 + pulses.count + sparkles.count }   // web is always live

    // Position of web node (spoke s, ring r) with sway + cursor press + ripple displacement.
    private func node(_ s: Int, _ r: Int) -> NSPoint {
        let baseAngle = CGFloat(s) * (2 * .pi / CGFloat(spokes))
        let ringR = CGFloat(r + 1) / CGFloat(rings) * maxR
        let angle = baseAngle + 0.05 * CGFloat(sin(now * 0.5 + Double(s) + Double(r) * 0.3))
        var radius = ringR + 6 * CGFloat(sin(now * 0.7 + Double(r) + Double(s) * 0.2))
        // ripple: a band of outward bulge traveling from the center
        for birth in pulses {
            let front = CGFloat(now - birth) * 360
            let band = ringR - front
            radius += 26 * CGFloat(exp(-(band * band) / (2 * 60 * 60))) * CGFloat(max(0, 1 - (now - birth) / 2.2))
        }
        var p = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        // cursor press: nodes near the cursor are pushed away (silk gives)
        let d = p - cursor
        let dist = sqrt(hypot2(d))
        let pushR: CGFloat = 150
        if dist < pushR, dist > 1 { let k = (pushR - dist) / pushR * 70; p.x += d.x / dist * k; p.y += d.y / dist * k }
        return p
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        // Build the whole web as one path: radial spokes + concentric rings.
        let path = CGMutablePath()
        @inline(__always) func pt(_ s: Int, _ r: Int) -> CGPoint {
            let n = node(s, r); return CGPoint(x: n.x - origin.x, y: n.y - origin.y)
        }
        // spokes (center → outward)
        for s in 0..<spokes {
            path.move(to: CGPoint(x: center.x - origin.x, y: center.y - origin.y))
            for r in 0..<rings { path.addLine(to: pt(s, r)) }
        }
        // rings (connect adjacent spokes at each radius, closing the loop)
        for r in 0..<rings {
            path.move(to: pt(0, r))
            for s in 1...spokes { path.addLine(to: pt(s % spokes, r)) }
        }
        strokeContrast(ctx, path, width: 1.0, alpha: 0.5, coreColor: Self.threadCore)

        // Dew drops at a scattering of nodes.
        for s in 0..<spokes {
            for r in 0..<rings where (s &* 3 &+ r) % 5 == 0 {
                let p = pt(s, r)
                let twinkle = 0.6 + 0.4 * CGFloat(sin(now * 1.3 + Double(s + r)))
                let rad: CGFloat = 4
                ctx.setBlendMode(.normal); ctx.setAlpha(0.85 * twinkle)
                ctx.draw(Self.dewCore, in: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.4 * twinkle)
                ctx.draw(Self.dewGlow, in: CGRect(x: p.x - rad * 2, y: p.y - rad * 2, width: rad * 4, height: rad * 4))
            }
        }
        // Keypress sparkles.
        for sp in sparkles {
            let t = CGFloat((now - sp.t) / 1.6)
            let a = (1 - t) * 0.9
            let rad: CGFloat = 4 + t * 6
            let x = sp.p.x - origin.x, y = sp.p.y - origin.y
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(a)
            ctx.draw(Self.dewGlow, in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
