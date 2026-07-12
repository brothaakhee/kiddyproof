import AppKit

// CAT LAB — the development harness for Kiddy the cat (archived: never in the kid
// rotation; preview with KP_SCENE="Cat Lab"). The cursor is a LASER DOT: Kiddy
// notices it, stalks it, chases it, and pounces on it. Left alone she wanders,
// sits, grooms, stretches — cycling every behavior the rig supports. A key press
// startles her. The current state is labeled for screenshot verification, and
// KP_CATSTATE=<state> pins a state for pose captures.
final class CatLabScene: Scene {
    let name = "Cat Lab"
    let category = SceneCategory.archived
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    let veil: CGFloat = 0
    var draining = false

    private var cat: KiddyCat?
    private var rng = RNG(seed: 0xCA7CA7)
    private var nextIdleChange: TimeInterval = 0
    private var laserStill: TimeInterval = 0
    private var lastLaser = NSPoint.zero
    private var pinned: KiddyCat.State?
    private var bgMap: BackgroundLuminance?
    private var bgFallback: CGFloat = 0.3
    private var now: TimeInterval = 0
    private var laser = NSPoint.zero
    private var lastBounds = CGRect.zero

    func reset() {
        cat = nil
        nextIdleChange = 0
        pinned = ProcessInfo.processInfo.environment["KP_CATSTATE"]
            .flatMap { KiddyCat.State(rawValue: $0) }
        draining = false
    }

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining, let cat = cat else { return }
        // Pose-capture mode: demo/user input must not fight the pinned state
        // (every set(state:) resets stateTime and the settle-gated tail poses).
        guard pinned == nil else { return }
        switch e.kind {
        case .key:
            cat.startle()
            ctx.audio?.bonk(intensity: 0.3)
        case .click(let pt, .left):
            let x = max(lastBounds.minX + cat.size * 2, min(lastBounds.maxX - cat.size * 2, pt.x))
            cat.pounce(at: NSPoint(x: x, y: cat.groundY))
        default:
            break
        }
    }

    func update(_ ctx: EffectContext) {
        now = ctx.now
        bgMap = ctx.background; bgFallback = ctx.fallbackLightness
        laser = ctx.cursor
        lastBounds = ctx.bounds

        if cat == nil {
            let ground = ctx.bounds.minY + 140
            let c = KiddyCat(at: NSPoint(x: ctx.bounds.midX - 200, y: ground), groundY: ground, size: 58)
            switch ProcessInfo.processInfo.environment["KP_CATSTYLE"] {
            case "arcade": c.style = .arcade
            case "pixel": c.style = .pixel
            default: break
            }
            cat = c
        }
        guard let cat = cat else { return }

        if let pin = pinned {
            // Pose-capture mode: hold one state (walk/trot keep moving for gait shots).
            if cat.state != pin { cat.set(state: pin) }
            cat.interest = laser
            keepOnScreen(cat, ctx)
            cat.update(dt: ctx.dt, now: now)
            // Display stand for the flight pose: hold her mid-air so the
            // leap can be seen (live pounces arc through this in 0.4s).
            if pin == .pounceAir { cat.pos.y = cat.groundY + cat.size * 1.1 }
            return
        }

        // --- Laser-driven behavior ---
        let toLaser = laser.x - cat.pos.x
        let laserDist = abs(toLaser)
        let laserMoved = sqrt(hypot2(laser - lastLaser))
        lastLaser = laser
        laserStill = laserMoved < 3 ? laserStill + Double(ctx.dt) : 0
        let laserNear = laserDist < ctx.bounds.width * 0.4 && laser.y < cat.groundY + 320

        switch cat.state {
        case .idle, .sit, .groom, .stretch, .lie, .walk, .trot, .play, .eat:
            cat.interest = laserNear ? laser : nil
            if laserNear, laserMoved > 6 {
                // A moving dot is irresistible.
                cat.face(toLaser)
                cat.set(state: laserDist > 420 ? .trot : .stalk)
            } else if now >= nextIdleChange {
                // Autonomous life: amble, rest, groom, stretch.
                let choices: [KiddyCat.State] = [.walk, .idle, .sit, .groom, .stretch, .lie, .walk, .trot, .play, .eat]
                let pick = choices[rng.int(choices.count)]
                if pick == .walk || pick == .trot { cat.face(rng.unit() > 0.5 ? 1 : -1) }
                // Re-picking the current state must not reset its settle clock —
                // the traced resting poses need uninterrupted stateTime to engage.
                if pick != cat.state { cat.set(state: pick) }
                nextIdleChange = now + Double(rng.range(2.2, 5.5))
            }
        case .stalk:
            cat.interest = laser
            cat.face(toLaser)
            if !laserNear {
                cat.set(state: .idle)
            } else if laserDist < 190, laserStill > 0.25 {
                let x = max(ctx.bounds.minX + cat.size * 2, min(ctx.bounds.maxX - cat.size * 2, laser.x))
                cat.pounce(at: NSPoint(x: x, y: cat.groundY))
            } else if laserDist > 500 {
                cat.set(state: .trot)
            }
        case .pounceWindup, .pounceAir, .land, .startle:
            cat.interest = laser
        }

        keepOnScreen(cat, ctx)
        cat.update(dt: ctx.dt, now: now)
    }

    private func keepOnScreen(_ cat: KiddyCat, _ ctx: EffectContext) {
        let margin = cat.size * 2.4
        if cat.pos.x < ctx.bounds.minX + margin { cat.face(1) }
        if cat.pos.x > ctx.bounds.maxX - margin { cat.face(-1) }
        // Hard clamp: a pounce ballistic must never carry her off-screen.
        cat.pos.x = max(ctx.bounds.minX + cat.size, min(ctx.bounds.maxX - cat.size, cat.pos.x))
    }

    func liveCount() -> Int { cat == nil ? 0 : 1 }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        guard let cat = cat else { return }
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
        let w = inkWeight(bgMap, bgFallback, cat.pos)

        // Ground line so the gait has a visible floor to plant on.
        let gy = cat.groundY - origin.y
        ctx.setLineWidth(2)
        ctx.setStrokeColor(blendColor(NSColor(srgbRed: 0.7, green: 0.75, blue: 0.85, alpha: 1), .black, 0.4 * w)
            .withAlphaComponent(0.5).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: gy))
        ctx.addLine(to: CGPoint(x: bounds.width, y: gy))
        ctx.strokePath()

        cat.draw(into: ctx, origin: origin, inkW: w)

        // The laser dot (the future scene's core interaction, useful in the lab now).
        let lx = laser.x - origin.x, ly = laser.y - origin.y
        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: lx - 5, y: ly - 5, width: 10, height: 10))
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.3, blue: 0.2, alpha: 0.3).cgColor)
        ctx.fillEllipse(in: CGRect(x: lx - 12, y: ly - 12, width: 24, height: 24))
        ctx.setBlendMode(.normal)

        // Dev label: current state (screenshot-verifiable).
        let label = "state: \(cat.state.rawValue)  facing: \(cat.facing > 0 ? "→" : "←")"
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(white: 1 - w, alpha: 0.8),
        ]).draw(at: CGPoint(x: 24, y: gy - 44))
        ctx.setAlpha(1); ctx.setBlendMode(.normal)
    }
}
