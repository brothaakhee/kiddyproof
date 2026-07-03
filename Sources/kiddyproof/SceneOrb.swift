import AppKit

// The kid-tappable "scene orb": a glowing disc in the TOP-RIGHT (diagonally
// opposite the bottom-left exit hot-zone, so the two can never be hit together).
// Cycles scenes on a left-click inside the disc OR a 0.9s dwell, debounced to
// ≤1 switch / 1.2s so a mashing toddler can't strobe through scenes.
final class SceneOrb {
    var onCycle: (() -> Void)?
    var enabled = true

    private let radius: CGFloat = 64
    private let hitPad: CGFloat = 28
    private let cooldown: TimeInterval = 1.2
    private let dwellNeeded: TimeInterval = 0.9

    private var center = NSPoint.zero      // global coords, set each frame
    private var lastCycle: TimeInterval = -10
    private var dwellStart: TimeInterval?
    private var popBirth: TimeInterval = -10
    private var hoverAmt: CGFloat = 0

    // Fixed gradients, built once (drawn every frame, so never recreate them).
    private static let glowGrad = CGGradient(colorsSpace: sharedRGB,
        colors: [NSColor(srgbRed: 0.6, green: 0.85, blue: 1, alpha: 1).cgColor,
                 NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])
    private static let bodyGrad = CGGradient(colorsSpace: sharedRGB,
        colors: [NSColor(srgbRed: 0.9, green: 0.97, blue: 1, alpha: 0.95).cgColor,
                 NSColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 0.95).cgColor] as CFArray, locations: [0, 1])

    func reset() { lastCycle = -10; dwellStart = nil; popBirth = -10; hoverAmt = 0 }

    // Single source of truth for the hit zone (squared distance — no sqrt). The manager
    // passes its own orb center so the two never silently diverge.
    func contains(_ p: NSPoint, center: NSPoint) -> Bool {
        let pad = radius + hitPad
        return hypot2(p - center) <= pad * pad
    }
    private func inDisc(_ p: NSPoint) -> Bool { contains(p, center: center) }

    // Called once per frame. `taps` are this frame's left-click points (global).
    func update(center: NSPoint, cursor: NSPoint, taps: [NSPoint], dt: CGFloat, now: TimeInterval) {
        self.center = center
        guard enabled else { dwellStart = nil; return }
        let cooling = now - lastCycle < cooldown

        // hover animation
        let near = sqrt(hypot2(cursor - center)) < 160
        hoverAmt += ((near ? 1 : 0) - hoverAmt) * min(1, dt * 12)

        if cooling { dwellStart = nil; return }

        // tap channel
        for t in taps where inDisc(t) { cycle(now); return }

        // dwell channel
        if inDisc(cursor) {
            if dwellStart == nil { dwellStart = now }
            else if now - dwellStart! >= dwellNeeded { cycle(now); return }
        } else { dwellStart = nil }
    }

    private func cycle(_ now: TimeInterval) {
        lastCycle = now; dwellStart = nil; popBirth = now
        onCycle?()
    }

    func draw(into ctx: CGContext, origin: CGPoint, now: TimeInterval) {
        guard enabled else { return }
        let c = CGPoint(x: center.x - origin.x, y: center.y - origin.y)
        let pulse = 1 + 0.06 * CGFloat(sin(now * 2 * .pi * 0.5))
        let pop = now - popBirth < 0.3 ? 1 + 0.4 * CGFloat(sin(.pi * (now - popBirth) / 0.3)) : 1
        let scale = pulse * pop * (1 + 0.15 * hoverAmt)
        let r = radius * scale

        // glow (cached gradient; animated brightness via setAlpha)
        let glowA = 0.35 + 0.25 * CGFloat(sin(now * 3)) + 0.3 * hoverAmt
        if let g = Self.glowGrad {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(min(1, glowA))
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 1.8, options: [])
            ctx.restoreGState()
        }

        // body — CLIPPED to the disc. (Without the clip, .drawsAfterEndLocation fills the
        // entire screen with the end color every frame: a full-screen per-pixel radial
        // gradient that both hides the scene and saturates the CPU renderer.)
        if let g = Self.bodyGrad {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x, y: c.y + r * 0.3), startRadius: 1,
                                   endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        // cooldown / dwell charge ring
        let charge: CGFloat
        if let ds = dwellStart { charge = min(1, CGFloat((now - ds) / dwellNeeded)) }
        else { charge = min(1, CGFloat((now - lastCycle) / cooldown)) }
        if charge < 1 {
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(4)
            let path = CGMutablePath()
            path.addArc(center: c, radius: r + 6, startAngle: .pi / 2,
                        endAngle: .pi / 2 - charge * 2 * .pi, clockwise: true)
            ctx.addPath(path); ctx.strokePath()
        }
        // sparkle icon
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
    }
}
