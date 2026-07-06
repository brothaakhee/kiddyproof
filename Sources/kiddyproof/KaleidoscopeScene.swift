import AppKit

// KALEIDOSCOPE — everything the child does is mirrored into N-fold symmetry around a
// glowing center, so even random mashing composes itself into a living mandala.
//   • Moving the cursor paints a rainbow ribbon — times N.
//   • Every KEY grows glass petals whose color belongs to that key (letters have
//     their own hues — mash your name, get your palette).
//   • CLICK blooms a ring of petals that unfurls outward.
//   • CLICK-AND-HOLD spins the whole mandala up like a music box; release lets it
//     glide back to its lazy drift.
//   • SCROLL changes the symmetry itself (5…12-fold) — the entire artwork refolds
//     with a chime and a pulse.
// Ambient jewel-motes orbit so the mandala is never empty, and a soft heart-glow
// anchors the center. All elements are adaptive-contrast aware.
final class KaleidoscopeScene: Scene {
    let name = "Kaleidoscope"
    let category = SceneCategory.live
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    // Polar elements (radius/angle relative to the mandala center, in the UNSPUN frame).
    private struct Petal {
        var r: CGFloat; var ang: CGFloat
        var vr: CGFloat; var vang: CGFloat
        var size: CGFloat; var hue: Int
        var birth: TimeInterval; var life: Double
        var stretch: CGFloat        // 0 round … 1 elongated teardrop
    }
    private struct TrailDot {
        var r: CGFloat; var ang: CGFloat
        var birth: TimeInterval; var hue: Int
        var dir: CGFloat            // travel direction (unspun frame) for elongation
    }
    private struct Mote { var r: CGFloat; var ang: CGFloat; var angV: CGFloat; var size: CGFloat; var hue: Int; var phase: CGFloat }

    private var petals: [Petal] = []
    private var trail: [TrailDot] = []
    private var motes: [Mote] = []
    // Element budgets scale INVERSELY with symmetry: every element is drawn N times,
    // so the total on-screen sprite count stays roughly constant across refolds.
    private var maxPetals: Int { max(44, 760 / symmetry) }
    private var maxTrail: Int { max(24, 400 / symmetry) }
    private var rng = RNG(seed: 0xCA1E1D0)

    // Symmetry + spin.
    private var symmetry = 8            // 5…12, scroll-driven
    private var scrollAccum: CGFloat = 0
    private var spin: CGFloat = 0
    private var spinV: CGFloat = 0.05
    private var holdLevel: CGFloat = 0
    private var pulse: CGFloat = 0      // celebration flash when the symmetry refolds

    private var center = NSPoint.zero
    private var lastCursorRel = NSPoint.zero
    private var seeded = false
    private var now: TimeInterval = 0

    // Adaptive contrast cache.
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3

    // A full 12-hue wheel: keys map deterministically onto it, so every letter owns a
    // color and a mashed name becomes a palette.
    private static let hues: [NSColor] = (0..<12).map {
        NSColor(hue: CGFloat($0) / 12, saturation: 0.8, brightness: 1.0, alpha: 1)
    }
    private static let cores: [CGImage] = hues.map { softContrastSprite($0) }
    private static let glows: [CGImage] = hues.map { softGlowSprite($0) }
    private static let dark: CGImage = inkSprite(NSColor(white: 0, alpha: 1))

    var audioSwell: CGFloat { holdLevel * 0.3 }

    func reset() {
        petals.removeAll(keepingCapacity: true)
        trail.removeAll(keepingCapacity: true)
        motes.removeAll(keepingCapacity: true)
        symmetry = 8; scrollAccum = 0
        spin = 0; spinV = 0.05; holdLevel = 0; pulse = 0
        seeded = false
        draining = false
    }

    private func seedIfNeeded(_ bounds: CGRect) {
        guard !seeded else { return }
        seeded = true
        center = NSPoint(x: bounds.midX, y: bounds.midY)
        let maxR = min(bounds.width, bounds.height) * 0.42
        for _ in 0..<26 {
            motes.append(Mote(r: rng.range(40, maxR),
                              ang: rng.range(0, 6.28),
                              angV: rng.range(0.03, 0.12) * (rng.unit() > 0.5 ? 1 : -1),
                              size: rng.range(2.5, 5.5),
                              hue: rng.int(Self.hues.count),
                              phase: rng.range(0, 6.28)))
        }
    }

    private func rel(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x - center.x, y: p.y - center.y) }

    private func addPetal(_ p: Petal) {
        if petals.count >= maxPetals { petals.removeFirst() }
        petals.append(p)
    }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key(let s):
            // The key's own color: deterministic hash → hue.
            let hue = Int(s.unicodeScalars.reduce(7) { $0 &+ UInt32($1.value) }) % Self.hues.count
            let c = rel(ctx.cursor)
            let r = max(46, sqrt(c.x * c.x + c.y * c.y))
            let ang = atan2(c.y, c.x) - spin   // store in the unspun frame
            for _ in 0..<2 {
                // Jewel hierarchy: most petals are small beads, but one in six is a
                // statement stone — the mandala needs focal points, not confetti.
                let statement = rng.unit() < 0.17
                addPetal(Petal(r: r + rng.range(-24, 24), ang: ang + rng.range(-0.12, 0.12),
                               vr: rng.range(8, 30), vang: rng.range(-0.14, 0.14),
                               size: statement ? rng.range(20, 28) : rng.range(8, 14), hue: hue,
                               birth: ctx.now, life: Double(rng.range(6, 10)),
                               stretch: statement ? 0.3 : rng.range(0.4, 0.9)))
            }
            ctx.audio?.note(for: s, intensity: ctx.intensity)
        case .click(let pt, .left):
            // A bloom: a ring of petals unfurling outward from the click radius.
            let c = rel(pt)
            let r = max(40, sqrt(c.x * c.x + c.y * c.y))
            let baseAng = atan2(c.y, c.x) - spin
            let hue = rng.int(Self.hues.count)
            for k in 0..<9 {
                let a = baseAng + CGFloat(k) / 9 * 0.5 - 0.25
                addPetal(Petal(r: r, ang: a,
                               vr: rng.range(34, 60), vang: rng.range(-0.06, 0.06),
                               size: rng.range(10, 17), hue: (hue + k / 3) % Self.hues.count,
                               birth: ctx.now, life: Double(rng.range(4, 7)),
                               stretch: 0.85))
            }
            ctx.audio?.glimmer()
        case .scroll(let dy):
            // The symmetry lever: fold the whole artwork into more (or fewer) wedges.
            scrollAccum += CGFloat(dy) * 0.12
            if abs(scrollAccum) >= 1 {
                let dir = scrollAccum > 0 ? 1 : -1
                scrollAccum = 0
                let next = max(5, min(12, symmetry + dir))
                if next != symmetry {
                    symmetry = next
                    pulse = 1
                    ctx.audio?.ping()
                }
            }
        default:
            break
        }
    }

    func update(_ ctx: EffectContext) {
        seedIfNeeded(ctx.bounds)
        now = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        let dt = ctx.dt

        // Spin: lazy drift, wound up by holding — a music box in the child's hand.
        if ctx.leftButtonDown && !draining { holdLevel += (1 - holdLevel) * min(1, dt * 1.6) }
        else { holdLevel += (0 - holdLevel) * min(1, dt * 0.9) }   // long glide down
        spinV = 0.05 + holdLevel * 0.75
        spin += spinV * dt
        pulse = max(0, pulse - dt * 1.6)

        // Ribbon: sample the cursor into the unspun frame.
        let c = rel(ctx.cursor)
        let dc = NSPoint(x: c.x - lastCursorRel.x, y: c.y - lastCursorRel.y)
        let moved = sqrt(dc.x * dc.x + dc.y * dc.y)
        if moved > 12 {
            let r = sqrt(c.x * c.x + c.y * c.y)
            if r > 8 {
                let hue = Int(now * 3.2) % Self.hues.count   // the ribbon cycles the wheel
                if trail.count >= maxTrail { trail.removeFirst() }
                trail.append(TrailDot(r: r, ang: atan2(c.y, c.x) - spin,
                                      birth: now, hue: hue,
                                      dir: atan2(dc.y, dc.x) - spin))
            }
            lastCursorRel = c
        }
        trail.removeAll { now - $0.birth > 2.0 }

        // Petals: orbit, drift, age out.
        let maxR = min(ctx.bounds.width, ctx.bounds.height) * 0.46
        var i = 0
        while i < petals.count {
            if now - petals[i].birth >= petals[i].life { petals.remove(at: i); continue }
            petals[i].ang += petals[i].vang * dt
            petals[i].r += petals[i].vr * dt
            petals[i].vr *= exp(-0.8 * dt)                       // outward rush settles into orbit
            petals[i].vang += (0.05 - petals[i].vang) * dt * 0.3 // …and slowly joins the drift
            if petals[i].r > maxR { petals[i].r = maxR; petals[i].vr = -abs(petals[i].vr) * 0.5 }
            i += 1
        }

        for m in motes.indices {
            motes[m].ang += motes[m].angV * (1 + holdLevel * 1.5) * dt
        }
    }

    func liveCount() -> Int { petals.count + trail.count + motes.count }

    // One blit in mandala space: position is polar (unspun); each wedge adds its own
    // rotation. `elong` stretches the sprite along `dir` via a second offset blit.
    private func blit(_ ctx: CGContext, hue: Int, x: CGFloat, y: CGFloat, gx: CGFloat, gy: CGFloat,
                      rad: CGFloat, alpha: CGFloat, elong: CGFloat = 0, dir: CGFloat = 0) {
        let w = inkWeight(bgMap, bgFallback, NSPoint(x: gx, y: gy))
        ctx.setBlendMode(.normal)
        if w > 0.05 {
            ctx.setAlpha(alpha * 0.5 * w)
            let dr = rad * 1.35
            ctx.draw(Self.dark, in: CGRect(x: x - dr, y: y - dr, width: dr * 2, height: dr * 2))
        }
        ctx.setAlpha(alpha)
        let core = Self.cores[hue % Self.cores.count]
        ctx.draw(core, in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        if elong > 0.05 {
            let ox = cos(dir) * rad * 0.9 * elong, oy = sin(dir) * rad * 0.9 * elong
            ctx.setAlpha(alpha * 0.75)
            let r2 = rad * 0.75
            ctx.draw(core, in: CGRect(x: x + ox - r2, y: y + oy - r2, width: r2 * 2, height: r2 * 2))
        }
        let ga = alpha * 0.55 * (1 - 0.75 * w)
        if ga > 0.02 {
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(ga)
            let gr = rad * 2.0
            ctx.draw(Self.glows[hue % Self.glows.count], in: CGRect(x: x - gr, y: y - gr, width: gr * 2, height: gr * 2))
            ctx.setBlendMode(.normal)
        }
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
        let cx = center.x - origin.x, cy = center.y - origin.y
        let n = symmetry
        let wedge = 2 * CGFloat.pi / CGFloat(n)
        let flash = 1 + pulse * 0.5   // refold celebration briefly swells everything

        // Precompute every element once in polar; each wedge is just an angle offset.
        for k in 0..<n {
            let base = spin + wedge * CGFloat(k)

            // Ribbon trail (drawn first, beneath the petals).
            for t in trail {
                let age = CGFloat((now - t.birth) / 2.0)
                let a = (1 - age) * (1 - age) * 0.6
                guard a > 0.02 else { continue }
                let ang = t.ang + base
                let x = cx + cos(ang) * t.r, y = cy + sin(ang) * t.r
                blit(ctx, hue: t.hue, x: x, y: y, gx: x + origin.x, gy: y + origin.y,
                     rad: (7 - age * 3) * flash, alpha: a, elong: 0.9, dir: t.dir + base)
            }

            // Petals.
            for p in petals {
                let age = now - p.birth
                let fadeIn = min(1, CGFloat(age / 0.35))
                let fadeOut = max(0, min(1, CGFloat((p.life - age) / 1.4)))
                let a = fadeIn * fadeOut * 0.8
                guard a > 0.02 else { continue }
                let ang = p.ang + base
                let x = cx + cos(ang) * p.r, y = cy + sin(ang) * p.r
                blit(ctx, hue: p.hue, x: x, y: y, gx: x + origin.x, gy: y + origin.y,
                     rad: p.size * flash, alpha: a, elong: p.stretch, dir: ang + .pi / 2)
            }

            // Jewel motes (the resting mandala).
            for m in motes {
                let tw = 0.5 + 0.5 * CGFloat(sin(now * 1.1 + Double(m.phase)))
                let ang = m.ang + base
                let x = cx + cos(ang) * m.r, y = cy + sin(ang) * m.r
                blit(ctx, hue: m.hue, x: x, y: y, gx: x + origin.x, gy: y + origin.y,
                     rad: m.size * flash, alpha: 0.35 + 0.3 * tw)
            }
        }

        // The heart: a layered, slowly color-cycling jewel anchoring the center.
        // Glow carries it on dark pixels; on light ones (where additive light is
        // invisible) two concentric SOLID discs take over, so it anchors everywhere.
        let beat = 0.85 + 0.15 * CGFloat(sin(now * 1.6))
        let hr = (56 + holdLevel * 22 + pulse * 26) * beat
        let heartHue = Int(now * 0.7) % Self.hues.count
        let nextHue = (heartHue + 1) % Self.hues.count
        let hw = inkWeight(bgMap, bgFallback, center)
        if hw < 0.95 {
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(0.55 * (1 - hw))
            ctx.draw(Self.glows[heartHue], in: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2))
            ctx.setAlpha(0.35 * (1 - hw))
            let hr2 = hr * 0.62
            ctx.draw(Self.glows[nextHue], in: CGRect(x: cx - hr2, y: cy - hr2, width: hr2 * 2, height: hr2 * 2))
            ctx.setBlendMode(.normal)
        }
        if hw > 0.05 {
            ctx.setAlpha(0.3 * hw)
            let or2 = hr * 0.72
            ctx.draw(Self.cores[nextHue], in: CGRect(x: cx - or2, y: cy - or2, width: or2 * 2, height: or2 * 2))
        }
        ctx.setAlpha(1)
        blit(ctx, hue: heartHue, x: cx, y: cy, gx: center.x, gy: center.y, rad: hr * 0.42, alpha: 0.92)
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
