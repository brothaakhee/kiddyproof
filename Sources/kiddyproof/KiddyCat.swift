import AppKit

// KIDDY — the brand cat. A silhouette cat rig with realistic anatomy and lifelike
// motion, built to be reusable: first in the Cat Lab harness, later as the easter-egg
// cameo and a full scene. Realism comes from MOTION, not rendering:
//   • PLANTED FEET: stance feet are world-anchored while the body travels; swing feet
//     arc forward with a lift — the single biggest "real gait vs sliding sprite" cue.
//   • A verlet-chain tail with gravity, stiffness, and mood bias (raised when content,
//     low and twitchy when stalking).
//   • A state machine (idle/sit/groom/stretch/walk/trot/stalk/pounce/startle) whose
//     poses BLEND over ~0.25s instead of snapping.
//   • Idle life: breathing, ear flicks, slow blinks — a cat is never truly still.
// Adaptive silhouette: near-black over light backgrounds, warm silver over dark.
final class KiddyCat {

    // Two looks, one brain: the elegant silhouette and the chunky arcade mascot
    // share the same skeleton, gait, tail physics, and behavior states.
    enum Style { case silhouette, arcade, pixel, model3d }
    var style: Style = .silhouette

    // The 3D skin (Quaternius animated cat via SceneKit); created on demand.
    private lazy var renderer3D = KiddyCat3D()

    enum State: String {
        case idle, sit, groom, stretch, lie, walk, trot, stalk, pounceWindup, pounceAir, land, startle, play, eat
    }

    // MARK: Public surface

    private(set) var state: State = .idle
    var pos: NSPoint          // ground anchor under the body center (world coords)
    var facing: CGFloat = 1   // +1 → cat faces right
    var size: CGFloat         // body half-length in px (~55 reads well)
    var groundY: CGFloat

    // Where the cat is looking (head tracking), if anything.
    var interest: NSPoint?

    init(at p: NSPoint, groundY: CGFloat, size: CGFloat = 55) {
        self.pos = p
        self.groundY = groundY
        self.size = size
        pos.y = groundY
        let seg = size * 0.18
        tail = (0..<10).map { i in NSPoint(x: p.x - size * 0.9 - CGFloat(i) * seg, y: groundY + size * 0.55) }
        tailPrev = tail
    }

    // MARK: Locomotion + state control

    private(set) var speed: CGFloat = 0          // signed world px/s (sign = direction)
    private var targetSpeed: CGFloat = 0
    private var stateTime: TimeInterval = 0
    private var blend: CGFloat = 1               // 0→1 pose blend into the current state
    private var prevPose = Pose()
    private var now: TimeInterval = 0

    // Pounce ballistics.
    private var vy: CGFloat = 0
    private var pounceTarget: NSPoint?

    // Idle life.
    private var blinkAt: TimeInterval = 1.5
    private var blinkPhase: CGFloat = 0          // 0 open … 1 closed
    private var earFlickAt: TimeInterval = 2.5
    private var earFlick: CGFloat = 0
    private var rng = RNG(seed: 0xCA7)

    func set(state newState: State) {
        guard newState != state else { return }
        prevPose = currentPose()
        state = newState
        stateTime = 0
        blend = 0
        switch newState {
        case .walk: targetSpeed = size * 1.3      // calm, catlike amble
        case .trot: targetSpeed = size * 3.0
        case .stalk: targetSpeed = size * 1.1
        case .pounceWindup: targetSpeed = 0
        case .pounceAir: break
        default: targetSpeed = 0
        }
    }

    func face(_ dir: CGFloat) { facing = dir >= 0 ? 1 : -1 }

    // True while feet are on the ground and no launch is in progress.
    private var grounded: Bool {
        pos.y <= groundY + 1 && state != .pounceAir && state != .startle
    }

    // Launch at a world point (harness decides when). Ignored while airborne —
    // re-launching mid-flight compounds velocity and sends the cat flying.
    func pounce(at target: NSPoint) {
        guard grounded else { return }
        pounceTarget = target
        set(state: .pounceWindup)
    }

    func startle() {
        guard grounded else { return }
        set(state: .startle)
        vy = size * 7.5
    }

    // MARK: Update

    func update(dt: CGFloat, now t: TimeInterval) {
        now = t
        stateTime += Double(dt)
        blend = min(1, blend + dt * 4.5)

        // Idle life timers.
        if t >= blinkAt {
            blinkPhase = 1
            blinkAt = t + Double(rng.range(2.2, 6.5))
        }
        blinkPhase = max(0, blinkPhase - dt * 6)     // ~0.17s blink
        if t >= earFlickAt {
            earFlick = 1
            earFlickAt = t + Double(rng.range(3, 9))
        }
        earFlick = max(0, earFlick - dt * 5)

        // Locomotion.
        let accel: CGFloat = size * 6
        let want = targetSpeed * facing
        if speed < want { speed = min(want, speed + accel * dt) }
        if speed > want { speed = max(want, speed - accel * dt) }
        pos.x += speed * dt

        // Gait clock advances with distance so stride frequency tracks speed.
        let stride = strideLength()
        if stride > 0, abs(speed) > 1 {
            gaitPhase += abs(speed) * dt / stride
            gaitPhase = gaitPhase.truncatingRemainder(dividingBy: 1)
        }

        // State-specific progression.
        switch state {
        case .pounceWindup:
            if stateTime > 0.28, let target = pounceTarget {
                // Ballistic solve: reach target x in T while arcing.
                let T: CGFloat = 0.42
                let dx = target.x - pos.x
                speed = dx / T
                facing = dx >= 0 ? 1 : -1
                vy = size * 6.2
                set(state: .pounceAir)
            }
        case .pounceAir:
            vy -= size * 30 * dt
            pos.y += vy * dt
            if pos.y <= groundY, vy < 0 {
                pos.y = groundY
                speed = 0
                set(state: .land)
            }
        case .startle:
            vy -= size * 30 * dt
            pos.y += vy * dt
            if pos.y <= groundY, vy < 0 {
                pos.y = groundY
                set(state: .idle)
            }
        case .land:
            if stateTime > 0.3 { set(state: .idle) }
        default:
            pos.y = groundY
        }

        // Head tracking eases toward the interest point.
        let wantHead: CGFloat
        if let i = interest {
            let dx = (i.x - headWorldX()) * facing
            let dy = i.y - (groundY + size * 0.92)
            wantHead = max(-0.5, min(0.6, atan2(dy, max(30, abs(dx))) * 0.9))
        } else { wantHead = 0 }
        headPitch += (wantHead - headPitch) * min(1, dt * 6)

        updateTail(dt: dt)
        updateMorph(dt: dt)
        if style == .model3d {
            renderer3D?.update(dt: dt, state: state, speed: speed, facing: facing, size: size)
        }
    }

    private func headWorldX() -> CGFloat { pos.x + facing * size * 1.05 }

    // MARK: Gait (planted feet)

    // Legs indexed: 0 front-near, 1 front-far, 2 rear-near, 3 rear-far.
    // Lateral-sequence walk offsets; trot pairs diagonals.
    private var gaitPhase: CGFloat = 0
    private var headPitch: CGFloat = 0

    private func strideLength() -> CGFloat {
        switch state {
        case .trot: return size * 1.5
        case .stalk: return size * 0.9
        default: return size * 1.15
        }
    }

    private func legOffsets() -> [CGFloat] {
        switch state {
        case .trot: return [0, 0.5, 0.5, 0]          // diagonal pairs
        default: return [0.6, 0.1, 0.35, 0.85]       // lateral-sequence walk
        }
    }

    private func swingDuty() -> CGFloat { state == .trot ? 0.38 : 0.3 }

    // Foot position relative to its hip anchor, x in world-forward units.
    // Stance: foot slides backward relative to the body exactly as fast as the body
    // moves forward → world-anchored. Swing: eased forward flight with a lift arc.
    private func footOffset(_ leg: Int, stride: CGFloat) -> (dx: CGFloat, lift: CGFloat) {
        guard abs(speed) > 1 else { return (0, 0) }
        let duty = swingDuty()
        let c = (gaitPhase - legOffsets()[leg]).truncatingRemainder(dividingBy: 1)
        let cc = c < 0 ? c + 1 : c
        if cc < duty {
            let p = cc / duty
            let e = p * p * (3 - 2 * p)
            let lift = sin(p * .pi) * size * (state == .trot ? 0.34 : 0.22)
            return (stride * (e - 0.5), lift)
        } else {
            let p = (cc - duty) / (1 - duty)
            return (stride * (0.5 - p), 0)
        }
    }

    // MARK: Tail (verlet chain)

    private var tail: [NSPoint]
    private var tailPrev: [NSPoint]

    private func tailMood() -> (liftBias: CGFloat, sway: CGFloat) {
        switch state {
        case .stalk, .pounceWindup: return (-0.25, 2.6)   // low, twitchy
        case .walk, .trot: return (0.74, 0.9)             // raised, soft S
        case .startle: return (1.1, 0)                    // bottle-brush up
        case .pounceAir: return (1.0, 0)                  // carried up-back in flight
        case .sit, .groom, .lie, .eat: return (0.22, 0.35)  // wrapped low, tip curled
        case .play: return (0.85, 1.6)                    // raised, whippy
        default: return (0.55, 0.6)
        }
    }

    private func updateTail(dt: CGFloat) {
        let pose = currentPose()
        let rootBack: CGFloat = style == .arcade
            ? (state == .sit || state == .groom ? 0.42 : 0.52)
            : (state == .sit || state == .groom ? 0.54 : 0.64)
        let root = NSPoint(x: pos.x - facing * size * rootBack,
                           y: pos.y + size * pose.rumpHeight * (style == .arcade ? 0.72 : 0.88))
        let seg = size * 0.18
        let (lift, sway) = tailMood()
        // Verlet integrate.
        for i in 0..<tail.count {
            let cur = tail[i]
            var vel = NSPoint(x: (cur.x - tailPrev[i].x) * 0.92, y: (cur.y - tailPrev[i].y) * 0.92)
            // Gravity vs the mood's lift; the tip sways with an idle wave.
            let t = CGFloat(i) / CGFloat(tail.count - 1)
            vel.y += (lift * t * size * 5.2 - size * 2.2) * dt * dt * 60
            vel.x += CGFloat(sin(now * (1.3 + Double(sway)) + Double(t) * 2.6)) * sway * t * size * 0.5 * dt
            // Sitting: the tail curls forward and wraps around the paws.
            if state == .sit || state == .groom || state == .lie || state == .eat {
                vel.x += facing * t * t * size * 1.9 * dt * dt * 60
            }
            tailPrev[i] = cur
            tail[i] = cur + vel
            // The tail never drags through the floor.
            if tail[i].y < groundY + size * 0.08 { tail[i].y = groundY + size * 0.08 }
        }
        tail[0] = root
        tailPrev[0] = root
        // Standing/walking: ease toward the reference's tall S-curve carriage
        // (bows back mid-length, tip hooks forward). Weak pull — the verlet
        // sway stays audible on top.
        if state == .idle || state == .walk || state == .trot {
            let settle = CGFloat(min(1, max(0, stateTime - 0.1) * 1.6))
            if settle > 0 {
                let n = tail.count
                for i in 1..<n {
                    let t = CGFloat(i) / CGFloat(n - 1)
                    // Traced-stand tail centerline: base behind the rump, mid
                    // bowing further back, tip hooking forward — a soft S whose
                    // arc length matches the chain, so no slack juts straight up.
                    let tx = pos.x - facing * size * (0.60 + 0.42 * sin(.pi * min(t * 1.3, 1)))
                    let ty = groundY + size * (0.88 + 1.02 * t)
                    let k = settle * min(1, dt * 9)
                    let dx = (tx - tail[i].x) * k, dy = (ty - tail[i].y) * k
                    tail[i].x += dx; tail[i].y += dy
                    tailPrev[i].x += dx; tailPrev[i].y += dy   // no velocity injection
                }
            }
        }
        // Seated/loafing: after the physics settle, ease the chain onto an
        // AUTHORED wrap — down from the rump, forward along the ground past the
        // paws, tip curled up — the reference pose physics alone won't find.
        if state == .sit || state == .groom || state == .lie || state == .eat {
            let settle = CGFloat(min(1, max(0, stateTime - 0.4) * 0.9))
            if settle > 0 {
                let n = tail.count
                for i in 1..<n {
                    let t = CGFloat(i) / CGFloat(n - 1)
                    let tx = pos.x + facing * size * (-0.56 + 0.74 * t)
                    let drop = 0.42 * (1 - t) * (1 - t)
                    let curl = t > 0.72 ? (t - 0.72) * 1.9 : 0
                    let ty = groundY + size * (0.09 + drop + curl)
                    let k = settle * min(1, dt * 5)
                    let dx = (tx - tail[i].x) * k, dy = (ty - tail[i].y) * k
                    tail[i].x += dx; tail[i].y += dy
                    tailPrev[i].x += dx; tailPrev[i].y += dy   // no velocity injection
                }
            }
        }
        // Constraint passes keep segment lengths.
        for _ in 0..<3 {
            for i in 1..<tail.count {
                let d = tail[i] - tail[i - 1]
                let len = max(0.001, sqrt(hypot2(d)))
                let corr = (len - seg) / len
                if i == 1 {
                    tail[i] = tail[i] - d * corr
                } else {
                    tail[i - 1] = tail[i - 1] + d * (corr * 0.5)
                    tail[i] = tail[i] - d * (corr * 0.5)
                }
            }
        }
    }

    // MARK: Morph outline — ONE cat, continuously deformed
    //
    // Every state targets a traced reference outline (all in the same shared,
    // area-normalized, index-aligned space — see KiddyCatTraced). The rendered
    // shape is a single point array that eases toward the active target every
    // frame: state changes are smooth shape morphs, never jump cuts, and the
    // silhouette can never change size or style between movement modes.
    private var morph: [(CGFloat, CGFloat)] = []
    private var morphSettle: CGFloat = 0     // 1 when the shape has reached its pose

    private func targetOutline() -> [(CGFloat, CGFloat)] {
        switch state {
        case .idle, .startle: return KiddyCatTraced.stand
        case .sit, .groom:    return KiddyCatTraced.sit
        case .lie:            return KiddyCatTraced.loaf
        case .stretch, .play: return KiddyCatTraced.play
        case .eat:            return KiddyCatTraced.eat
        case .stalk, .pounceWindup, .land: return KiddyCatTraced.prowl
        case .pounceAir:      return KiddyCatTraced.leap
        case .walk, .trot:
            // Ping-pong between the two walk keyframes, locked to the gait clock.
            let ph = gaitPhase.truncatingRemainder(dividingBy: 1)
            let tt = ph < 0.5 ? ph * 2 : 2 - ph * 2
            return zip(KiddyCatTraced.walkA, KiddyCatTraced.walkB).map {
                ($0.0 + ($1.0 - $0.0) * tt, $0.1 + ($1.1 - $0.1) * tt)
            }
        }
    }

    private func updateMorph(dt: CGFloat) {
        let target = targetOutline()
        if morph.count != target.count { morph = target }
        var total: CGFloat = 0
        for i in 0..<morph.count {
            total += abs(target[i].0 - morph[i].0) + abs(target[i].1 - morph[i].1)
        }
        let avg = total / CGFloat(morph.count)
        // Far from the pose → deliberate morph (~0.3s). Near → tight tracking,
        // so the walk cycle's fast keyframe motion isn't low-pass blurred away.
        let k = min(1, dt * (avg < 0.08 ? 22 : 8))
        for i in 0..<morph.count {
            morph[i].0 += (target[i].0 - morph[i].0) * k
            morph[i].1 += (target[i].1 - morph[i].1) * k
        }
        morphSettle = max(0, min(1, (0.10 - avg) / 0.07))
    }

    // MARK: Pose

    // A pose in cat-local units (x forward, y up from the ground anchor; 1 = size).
    struct Pose {
        var shoulderHeight: CGFloat = 0.92
        var rumpHeight: CGFloat = 0.95
        var backArch: CGFloat = 0          // extra mid-spine lift
        var bodyStretch: CGFloat = 0       // lengthens the torso (stretch pose)
        var headHeight: CGFloat = 1.14
        var headForward: CGFloat = 0.88
        var crouch: CGFloat = 0            // 0…1 compresses everything
        var sitFold: CGFloat = 0           // 0…1 rear folded to the ground
        var frontLegBend: CGFloat = 0
        var rearLegBend: CGFloat = 0
        var earPerk: CGFloat = 0.75
    }

    private func statePose() -> Pose {
        var p = Pose()
        switch state {
        case .idle:
            p.earPerk = 0.72
        case .sit, .groom:
            // The royal sit: tall vertical chest over straight front legs, haunches
            // rounded behind, head high (groom: head dipped to the chest).
            p.sitFold = 1
            p.rumpHeight = 0.52
            p.shoulderHeight = 1.10
            p.headHeight = state == .groom ? 0.92 : 1.38
            p.headForward = state == .groom ? 0.42 : 0.5
            p.earPerk = state == .groom ? 0.45 : 0.8
        case .stretch:
            // Play-bow: chest to the ground, rump high.
            p.shoulderHeight = 0.4
            p.rumpHeight = 1.05
            p.bodyStretch = 0.35
            p.headHeight = 0.62
            p.headForward = 1.25
            p.frontLegBend = 0.8
        case .walk:
            p.backArch = 0.03
        case .trot:
            p.backArch = 0.05
            p.shoulderHeight = 0.86
        case .lie:
            // The loaf: a smooth chunky mound, head up, everything tucked.
            p.shoulderHeight = 0.70
            p.rumpHeight = 0.72
            p.headHeight = 0.98
            p.headForward = 0.55
            p.crouch = 0.55
            p.earPerk = 0.55
        case .stalk:
            p.crouch = 0.55
            p.headHeight = 0.72
            p.headForward = 1.2
            p.earPerk = 1
        case .pounceWindup:
            p.crouch = 0.75
            p.rumpHeight = 0.62
            p.headHeight = 0.68
            p.headForward = 1.15
            p.earPerk = 1
        case .pounceAir:
            // Gentle rising bound: slight diagonal, head forward with the arc.
            p.bodyStretch = 0.45
            p.backArch = -0.05
            p.shoulderHeight = 1.06
            p.rumpHeight = 0.84
            p.headForward = 1.30
            p.headHeight = 1.18
            p.frontLegBend = -0.5      // reaching
            p.rearLegBend = -0.6
        case .play:
            // Batting crouch: chest low over the toy, head down watching it.
            p.crouch = 0.45
            p.shoulderHeight = 0.72
            p.headHeight = 0.66
            p.headForward = 1.05
            p.earPerk = 1
        case .eat:
            // Hunched over the bowl: mound back, head dropped to the ground.
            p.crouch = 0.6
            p.shoulderHeight = 0.78
            p.rumpHeight = 0.66
            p.headHeight = 0.45
            p.headForward = 0.95
            p.earPerk = 0.4
        case .land:
            p.crouch = 0.5
            p.headHeight = 0.85
        case .startle:
            p.backArch = 0.3           // Halloween arch
            p.crouch = 0.15
            p.shoulderHeight = 0.95
            p.rumpHeight = 0.98
            p.headHeight = 1.0
            p.earPerk = 0.15           // ears flat
        }
        return p
    }

    private func lerp(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        var r = Pose()
        r.shoulderHeight = m(a.shoulderHeight, b.shoulderHeight)
        r.rumpHeight = m(a.rumpHeight, b.rumpHeight)
        r.backArch = m(a.backArch, b.backArch)
        r.bodyStretch = m(a.bodyStretch, b.bodyStretch)
        r.headHeight = m(a.headHeight, b.headHeight)
        r.headForward = m(a.headForward, b.headForward)
        r.crouch = m(a.crouch, b.crouch)
        r.sitFold = m(a.sitFold, b.sitFold)
        r.frontLegBend = m(a.frontLegBend, b.frontLegBend)
        r.rearLegBend = m(a.rearLegBend, b.rearLegBend)
        r.earPerk = m(a.earPerk, b.earPerk)
        return r
    }

    private func currentPose() -> Pose {
        var p = lerp(prevPose, statePose(), blend * blend * (3 - 2 * blend))
        // Breathing + gait bob layered on top.
        let breath = CGFloat(sin(now * 1.9)) * 0.012
        p.shoulderHeight += breath
        p.rumpHeight += breath * 0.6
        if abs(speed) > 1 {
            let bob = CGFloat(sin(Double(gaitPhase) * 2 * .pi * 2)) * 0.02
            p.shoulderHeight += bob
            p.rumpHeight -= bob * 0.7
        }
        let squash = p.crouch
        p.shoulderHeight *= (1 - squash * 0.45)
        p.rumpHeight *= (1 - squash * 0.4)
        p.headHeight *= (1 - squash * 0.3)
        return p
    }

    // MARK: Draw

    func draw(into ctx: CGContext, origin: CGPoint, inkW w: CGFloat) {
        if style == .model3d, let r3d = renderer3D {
            r3d.draw(into: ctx, origin: origin, pos: pos, groundY: groundY, size: size, now: now)
            return
        }
        if style == .pixel { drawPixel(into: ctx, origin: origin); return }
        if style == .arcade { drawArcade(into: ctx, origin: origin, inkW: w); return }
        drawSilhouette(into: ctx, origin: origin, inkW: w)
    }

    // Colors adapt: ink cat on light pixels, warm silver cat on dark.
    // MARK: 8-bit style — authored sprite frames, chosen by the shared brain.
    // The rig still drives everything (position, facing, gait phase, blink, states);
    // the pixel style just quantizes it into discrete frames on a crisp integer grid.

    private func pixelFrame() -> (String, [String]) {
        switch state {
        case .walk, .trot:
            let frames = [KiddyCatPixel.walk1, KiddyCatPixel.walk2, KiddyCatPixel.walk3, KiddyCatPixel.walk4]
            let i = min(3, max(0, Int(gaitPhase * 4)))
            return ("walk\(i)", frames[i])
        case .sit, .groom:
            return blinkPhase > 0.4 ? ("sit2", KiddyCatPixel.sit2) : ("sit1", KiddyCatPixel.sit1)
        case .stalk, .pounceWindup:
            let i = min(1, max(0, Int(gaitPhase * 2)))
            return i == 0 ? ("stalk1", KiddyCatPixel.stalk1) : ("stalk2", KiddyCatPixel.stalk2)
        case .pounceAir:
            return ("pounce", KiddyCatPixel.pounce)
        case .land:
            return ("stalk1", KiddyCatPixel.stalk1)   // compressed crouch on touchdown
        case .stretch:
            return ("stretch", KiddyCatPixel.stretch)
        case .startle:
            return ("startle", KiddyCatPixel.startle)
        default:
            return blinkPhase > 0.4 ? ("idle2", KiddyCatPixel.idle2) : ("idle1", KiddyCatPixel.idle1)
        }
    }

    private func drawPixel(into ctx: CGContext, origin: CGPoint) {
        let (key, rows) = pixelFrame()
        let img = KiddyCatPixel.image(key, rows)
        // Integer scale + integer screen coords + interpolation OFF = crisp pixels.
        let scale = max(3, (size / 11).rounded())
        let w = CGFloat(img.width) * scale
        let h = CGFloat(img.height) * scale
        let x = (pos.x - origin.x).rounded()
        // Classic gait bob: passing frames ride one pixel higher than contact frames.
        let bob: CGFloat = (key == "walk1" || key == "walk3") ? scale : 0
        let y = (pos.y - origin.y).rounded() + bob
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.normal); ctx.setAlpha(1)
        ctx.translateBy(x: x, y: y)
        if facing < 0 { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    // MARK: Silhouette spline helpers

    // Smooth curve through points (Catmull-Rom converted to cubic Béziers) —
    // professional silhouettes are continuous curvature, not welded primitives.
    private static func catmull(_ pts: [CGPoint], closed: Bool) -> CGMutablePath {
        let path = CGMutablePath()
        let n = pts.count
        guard n >= 3 else { return path }
        path.move(to: pts[0])
        let segs = closed ? n : n - 1
        for i in 0..<segs {
            let p0 = pts[closed ? (i - 1 + n) % n : max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[closed ? (i + 2) % n : min(n - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    // A filled tapered tube along a centerline: per-point widths, smooth sides,
    // rounded tip. Replaces stroked segments (which bulge at width steps).
    private static func ribbon(_ center: [CGPoint], _ widths: [CGFloat]) -> CGMutablePath {
        let n = center.count
        guard n >= 2 else { return CGMutablePath() }
        var left = [CGPoint](); var right = [CGPoint]()
        left.reserveCapacity(n); right.reserveCapacity(n)
        for i in 0..<n {
            let a = center[max(0, i - 1)], b = center[min(n - 1, i + 1)]
            var tx = b.x - a.x, ty = b.y - a.y
            let len = max(0.0001, sqrt(tx * tx + ty * ty))
            tx /= len; ty /= len
            let hw = widths[i] / 2
            left.append(CGPoint(x: center[i].x - ty * hw, y: center[i].y + tx * hw))
            right.append(CGPoint(x: center[i].x + ty * hw, y: center[i].y - tx * hw))
        }
        // Rounded tip: extend past the last point along the tangent.
        let a = center[n - 2], b = center[n - 1]
        var tx = b.x - a.x, ty = b.y - a.y
        let len = max(0.0001, sqrt(tx * tx + ty * ty))
        tx /= len; ty /= len
        let tip = CGPoint(x: b.x + tx * widths[n - 1] * 0.55, y: b.y + ty * widths[n - 1] * 0.55)
        return catmull(left + [tip] + right.reversed(), closed: true)
    }

    private func drawSilhouette(into ctx: CGContext, origin: CGPoint, inkW w: CGFloat) {
        let s = size
        let f = facing
        let gx = pos.x - origin.x
        let gy = pos.y - origin.y

        let bodyColor = blendColor(NSColor(srgbRed: 0.75, green: 0.72, blue: 0.7, alpha: 1),
                                   NSColor(srgbRed: 0.07, green: 0.06, blue: 0.08, alpha: 1), 0.25 + 0.75 * w)
        @inline(__always) func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: gx + x * f * s, y: gy + y * s)
        }

        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
        ctx.setLineCap(.round)
        let accent = NSColor(white: 0.05 + 0.90 * w, alpha: 0.85)
        let eyeOpen = 1 - blinkPhase

        // Front face renderer (shared by parametric and traced heads).
        func frontFace(_ fcx: CGFloat, _ fcy: CGFloat, _ fhw: CGFloat, _ fhh: CGFloat,
                       sleepy: Bool = false) {
            let fy = headPitch * 0.05
            ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(s * 0.017)
            for side: CGFloat in [-1, 1] {
                for (dy, len) in [(CGFloat(0.02), CGFloat(0.22)), (CGFloat(-0.05), CGFloat(0.26)), (CGFloat(-0.12), CGFloat(0.21))] {
                    ctx.beginPath()
                    ctx.move(to: P(fcx + side * fhw * 0.55, fcy + fy - 0.10 + dy * 0.5))
                    ctx.addLine(to: P(fcx + side * (fhw * 0.55 + len), fcy + fy - 0.10 + dy))
                    ctx.strokePath()
                }
            }
            for side: CGFloat in [-1, 1] {
                ctx.beginPath()
                ctx.move(to: P(fcx + side * fhw * 0.44, fcy + fhh * 0.68))
                ctx.addLine(to: P(fcx + side * fhw * 0.70, fcy + fhh * 1.08))
                ctx.strokePath()
            }
            if sleepy {
                // Content closed eyes (the sheet's loafing cat is asleep): two ∩ arcs.
                ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
                ctx.setLineWidth(s * 0.026)
                for side: CGFloat in [-1, 1] {
                    let e = P(fcx + side * fhw * 0.40, fcy + fy + fhh * 0.10)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: e.x - s * 0.062 * f, y: e.y - s * 0.012))
                    ctx.addQuadCurve(to: CGPoint(x: e.x + s * 0.062 * f, y: e.y - s * 0.012),
                                     control: CGPoint(x: e.x, y: e.y + s * 0.075))
                    ctx.strokePath()
                }
            } else if eyeOpen > 0.08 {
                let ew = s * 0.062, eh = s * 0.078 * eyeOpen
                for side: CGFloat in [-1, 1] {
                    let e = P(fcx + side * fhw * 0.40, fcy + fy + fhh * 0.10)
                    ctx.setFillColor(accent.withAlphaComponent(0.95).cgColor)
                    ctx.fillEllipse(in: CGRect(x: e.x - ew, y: e.y - eh, width: ew * 2, height: eh * 2))
                    ctx.setFillColor(bodyColor.cgColor)
                    ctx.fillEllipse(in: CGRect(x: e.x - ew * 0.30, y: e.y - eh * 0.48, width: ew * 0.60, height: eh * 0.96))
                    ctx.fillEllipse(in: CGRect(x: e.x - ew * 1.1, y: e.y + eh * 0.58, width: ew * 2.2, height: eh * 1.2))
                }
            }
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            let np = P(fcx, fcy + fy - fhh * 0.34)
            let nw = s * 0.045
            let nose = CGMutablePath()
            nose.move(to: CGPoint(x: np.x - nw, y: np.y + nw * 0.7))
            nose.addLine(to: CGPoint(x: np.x + nw, y: np.y + nw * 0.7))
            nose.addLine(to: CGPoint(x: np.x, y: np.y - nw * 0.8))
            nose.closeSubpath()
            ctx.addPath(nose)
            ctx.fillPath()
            ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(s * 0.016)
            let mc = P(fcx, fcy + fy - fhh * 0.52)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: mc.x, y: mc.y + s * 0.05))
            ctx.addLine(to: CGPoint(x: mc.x, y: mc.y + s * 0.015))
            ctx.move(to: CGPoint(x: mc.x, y: mc.y + s * 0.015))
            ctx.addQuadCurve(to: CGPoint(x: mc.x - s * 0.075, y: mc.y + s * 0.035),
                             control: CGPoint(x: mc.x - s * 0.045, y: mc.y - s * 0.02))
            ctx.move(to: CGPoint(x: mc.x, y: mc.y + s * 0.015))
            ctx.addQuadCurve(to: CGPoint(x: mc.x + s * 0.075, y: mc.y + s * 0.035),
                             control: CGPoint(x: mc.x + s * 0.045, y: mc.y - s * 0.02))
            ctx.strokePath()
        }

        // --- The one body: the continuously-morphing traced outline, plus a
        // whisper of breath so a settled cat is never frozen.
        let breathe = 1 + 0.006 * CGFloat(sin(now * 2.1)) * morphSettle
        let pts = morph.map { P(-$0.0, $0.1 * breathe) }
        ctx.setFillColor(bodyColor.cgColor)
        ctx.addPath(Self.catmull(pts, closed: true))
        ctx.fillPath()

        // Pose dressing — the reference's own accents, faces, and props —
        // fades in once the morph has arrived, out as it departs.
        guard morphSettle > 0.02 else { ctx.setAlpha(1); return }
        ctx.setAlpha(morphSettle)
        func strokeAccents(_ accents: [[(CGFloat, CGFloat)]]) {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(s * 0.028)
            for stroke in accents {
                ctx.addPath(Self.catmull(stroke.map { P(-$0.0, $0.1) }, closed: false))
                ctx.strokePath()
            }
        }
        func fillProps(_ props: [[(CGFloat, CGFloat)]]) {
            ctx.setFillColor(bodyColor.cgColor)
            for prop in props {
                ctx.addPath(Self.catmull(prop.map { P(-$0.0, $0.1) }, closed: true))
                ctx.fillPath()
            }
        }
        func profileEye(_ e: (CGFloat, CGFloat), closed: Bool) {
            let p = P(-e.0, e.1)
            if closed {
                ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(s * 0.024)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: p.x - s * 0.05 * f, y: p.y + s * 0.012))
                ctx.addQuadCurve(to: CGPoint(x: p.x + s * 0.05 * f, y: p.y + s * 0.012),
                                 control: CGPoint(x: p.x, y: p.y - s * 0.055))
                ctx.strokePath()
            } else {
                ctx.setFillColor(accent.withAlphaComponent(0.95).cgColor)
                let ew = s * 0.055, eh = s * 0.038
                ctx.fillEllipse(in: CGRect(x: p.x - ew, y: p.y - eh, width: ew * 2, height: eh * 2))
                ctx.setFillColor(bodyColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - ew * 0.35, y: p.y - eh * 0.8, width: ew * 0.7, height: eh * 1.6))
            }
        }
        switch state {
        case .idle, .startle:
            strokeAccents(KiddyCatTraced.standAccents)
            let ff = KiddyCatTraced.standFace
            frontFace(-ff.0, ff.1, ff.2, ff.2 * 0.88)
        case .sit, .groom:
            strokeAccents(KiddyCatTraced.sitAccents)
            let ff = KiddyCatTraced.sitFace
            frontFace(-ff.0, ff.1, ff.2, ff.2 * 0.88)
        case .lie:
            strokeAccents(KiddyCatTraced.loafAccents)
            let ff = KiddyCatTraced.loafFace
            frontFace(-ff.0, ff.1, ff.2, ff.2 * 0.88, sleepy: true)
        case .play:
            fillProps(KiddyCatTraced.playProps)
            profileEye(KiddyCatTraced.playEye, closed: false)
        case .eat:
            fillProps(KiddyCatTraced.eatProps)
            strokeAccents(KiddyCatTraced.eatAccents)
            profileEye(KiddyCatTraced.eatEye, closed: true)
        default:
            break
        }
        ctx.setAlpha(1)
    }


    // MARK: Arcade style — chunky chibi mascot: big head, big tracking eye, bold
    // outlines, squash & stretch. Same pose anchors as the silhouette.
    private func drawArcade(into ctx: CGContext, origin: CGPoint, inkW w: CGFloat) {
        let pose = currentPose()
        let s = size
        let f = facing
        let gx = pos.x - origin.x
        let gy = pos.y - origin.y

        // Palette: orange tabby with a cream chest, dark chocolate outline.
        let fur = NSColor(srgbRed: 0.99, green: 0.62, blue: 0.24, alpha: 1)
        let furShade = NSColor(srgbRed: 0.9, green: 0.5, blue: 0.17, alpha: 1)
        let cream = NSColor(srgbRed: 1.0, green: 0.94, blue: 0.82, alpha: 1)
        let outline = NSColor(srgbRed: 0.28, green: 0.16, blue: 0.1, alpha: 1)
        let pink = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.66, alpha: 1)
        let lineW = s * 0.055

        @inline(__always) func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: gx + x * f * s, y: gy + y * s)
        }
        func fillStroke(_ path: CGPath, _ fill: NSColor) {
            ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(outline.cgColor); ctx.setLineWidth(lineW); ctx.strokePath()
        }

        // Squash & stretch: arcade exaggeration on top of the pose.
        let squash = 1 - pose.crouch * 0.3 + pose.bodyStretch * 0.2
        let shoulderX: CGFloat = (0.44 - pose.sitFold * 0.22)
        let rumpX: CGFloat = -0.5
        let shoulderY = pose.shoulderHeight * 0.82 * squash
        let rumpY = pose.rumpHeight * 0.82 * squash
        let headX = pose.headForward * 0.58
        let headY = (pose.headHeight * 0.92 + 0.04) * squash
        let stride = strideLength()

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)

        // --- Tail: fat outlined rope with the same verlet points ---
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: tail[0].x - origin.x, y: tail[0].y - origin.y))
        for i in 1..<tail.count {
            tailPath.addLine(to: CGPoint(x: tail[i].x - origin.x, y: tail[i].y - origin.y))
        }
        ctx.addPath(tailPath); ctx.setStrokeColor(outline.cgColor); ctx.setLineWidth(s * 0.3); ctx.strokePath()
        ctx.addPath(tailPath); ctx.setStrokeColor(fur.cgColor); ctx.setLineWidth(s * 0.3 - lineW * 2); ctx.strokePath()

        // --- Legs (far pair shaded) ---
        func leg(front: Bool, far: Bool) {
            let legIdx = (front ? 0 : 2) + (far ? 1 : 0)
            let rootX = front ? shoulderX - 0.02 : rumpX + 0.12
            let rootY = front ? shoulderY - 0.1 : rumpY - 0.08
            var footX = rootX
            var footY: CGFloat = 0
            if pose.sitFold > 0.5 && !front {
                footX = rootX + 0.3; footY = 0
            } else {
                let (dx, lift) = footOffset(legIdx, stride: stride / s)
                footX = rootX + dx
                footY = lift / s
                if state == .pounceAir { footX = rootX + (front ? 0.3 : -0.26); footY = 0.24 }
            }
            let path = CGMutablePath()
            path.move(to: P(rootX, rootY))
            path.addQuadCurve(to: P(footX, footY + 0.05),
                              control: P((rootX + footX) / 2 + (front ? -0.06 : 0.1), (rootY + footY) / 2))
            ctx.addPath(path); ctx.setStrokeColor(outline.cgColor); ctx.setLineWidth(s * 0.3); ctx.strokePath()
            ctx.addPath(path); ctx.setStrokeColor((far ? furShade : fur).cgColor)
            ctx.setLineWidth(s * 0.3 - lineW * 2); ctx.strokePath()
        }
        leg(front: true, far: true)
        leg(front: false, far: true)

        // --- Body: one plump bean ---
        let body = CGMutablePath()
        let midTop = max(shoulderY, rumpY) + 0.16 + pose.backArch
        let belly: CGFloat = 0.2 - pose.crouch * 0.1   // high enough that legs SHOW
        body.move(to: P(rumpX - 0.18, rumpY * 0.5))
        body.addQuadCurve(to: P((rumpX + shoulderX) / 2, midTop), control: P(rumpX - 0.26, rumpY + 0.18))
        // Chest rises to tuck UNDER the skull — head and body must overlap, never gap.
        body.addQuadCurve(to: P(headX + 0.1, headY - 0.1), control: P(shoulderX + 0.26, shoulderY + 0.1))
        body.addQuadCurve(to: P(shoulderX + 0.1, belly), control: P(headX + 0.02, belly + 0.1))
        body.addQuadCurve(to: P(rumpX - 0.18, rumpY * 0.5), control: P(rumpX * 0.4, belly - 0.06))
        body.closeSubpath()
        fillStroke(body, fur)

        // Cream chest patch.
        let chest = CGMutablePath()
        chest.addEllipse(in: CGRect(x: P(shoulderX - 0.04, 0.02).x - s * 0.19 * f,
                                    y: P(0, 0.02).y, width: s * 0.38, height: s * (shoulderY * 0.62)))
        ctx.addPath(chest); ctx.setFillColor(cream.cgColor); ctx.fillPath()

        // --- Near legs over the body ---
        leg(front: true, far: false)
        leg(front: false, far: false)

        // --- Head: BIG circle with ears, face, whiskers ---
        let hp = headPitch
        let R: CGFloat = 0.46
        let hcx = headX, hcy = headY + hp * 0.2
        let headC = P(hcx, hcy)
        let Rs = R * s

        // Ears first (behind the head): outlined triangles with pink inner.
        let earLen = R * (0.55 + 0.45 * pose.earPerk)
        let flick = earFlick * 0.1
        func ear(_ baseA: CGFloat, _ tipA: CGFloat) {
            let e = CGMutablePath()
            let a1 = baseA - 0.4, a2 = baseA + 0.4
            e.move(to: P(hcx + cos(a1) * R * 0.9, hcy + sin(a1) * R * 0.9))
            e.addLine(to: P(hcx + cos(tipA) * (R * 0.72 + earLen), hcy + sin(tipA) * (R * 0.72 + earLen)))
            e.addLine(to: P(hcx + cos(a2) * R * 0.9, hcy + sin(a2) * R * 0.9))
            e.closeSubpath()
            fillStroke(e, fur)
            // Pink inner ear.
            let inner = CGMutablePath()
            let m1 = baseA - 0.2, m2 = baseA + 0.2
            inner.move(to: P(hcx + cos(m1) * R * 0.88, hcy + sin(m1) * R * 0.88))
            inner.addLine(to: P(hcx + cos(tipA) * (R * 0.72 + earLen * 0.62), hcy + sin(tipA) * (R * 0.72 + earLen * 0.62)))
            inner.addLine(to: P(hcx + cos(m2) * R * 0.88, hcy + sin(m2) * R * 0.88))
            inner.closeSubpath()
            ctx.addPath(inner); ctx.setFillColor(pink.cgColor); ctx.fillPath()
        }
        ear(2.25, 2.35 + flick)
        ear(0.92, 0.8)

        // Skull.
        let skull = CGMutablePath()
        skull.addEllipse(in: CGRect(x: headC.x - Rs, y: headC.y - Rs, width: Rs * 2, height: Rs * 2))
        fillStroke(skull, fur)

        // Cream muzzle patch (lower front of the face).
        let mz = P(hcx + R * 0.42, hcy - R * 0.34)
        ctx.setFillColor(cream.cgColor)
        ctx.fillEllipse(in: CGRect(x: mz.x - Rs * 0.42, y: mz.y - Rs * 0.3, width: Rs * 0.84, height: Rs * 0.6))

        // Big eye with a pupil that TRACKS the interest point (instant charm).
        let eyeOpen = 1 - blinkPhase
        let ec = P(hcx + R * 0.3, hcy + R * 0.18)
        let ew = Rs * 0.3, eh = Rs * 0.34 * max(0.12, eyeOpen)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: ec.x - ew, y: ec.y - eh, width: ew * 2, height: eh * 2))
        ctx.setStrokeColor(outline.cgColor); ctx.setLineWidth(lineW * 0.8)
        ctx.strokeEllipse(in: CGRect(x: ec.x - ew, y: ec.y - eh, width: ew * 2, height: eh * 2))
        if eyeOpen > 0.15 {
            var px: CGFloat = 0, py: CGFloat = 0
            if let i = interest {
                let dx = (i.x - pos.x) * facing, dy = i.y - pos.y - size
                let m = max(60, sqrt(dx * dx + dy * dy))
                px = dx / m * ew * 0.35; py = dy / m * eh * 0.3
            }
            let pr = ew * 0.52
            ctx.setFillColor(outline.cgColor)
            ctx.fillEllipse(in: CGRect(x: ec.x + px * f - pr, y: ec.y + py - pr * 1.25,
                                       width: pr * 2, height: pr * 2.5))
            // Sparkle.
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: ec.x + px * f - pr * 0.3, y: ec.y + py + pr * 0.3,
                                       width: pr * 0.55, height: pr * 0.55))
        }

        // Nose + whiskers.
        let nose = P(hcx + R * 0.78, hcy - R * 0.08)
        ctx.setFillColor(pink.cgColor)
        ctx.fillEllipse(in: CGRect(x: nose.x - Rs * 0.08, y: nose.y - Rs * 0.06, width: Rs * 0.16, height: Rs * 0.12))
        ctx.setStrokeColor(outline.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(lineW * 0.55)
        for (dy, tilt) in [(0.02, 0.1), (-0.08, 0.0), (-0.18, -0.1)] {
            ctx.beginPath()
            ctx.move(to: P(hcx + R * 0.62, hcy - R * 0.18 + dy))
            ctx.addLine(to: P(hcx + R * 1.5, hcy - R * 0.18 + dy + tilt))
            ctx.strokePath()
        }
        ctx.setAlpha(1)
    }
}
