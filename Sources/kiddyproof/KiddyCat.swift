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

    enum State: String {
        case idle, sit, groom, stretch, walk, trot, stalk, pounceWindup, pounceAir, land, startle
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
        let seg = size * 0.16
        tail = (0..<9).map { i in NSPoint(x: p.x - size * 0.9 - CGFloat(i) * seg, y: groundY + size * 0.55) }
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
        case .walk: targetSpeed = size * 2.2
        case .trot: targetSpeed = size * 4.4
        case .stalk: targetSpeed = size * 1.1
        case .pounceWindup: targetSpeed = 0
        case .pounceAir: break
        default: targetSpeed = 0
        }
    }

    func face(_ dir: CGFloat) { facing = dir >= 0 ? 1 : -1 }

    // Launch at a world point (harness decides when).
    func pounce(at target: NSPoint) {
        pounceTarget = target
        set(state: .pounceWindup)
    }

    func startle() {
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
        case .walk, .trot: return (0.75, 1.0)             // raised, confident
        case .startle, .pounceAir: return (1.1, 0)        // bottle-brush up
        case .sit, .groom: return (0.1, 0.4)              // wrapped low
        default: return (0.4, 0.6)
        }
    }

    private func updateTail(dt: CGFloat) {
        let pose = currentPose()
        let root = NSPoint(x: pos.x - facing * size * (state == .sit || state == .groom ? 0.62 : 0.92),
                           y: pos.y + size * pose.rumpHeight)
        let seg = size * 0.15
        let (lift, sway) = tailMood()
        // Verlet integrate.
        for i in 0..<tail.count {
            let cur = tail[i]
            var vel = NSPoint(x: (cur.x - tailPrev[i].x) * 0.92, y: (cur.y - tailPrev[i].y) * 0.92)
            // Gravity vs the mood's lift; the tip sways with an idle wave.
            let t = CGFloat(i) / CGFloat(tail.count - 1)
            vel.y += (lift * t * size * 5.2 - size * 2.2) * dt * dt * 60
            vel.x += CGFloat(sin(now * (1.3 + Double(sway)) + Double(t) * 2.6)) * sway * t * size * 0.5 * dt
            tailPrev[i] = cur
            tail[i] = cur + vel
            // The tail never drags through the floor.
            if tail[i].y < groundY + size * 0.08 { tail[i].y = groundY + size * 0.08 }
        }
        tail[0] = root
        tailPrev[0] = root
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
            p.rumpHeight = 0.46
            p.shoulderHeight = 1.0
            p.headHeight = state == .groom ? 0.92 : 1.3
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
            p.bodyStretch = 0.45
            p.backArch = -0.05
            p.headForward = 1.3
            p.headHeight = 1.1
            p.frontLegBend = -0.5      // reaching
            p.rearLegBend = -0.6
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

    // Colors adapt: ink cat on light pixels, warm silver cat on dark.
    func draw(into ctx: CGContext, origin: CGPoint, inkW w: CGFloat) {
        let pose = currentPose()
        let s = size
        let f = facing
        let gx = pos.x - origin.x
        let gy = pos.y - origin.y

        let bodyColor = blendColor(NSColor(srgbRed: 0.75, green: 0.72, blue: 0.7, alpha: 1),
                                   NSColor(srgbRed: 0.07, green: 0.06, blue: 0.08, alpha: 1), 0.25 + 0.75 * w)
        let farColor = blendColor(bodyColor, NSColor(white: 0.5 * (1 - w), alpha: 1), 0.3)

        @inline(__always) func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: gx + x * f * s, y: gy + y * s)
        }

        // Anchor geometry.
        let stretch = pose.bodyStretch
        let shoulderX: CGFloat = 0.52 + stretch * 0.25 - pose.sitFold * 0.3
        let rumpX: CGFloat = -(0.62 + stretch * 0.2)
        let shoulderY = pose.shoulderHeight
        let rumpY = pose.rumpHeight
        let headX = pose.headForward + stretch * 0.2
        let headY = pose.headHeight
        let stride = strideLength()

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)

        // --- Legs (far pair first, faded, phase-shifted) ---
        func drawLeg(front: Bool, far: Bool) {
            let legIdx = (front ? 0 : 2) + (far ? 1 : 0)
            let rootX = front ? shoulderX - 0.06 : rumpX + 0.1
            let rootY = front ? shoulderY - 0.12 : rumpY - 0.1
            var footX = rootX
            var footY: CGFloat = 0
            if pose.sitFold > 0.5 && !front {
                // Folded haunch: foot tucks forward under the body.
                footX = rootX + 0.34
                footY = 0
            } else {
                let (dx, lift) = footOffset(legIdx, stride: stride / s)
                footX = rootX + dx
                footY = lift / s
                if state == .pounceAir {
                    footX = rootX + (front ? 0.35 : -0.3)
                    footY = 0.28
                }
            }
            // Two-segment limb via a quad control point: front knees bend backward,
            // rear hocks bend forward (side-view cat anatomy).
            let midX = (rootX + footX) / 2 + (front ? -0.1 : 0.14) * (1 - pose.sitFold)
            let midY = (rootY + footY) / 2 + 0.02
            let path = CGMutablePath()
            path.move(to: P(rootX, rootY))
            path.addQuadCurve(to: P(footX, footY + 0.03), control: P(midX, midY))
            ctx.setStrokeColor((far ? farColor : bodyColor).cgColor)
            ctx.setLineWidth(s * (front ? 0.23 : 0.26))
            ctx.addPath(path)
            ctx.strokePath()
            // Paw.
            ctx.setFillColor((far ? farColor : bodyColor).cgColor)
            let pw = s * 0.125
            let pp = P(footX + 0.05, footY + 0.045)
            ctx.fillEllipse(in: CGRect(x: pp.x - pw, y: pp.y - pw * 0.8, width: pw * 2, height: pw * 1.6))
        }
        drawLeg(front: true, far: true)
        drawLeg(front: false, far: true)

        // Rear haunch (thigh mass) behind the body fill so the back leg reads
        // muscled — a cat's rear is its engine, not a wire.
        do {
            let hq = P(rumpX + 0.12, rumpY * 0.55)
            let hw = s * 0.34, hh = s * 0.42 * (1 - pose.sitFold * 0.15)
            ctx.setFillColor(farColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: hq.x - hw, y: hq.y - hh, width: hw * 2, height: hh * 2))
        }

        // --- Tail (behind the body) ---
        ctx.setStrokeColor(bodyColor.cgColor)
        for i in 1..<tail.count {
            let t = CGFloat(i) / CGFloat(tail.count - 1)
            // A cat's tail is FAT — thick at the base, still plush at the tip
            // (a thin taper reads instantly as a rat).
            ctx.setLineWidth(s * (0.24 - 0.09 * t))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: tail[i - 1].x - origin.x, y: tail[i - 1].y - origin.y))
            ctx.addLine(to: CGPoint(x: tail[i].x - origin.x, y: tail[i].y - origin.y))
            ctx.strokePath()
        }

        // --- Body silhouette: ONE smooth flowing outline (reference silhouettes are
        // a single unbroken curve — multi-segment waviness reads hand-drawn-badly).
        let body = CGMutablePath()
        let spineTopY = max(shoulderY, rumpY) + 0.14 + pose.backArch
        body.move(to: P(rumpX - 0.14, rumpY - 0.3))                        // under the tail
        body.addQuadCurve(to: P((rumpX + shoulderX) / 2, spineTopY),       // rump → spine crest
                          control: P(rumpX - 0.16, rumpY + 0.22 + pose.backArch * 0.6))
        body.addQuadCurve(to: P(shoulderX + 0.14, shoulderY - 0.02),       // crest → neck base
                          control: P(shoulderX + 0.06, shoulderY + 0.16 + pose.backArch * 0.4))
        // Throat → deep chest → belly → close.
        body.addQuadCurve(to: P(shoulderX + 0.1, shoulderY - 0.42),
                          control: P(shoulderX + 0.2, shoulderY - 0.22))
        body.addQuadCurve(to: P(rumpX + 0.14, rumpY - 0.32 - pose.sitFold * 0.08),
                          control: P(0.08, shoulderY - 0.66 + pose.crouch * 0.12))
        body.closeSubpath()
        ctx.setFillColor(bodyColor.cgColor)
        ctx.addPath(body)
        ctx.fillPath()

        // --- Head group: a GUARANTEED-round skull (filled circle), two big triangle
        // ears, and a neck capsule joining it to the shoulders — built the way the
        // reference silhouettes are, instead of fighting one giant outline path.
        let hp = headPitch
        let R: CGFloat = 0.35                          // skull radius (size units)
        let hcx = headX + 0.02, hcy = headY + 0.02 + hp * 0.22
        let headC = P(hcx, hcy)

        // Neck capsule.
        ctx.setStrokeColor(bodyColor.cgColor)
        ctx.setLineWidth(s * 0.4)
        ctx.beginPath()
        ctx.move(to: P(shoulderX - 0.02, shoulderY - 0.14))
        ctx.addLine(to: P(hcx - R * 0.3, hcy - R * 0.3))
        ctx.strokePath()

        // Ears BEHIND the skull circle so their bases are swallowed cleanly.
        let flick = earFlick * 0.1
        let earLen = R * (0.62 + 0.5 * pose.earPerk)   // big ears — a cat signature
        func ear(baseA: CGFloat, tipA: CGFloat, tipLen: CGFloat) {
            let e = CGMutablePath()
            let a1 = baseA - 0.42, a2 = baseA + 0.42
            e.move(to: P(hcx + cos(a1) * R * 0.92, hcy + sin(a1) * R * 0.92))
            let tip = (x: hcx + cos(tipA) * (R * 0.75 + tipLen), y: hcy + sin(tipA) * (R * 0.75 + tipLen))
            // Outer edge slightly convex, inner edge straight — a real ear, not a spike.
            e.addQuadCurve(to: P(tip.x, tip.y),
                           control: P(hcx + cos(a1 + 0.16) * (R + tipLen * 0.7), hcy + sin(a1 + 0.16) * (R + tipLen * 0.7)))
            e.addLine(to: P(hcx + cos(a2) * R * 0.92, hcy + sin(a2) * R * 0.92))
            e.closeSubpath()
            ctx.addPath(e)
            ctx.fillPath()
        }
        ctx.setFillColor(bodyColor.cgColor)
        ear(baseA: 2.0, tipA: 2.05 + flick, tipLen: earLen)        // rear ear
        ear(baseA: 1.05, tipA: 0.95, tipLen: earLen)               // front ear

        // Skull.
        let Rs = R * s
        ctx.fillEllipse(in: CGRect(x: headC.x - Rs, y: headC.y - Rs, width: Rs * 2, height: Rs * 2))
        // A soft cheek/muzzle hint: one small ellipse low-front on the circle.
        let mzR = Rs * 0.34
        let mz = P(hcx + R * 0.78 * 1.0, hcy - R * 0.28)
        ctx.fillEllipse(in: CGRect(x: mz.x - mzR, y: mz.y - mzR * 0.8, width: mzR * 2, height: mzR * 1.6))

        // Sitting haunch: a rounded thigh mass over the folded rear.
        if pose.sitFold > 0.15 {
            let hx = P(rumpX + 0.16, rumpY * 0.45)
            let hr = s * 0.42 * pose.sitFold
            ctx.fillEllipse(in: CGRect(x: hx.x - hr, y: hx.y - hr * 0.95, width: hr * 2, height: hr * 1.9))
        }

        // --- Near legs over the body ---
        drawLeg(front: true, far: false)
        drawLeg(front: false, far: false)

        // --- Eye (with blink) ---
        let eyeOpen = 1 - blinkPhase
        if eyeOpen > 0.08 {
            let e = P(headX + 0.02 + 0.13, headY + 0.06 + headPitch * 0.24)
            let ew = s * 0.055, eh = s * 0.075 * eyeOpen
            ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.95, blue: 0.55, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: e.x - ew, y: e.y - eh, width: ew * 2, height: eh * 2))
            // Slit pupil.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: e.x - ew * 0.22, y: e.y - eh * 0.9, width: ew * 0.44, height: eh * 1.8))
        }
        ctx.setAlpha(1)
    }

}
