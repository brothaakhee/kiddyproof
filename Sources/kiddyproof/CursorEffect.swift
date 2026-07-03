import AppKit

// Per-scene cursor look. Carries pre-baked sprites so the head reads on ANY wallpaper
// (bright core + soft dark halo) with an additive bloom for extra glow on dark.
struct CursorSkin {
    let baseColor: CGColor
    let glow: Bool
    let blackHole: Bool
    let trailWidthHead: CGFloat
    let coreSprite: CGImage?
    let glowSprite: CGImage?
    var inkStamp: CGImage? = nil   // when set, the trail is painted as a soft wet ink brush
    var hidden = false        // scene draws its own cursor visual; suppress the effect's

    private static func make(_ c: NSColor, blackHole: Bool, trail: CGFloat, ink: Bool = false) -> CursorSkin {
        CursorSkin(baseColor: c.cgColor, glow: true, blackHole: blackHole, trailWidthHead: trail,
                   coreSprite: blackHole ? nil : softContrastSprite(c),
                   glowSprite: blackHole ? nil : softGlowSprite(c),
                   inkStamp: ink ? inkSprite(c) : nil)
    }
    static let comet = make(NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 1), blackHole: false, trail: 14)
    static let blackHole = make(NSColor(srgbRed: 0.6, green: 0.4, blue: 1, alpha: 1), blackHole: true, trail: 10)
    // Calm scenes: a soft warm glow that paints a gentle wet-ink brush trail.
    static let soft = make(NSColor(srgbRed: 1, green: 0.92, blue: 0.7, alpha: 1), blackHole: false, trail: 6, ink: true)
    // For scenes that render their own cursor (e.g. the black hole).
    static let none = CursorSkin(baseColor: NSColor.black.cgColor, glow: false, blackHole: false,
                                 trailWidthHead: 0, coreSprite: nil, glowSprite: nil, hidden: true)
}

// Shared, always-on cursor effect. One instance owned by the manager (the virtual
// cursor is global). Trail is time- and length-capped so it can never smear the
// whole screen; velocity is derived render-side (the tap callback stays tiny).
final class CursorEffect {
    private struct Sample { var p: NSPoint; var t: TimeInterval }
    private var ring = [Sample]()
    private let maxSamples = 48
    private let maxAge: TimeInterval = 0.35
    private var lastPos = NSPoint.zero
    private var velocity = NSPoint.zero

    private static let blackHoleGrad = CGGradient(
        colorsSpace: sharedRGB,
        colors: [NSColor.black.cgColor, NSColor(white: 0.05, alpha: 0).cgColor] as CFArray,
        locations: [0, 1])

    func reset() { ring.removeAll(keepingCapacity: true); velocity = .zero }

    func update(cursor: NSPoint, dt: CGFloat, now: TimeInterval) {
        let moved = cursor - lastPos
        if dt > 0 {
            let inst = moved * (1 / dt)
            let k = 1 - exp(-dt / 0.05)
            velocity = velocity + (inst - velocity) * k
        }
        let last = ring.last
        if last == nil || hypot2(cursor - last!.p) >= 4 {
            ring.append(Sample(p: cursor, t: now))
            if ring.count > maxSamples { ring.removeFirst(ring.count - maxSamples) }
        }
        ring.removeAll { now - $0.t > maxAge }
        lastPos = cursor
    }

    var currentVelocity: NSPoint { velocity }

    func draw(into ctx: CGContext, origin: CGPoint, skin: CursorSkin, now: TimeInterval) {
        if skin.hidden { return }   // scene draws its own cursor (e.g. the black hole)
        // Wet ink brush trail: overlapping soft dabs, tapered + fading newest→oldest, so
        // the cursor paints a flowing stroke that bleeds away when it stops moving.
        if let stamp = skin.inkStamp, ring.count >= 2 {
            ctx.setBlendMode(.normal)
            let n = ring.count
            for j in stride(from: n - 1, to: 0, by: -1) {
                let s = ring[j]
                let u = CGFloat(n - 1 - j) / CGFloat(n - 1)
                let ageFade = max(0, 1 - CGFloat((now - s.t) / maxAge))
                let alpha = pow(1 - u, 1.6) * 0.5 * ageFade
                if alpha < 0.02 { continue }
                let r = max(2, (skin.trailWidthHead * 1.8) * pow(1 - u, 0.7))
                ctx.setAlpha(alpha)
                ctx.draw(stamp, in: CGRect(x: s.p.x - origin.x - r, y: s.p.y - origin.y - r, width: r * 2, height: r * 2))
            }
            ctx.setAlpha(1)
            drawHead(into: ctx, origin: origin, skin: skin)
            return
        }
        // Trail (newest→oldest, tapered). Fades to nothing when the cursor is still.
        if ring.count >= 2 {
            ctx.setBlendMode(skin.glow ? .plusLighter : .normal)
            ctx.setLineCap(.round)
            let n = ring.count
            for j in stride(from: n - 1, to: 0, by: -1) {
                let a = ring[j], b = ring[j - 1]
                let u = CGFloat(n - 1 - j) / CGFloat(n - 1)
                let ageFade = max(0, 1 - CGFloat((now - a.t) / maxAge))
                let alpha = pow(1 - u, 2) * 0.8 * ageFade
                if alpha < 0.02 { continue }
                ctx.setLineWidth(max(0.5, skin.trailWidthHead * pow(1 - u, 1.5)))
                ctx.setStrokeColor(skin.baseColor.copy(alpha: alpha)!)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: a.p.x - origin.x, y: a.p.y - origin.y))
                ctx.addLine(to: CGPoint(x: b.p.x - origin.x, y: b.p.y - origin.y))
                ctx.strokePath()
            }
            ctx.setBlendMode(.normal)
        }
        drawHead(into: ctx, origin: origin, skin: skin)
    }

    // Head sprite — drawn at the CURRENT cursor EVERY frame (not the last trail
    // sample), so it never vanishes/strobes when the cursor pauses.
    private func drawHead(into ctx: CGContext, origin: CGPoint, skin: CursorSkin) {
        let c = CGPoint(x: lastPos.x - origin.x, y: lastPos.y - origin.y)
        if skin.blackHole {
            let r: CGFloat = 44
            if let g = Self.blackHoleGrad {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
            ctx.setStrokeColor(skin.baseColor.copy(alpha: 0.9)!)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.6, y: c.y - r * 0.6, width: r * 1.2, height: r * 1.2))
        } else {
            let r: CGFloat = 22
            ctx.setBlendMode(.normal); ctx.setAlpha(1)
            if let core = skin.coreSprite {
                ctx.draw(core, in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            if let glow = skin.glowSprite {
                ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.55)
                let gr = r * 1.4
                ctx.draw(glow, in: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2))
                ctx.setAlpha(1)
            }
            ctx.setBlendMode(.normal)
        }
    }
}
