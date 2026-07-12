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
    enum Style { case silhouette, arcade, pixel }
    var style: Style = .silhouette

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
        case .startle: return (1.1, 0)                    // bottle-brush up
        case .pounceAir: return (0.2, 0)                  // streams back in flight
        case .sit, .groom: return (0.1, 0.4)              // wrapped low
        default: return (0.55, 0.6)
        }
    }

    private func updateTail(dt: CGFloat) {
        let pose = currentPose()
        let rootBack: CGFloat = style == .arcade
            ? (state == .sit || state == .groom ? 0.42 : 0.52)
            : (state == .sit || state == .groom ? 0.58 : 0.72)
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
            if state == .sit || state == .groom {
                vel.x += facing * t * t * size * 2.6 * dt * dt * 60
            }
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

    func draw(into ctx: CGContext, origin: CGPoint, inkW w: CGFloat) {
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
        func mapped(_ pts: [(CGFloat, CGFloat)]) -> [CGPoint] { pts.map { P($0.0, $0.1) } }

        // Anchor geometry.
        let stretch = pose.bodyStretch
        let shoulderX: CGFloat = 0.52 + stretch * 0.25 - pose.sitFold * 0.3
        let rumpX: CGFloat = -(0.62 + stretch * 0.2)
        let shoulderY = pose.shoulderHeight
        let rumpY = pose.rumpHeight
        let headX = pose.headForward + stretch * 0.2
        let headY = pose.headHeight
        let stride = strideLength()
        let sit = pose.sitFold

        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)

        // --- Legs: filled tapered limbs with real anatomy — wide thigh/shoulder,
        // a hock (reverse heel) on the rear leg, slim pastern, rounded paw.
        func drawLeg(front: Bool, far: Bool) {
            let legIdx = (front ? 0 : 2) + (far ? 1 : 0)
            let rootX = front ? shoulderX - 0.04 : rumpX + 0.12
            let rootY = front ? shoulderY - 0.05 : rumpY - 0.02
            var footX = rootX
            var footY: CGFloat = 0
            if sit > 0.5 && !front {
                footX = rootX + 0.36; footY = 0
            } else if sit > 0.5 && front {
                footX = rootX + sit * 0.12; footY = 0
            } else {
                let (dx, lift) = footOffset(legIdx, stride: stride / s)
                footX = rootX + dx
                footY = lift / s
                if front, pose.frontLegBend > 0 {
                    // Play-bow: forepaws reach far forward along the ground.
                    footX = rootX + pose.frontLegBend * 0.5
                    footY = 0
                }
                if state == .pounceAir {
                    // Airborne: paws gathered near the body, reaching with the arc.
                    footX = rootX + (front ? 0.52 : -0.42)
                    footY = front ? 0.58 : 0.26
                }
            }
            let color = far ? farColor : bodyColor
            ctx.setFillColor(color.cgColor)
            let path: CGMutablePath
            if front {
                // Shoulder → elbow (slightly back) → wrist → paw.
                let pts = mapped([
                    (rootX, rootY),
                    (rootX * 0.45 + footX * 0.55 - 0.015, (rootY + footY) / 2 + 0.05),
                    (footX - 0.005, footY + 0.14),
                    (footX, footY + 0.05),
                ])
                path = Self.ribbon(pts, [s * 0.25, s * 0.165, s * 0.125, s * 0.12])
            } else {
                // Hip → knee (forward) → hock (heel points BACK — the cat cue) → paw.
                let fold = 1 - sit
                let pts = mapped([
                    (rootX, rootY + 0.06),
                    (rootX * 0.4 + footX * 0.6 + 0.07 * fold, (rootY + footY) / 2 + 0.04),
                    (footX - 0.07 * fold, footY + 0.17),
                    (footX, footY + 0.05),
                ])
                path = Self.ribbon(pts, [s * 0.38, s * 0.24, s * 0.135, s * 0.125])
            }
            ctx.addPath(path)
            ctx.fillPath()
            // Paw: a soft rounded oval, slightly forward.
            let pw = s * 0.115
            let pp = P(footX + 0.055, footY + 0.045)
            ctx.fillEllipse(in: CGRect(x: pp.x - pw, y: pp.y - pw * 0.72, width: pw * 2, height: pw * 1.44))
        }
        drawLeg(front: true, far: true)
        drawLeg(front: false, far: true)

        // --- Tail: one smooth tapered ribbon over the verlet chain — plush base,
        // soft tip, no segment bulges.
        do {
            let pts = tail.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            let n = pts.count
            let widths = (0..<n).map { i -> CGFloat in
                let t = CGFloat(i) / CGFloat(n - 1)
                return s * (0.175 - 0.075 * t * t)
            }
            ctx.setFillColor(bodyColor.cgColor)
            ctx.addPath(Self.ribbon(pts, widths))
            ctx.fillPath()
        }

        // --- Body + head: ONE closed smooth outline. The head section is a real
        // cat profile (crown → brow → nose STEP → chin → jaw), not a circle —
        // the muzzle step is what the reference silhouettes live on.
        let hp = headPitch
        let R: CGFloat = 0.36
        let hcx = headX - 0.09, hcy = headY - 0.13 + hp * 0.22
        // Head-relative point, gently rotated by head pitch.
        let ca = cos(hp * 0.5), sa = sin(hp * 0.5)
        func H(_ dx: CGFloat, _ dy: CGFloat) -> (CGFloat, CGFloat) {
            (hcx + dx * ca - dy * sa, hcy + dx * sa + dy * ca)
        }
        let spineTopY = (shoulderY + rumpY) / 2 + 0.17 + pose.backArch
        let bellyY = shoulderY - 0.50 + pose.crouch * 0.22
        var outline: [(CGFloat, CGFloat)] = []
        outline.append(H(R * 0.15, -R * 0.94))                              // under jaw
        outline.append((shoulderX + 0.18 + sit * 0.11, shoulderY - 0.40 - sit * 0.02)) // chest
        outline.append(((shoulderX + rumpX) / 2 + 0.06, bellyY))            // belly
        outline.append((rumpX + 0.30, rumpY - 0.38 - sit * 0.10))           // groin / thigh front
        outline.append((rumpX - 0.16, rumpY - 0.30 - sit * 0.12))           // under tail
        outline.append((rumpX - 0.28 - sit * 0.06, rumpY + 0.02))           // rump back
        outline.append((rumpX - 0.12, rumpY + 0.21 + pose.backArch * 0.5))  // rump top
        outline.append(((rumpX + shoulderX) / 2, spineTopY))                // spine crest
        outline.append((shoulderX - 0.02 - sit * 0.10, shoulderY + 0.19 + sit * 0.06 + pose.backArch * 0.3)) // withers
        outline.append((shoulderX + 0.20 - sit * 0.08, shoulderY + 0.08 + sit * 0.26)) // neck top
        outline.append(H(-R * 0.70, R * 0.62))                              // crown back
        outline.append(H(-R * 0.12, R * 0.98))                              // crown top
        outline.append(H(R * 0.55, R * 0.82))                               // brow
        outline.append(H(R * 0.90, R * 0.34))                               // stop (brow → muzzle)
        outline.append(H(R * 1.12, R * 0.02))                               // nose tip
        outline.append(H(R * 1.05, -R * 0.26))                              // under nose
        outline.append(H(R * 0.72, -R * 0.56))                              // chin
        outline.append(H(R * 0.30, -R * 0.84))                              // jaw
        ctx.setFillColor(bodyColor.cgColor)
        ctx.addPath(Self.catmull(mapped(outline), closed: true))
        ctx.fillPath()

        // Ears: big, slightly canted outward, convex outer edge (reference cue).
        let flick = earFlick * 0.1
        let earLen = R * (0.60 + 0.36 * pose.earPerk)
        func ear(baseA: CGFloat, tipA: CGFloat, tipLen: CGFloat) {
            let e = CGMutablePath()
            let a1 = baseA - 0.36, a2 = baseA + 0.36
            e.move(to: P(hcx + cos(a1) * R * 0.90, hcy + sin(a1) * R * 0.90))
            let tip = (x: hcx + cos(tipA) * (R * 0.72 + tipLen), y: hcy + sin(tipA) * (R * 0.72 + tipLen))
            e.addQuadCurve(to: P(tip.x, tip.y),
                           control: P(hcx + cos(a1 + 0.14) * (R + tipLen * 0.75), hcy + sin(a1 + 0.14) * (R + tipLen * 0.75)))
            e.addLine(to: P(hcx + cos(a2) * R * 0.90, hcy + sin(a2) * R * 0.90))
            e.closeSubpath()
            ctx.addPath(e)
            ctx.fillPath()
        }
        ear(baseA: 1.70 + hp * 0.5, tipA: 1.78 + hp * 0.5 + flick, tipLen: earLen * 0.88) // rear ear
        ear(baseA: 1.26 + hp * 0.5, tipA: 1.14 + hp * 0.5, tipLen: earLen)         // front ear

        // Sitting: haunch mass over the folded rear, blended into the outline.
        if sit > 0.15 {
            let hx = P(rumpX + 0.16, rumpY * 0.45)
            let hr = s * 0.42 * sit
            ctx.fillEllipse(in: CGRect(x: hx.x - hr, y: hx.y - hr * 0.95, width: hr * 2, height: hr * 1.9))
        }

        // --- Near legs over the body ---
        drawLeg(front: true, far: false)
        drawLeg(front: false, far: false)

        // --- Accent lines: thin background-colored strokes carving the haunch
        // and foreleg out of the solid fill — the reference style's signature.
        let accent = NSColor(white: 0.05 + 0.90 * w, alpha: 0.85)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(s * 0.028)
        ctx.setLineCap(.round)
        // Haunch: a sweeping thigh arc from the tail root around and down.
        let haunch = CGMutablePath()
        haunch.move(to: P(rumpX + 0.04 + sit * 0.04, rumpY + 0.02 + sit * 0.08))
        haunch.addQuadCurve(to: P(rumpX + 0.22 + sit * 0.12, rumpY - 0.50 + sit * 0.18),
                            control: P(rumpX + 0.40 + sit * 0.06, rumpY - 0.16))
        ctx.addPath(haunch)
        ctx.strokePath()
        // Foreleg: a short line separating the near front leg from the chest.
        // Static poses only — a swinging leg leaves the line floating.
        if state != .pounceAir, abs(speed) < size * 0.3 {
            let leg = CGMutablePath()
            leg.move(to: P(shoulderX - 0.10 + sit * 0.06, bellyY - 0.01))
            leg.addQuadCurve(to: P(shoulderX - 0.12 + sit * 0.10, 0.12),
                             control: P(shoulderX - 0.13 + sit * 0.08, bellyY - 0.18))
            ctx.addPath(leg)
            ctx.strokePath()
        }

        // --- Whiskers: three thin strokes fanning from the muzzle.
        ctx.setLineWidth(s * 0.018)
        for (dy, len, tilt) in [(CGFloat(-0.06), CGFloat(0.38), CGFloat(0.09)),
                                (CGFloat(-0.12), CGFloat(0.42), CGFloat(0.00)),
                                (CGFloat(-0.18), CGFloat(0.36), CGFloat(-0.09))] {
            let base = H(R * 0.88, R * (dy * 2 - 0.18))
            let tip  = (base.0 + len * ca - tilt * sa, base.1 + len * sa + tilt * ca)
            ctx.beginPath()
            ctx.move(to: P(base.0, base.1))
            ctx.addLine(to: P(tip.0, tip.1 + dy))
            ctx.strokePath()
        }

        // --- Eye (with blink): almond with a slit pupil.
        let eyeOpen = 1 - blinkPhase
        if eyeOpen > 0.08 {
            let e = P(hcx + R * 0.42, hcy + R * 0.22 + hp * 0.03)
            let ew = s * 0.055, eh = s * 0.070 * eyeOpen
            ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.95, blue: 0.55, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: e.x - ew, y: e.y - eh, width: ew * 2, height: eh * 2))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: e.x - ew * 0.22, y: e.y - eh * 0.9, width: ew * 0.44, height: eh * 1.8))
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
