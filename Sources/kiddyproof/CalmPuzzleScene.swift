import AppKit

// PUZZLE PIECES — soft jigsaw pieces drift and slowly turn through space, gently gathering
// toward the cursor as if assembling, then easing apart again. Each piece is a rounded
// body with tab knobs, drawn as a colored shape over a slightly larger dark casing so it
// reads on light AND dark wallpaper. A click is a soft gust; a keypress adds a piece.
final class CalmPuzzleScene: Scene {
    let name = "Puzzle Pieces"
    let category = SceneCategory.calm
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private struct Piece {
        var pos: NSPoint; var vel: NSPoint
        var angle: CGFloat; var angVel: CGFloat; var half: CGFloat; var color: Int
        var tabs: [Bool]   // right, top, left, bottom
    }
    private var pieces: [Piece] = []
    private let ambient = 26
    private let maxPieces = 60
    private var rng = RNG(seed: 0x9022E)
    private var seededSize = CGSize.zero
    private var pulses: [(p: NSPoint, t: TimeInterval)] = []

    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.7, blue: 0.72, alpha: 1),   // coral
        NSColor(srgbRed: 0.7, green: 0.85, blue: 0.95, alpha: 1),   // sky
        NSColor(srgbRed: 0.8, green: 0.9, blue: 0.72, alpha: 1),    // sage
        NSColor(srgbRed: 0.95, green: 0.85, blue: 0.65, alpha: 1),  // butter
        NSColor(srgbRed: 0.85, green: 0.78, blue: 0.95, alpha: 1),  // lilac
    ]

    func reset() { pieces.removeAll(keepingCapacity: true); pulses.removeAll(); seededSize = .zero; draining = false }

    private func newPiece(_ b: CGRect, at: NSPoint? = nil) -> Piece {
        Piece(pos: at ?? NSPoint(x: rng.range(b.minX, b.maxX), y: rng.range(b.minY, b.maxY)),
              vel: NSPoint(x: rng.range(-18, 18), y: rng.range(-18, 18)),
              angle: rng.range(0, 6.28), angVel: rng.range(-0.5, 0.5), half: rng.range(16, 28),
              color: rng.int(Self.colors.count),
              tabs: [rng.unit() > 0.5, rng.unit() > 0.5, rng.unit() > 0.5, rng.unit() > 0.5])
    }

    private func seedIfNeeded(_ b: CGRect) {
        guard b.size != seededSize else { return }
        seededSize = b.size
        pieces.removeAll(keepingCapacity: true)
        for _ in 0..<ambient { pieces.append(newPiece(b)) }
    }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key:
            if pieces.count < maxPieces { pieces.append(newPiece(ctx.bounds, at: ctx.cursor)) }
            ctx.audio?.note(for: ks(e), intensity: ctx.intensity)
        case .click(let pt, .left): pulses.append((pt, ctx.now)); ctx.audio?.whoosh()
        default: break
        }
    }
    private func ks(_ e: InputEvent) -> String { if case let .key(s) = e.kind { return s }; return " " }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        let dt = ctx.dt, cur = ctx.cursor
        let gather = 36 + 70 * ctx.intensity
        pulses.removeAll { ctx.now - $0.t > 0.8 }
        for i in pieces.indices {
            var v = pieces[i].vel
            v.x += rng.range(-8, 8) * dt; v.y += rng.range(-8, 8) * dt
            let d = cur - pieces[i].pos, dist2 = hypot2(d)
            if dist2 > 25, dist2 < 360 * 360 {
                let dist = sqrt(dist2), f = gather / max(90, dist)
                v.x += d.x / dist * f * dt; v.y += d.y / dist * f * dt
            }
            for pulse in pulses {
                let pd = pieces[i].pos - pulse.p, pdist = sqrt(hypot2(pd))
                if pdist < 200, pdist > 1 { let f = (1 - pdist / 200) * 160; v.x += pd.x / pdist * f * dt; v.y += pd.y / pdist * f * dt; pieces[i].angVel += rng.range(-1, 1) }
            }
            v.x *= exp(-0.7 * dt); v.y *= exp(-0.7 * dt)
            let sp2 = hypot2(v); if sp2 > 60 * 60 { let s = 60 / sqrt(sp2); v.x *= s; v.y *= s }
            pieces[i].vel = v
            var p = pieces[i].pos + v * dt
            if p.x < ctx.bounds.minX - 40 { p.x = ctx.bounds.maxX + 40 }
            if p.x > ctx.bounds.maxX + 40 { p.x = ctx.bounds.minX - 40 }
            if p.y < ctx.bounds.minY - 40 { p.y = ctx.bounds.maxY + 40 }
            if p.y > ctx.bounds.maxY + 40 { p.y = ctx.bounds.minY - 40 }
            pieces[i].pos = p
            pieces[i].angle += pieces[i].angVel * dt
        }
    }

    func liveCount() -> Int { pieces.count }

    private func piecePath(_ half: CGFloat, _ tabs: [Bool]) -> CGPath {
        let p = CGMutablePath()
        let rect = CGRect(x: -half, y: -half, width: half * 2, height: half * 2)
        p.addRoundedRect(in: rect, cornerWidth: half * 0.2, cornerHeight: half * 0.2)
        let k = half * 0.36
        let centers = [NSPoint(x: half, y: 0), NSPoint(x: 0, y: half), NSPoint(x: -half, y: 0), NSPoint(x: 0, y: -half)]
        for (idx, c) in centers.enumerated() where tabs[idx] {
            p.addEllipse(in: CGRect(x: c.x - k, y: c.y - k, width: k * 2, height: k * 2))
        }
        return p
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        for piece in pieces {
            ctx.saveGState()
            ctx.translateBy(x: piece.pos.x - origin.x, y: piece.pos.y - origin.y)
            ctx.rotate(by: piece.angle)
            // dark casing (slightly larger) → contrast on light wallpaper
            ctx.setBlendMode(.normal); ctx.setAlpha(0.4)
            ctx.addPath(piecePath(piece.half + 2.2, piece.tabs)); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            // colored body
            ctx.setAlpha(0.82)
            ctx.addPath(piecePath(piece.half, piece.tabs)); ctx.setFillColor(Self.colors[piece.color % Self.colors.count].cgColor); ctx.fillPath()
            // soft top highlight
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.18)
            ctx.addPath(piecePath(piece.half * 0.6, [false, false, false, false])); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
