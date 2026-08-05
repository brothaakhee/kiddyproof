import AppKit
import QuartzCore
import simd
import CanalSim

// ---------------------------------------------------------------------------
// BLOOM — a plant grown from its own chemistry.
//
// Nothing in this scene is drawn. The silhouette of every leaf is a chain of
// epidermal cells that pushed outward wherever auxin converged; the veins inside
// it are canals that formed because flux begets transport capacity; the angle
// between one leaf and the next is measured off a meristem, never written down;
// the petals are leaves whose margin was told to grow broad instead of toothed;
// and the fruit's lobes are a readout of where its ovules happened to land.
// See Sources/CanalSim — a port of github.com/aj-dev-smith/canalisation.
//
// What the child does is give it light. Keys and clicks feed the specimen, so it
// grows faster and reaches its flowering sooner while they play; waving the
// cursor is a breeze it sways under. When a specimen finishes its life cycle the
// next one germinates.
//
// This is the only scene that renders through Metal rather than Core Graphics
// (the tissue is volumetric and there are tens of thousands of triangles). It
// draws into a CAMetalLayer sitting UNDER the overlay's Core Graphics content,
// so the cursor, the scene orb and the exit hint all still sit on top of it.
// ---------------------------------------------------------------------------
final class CanalScene: Scene {
    let name = "Bloom"
    let category = SceneCategory.live
    let reactivity = Reactivity.calm
    let skin = CursorSkin.soft
    // MUST stay 0: the Core Graphics veil is composited ABOVE the Metal layer, so
    // any dusk here would dim the plant rather than the desktop behind it.
    let veil: CGFloat = 0
    var draining = false

    // --- the organism -----------------------------------------------------
    private var species = SpeciesTable.make("Sulphur Rosette", seed: 1)
    private var plant: Plant!
    private let buffers = Buffers()
    private var seedCounter: UInt32 = 0

    // --- time and pacing --------------------------------------------------
    // Plant time is counted in solver steps, not seconds. A specimen needs a few
    // thousand of them to become a plant, so the scene runs a budget of steps per
    // frame and lets the child's play raise it.
    private var stepBudget: Double = 0
    private var light: CGFloat = 0.35        // 0…1, how hard the child is playing
    private var simTime: Float = 0
    private var geomAge: Float = 0
    private var restAfterDeath: TimeInterval = 0

    // --- camera -----------------------------------------------------------
    private var cam = Camera()
    private var az: Float = 0.6
    private var el: Float = 0.16
    private var camTarget = SIMD3<Float>(0, 1, 0)
    private var camDist: Float = 8
    private var breeze: CGFloat = 0
    // where the light is, in world space — set from the cursor every frame
    private var sun: SIMD3<Float>?

    // one renderer per panel (each screen has its own drawable chain)
    private var renderers: [ObjectIdentifier: CanalRenderer] = [:]

    init() { germinate() }

    // A new specimen: a species from the table and a seed it has never had.
    private func germinate() {
        seedCounter &+= 1
        let s = UInt32(truncatingIfNeeded: Int(seedCounter) &* 2654435761 &+ 12345)
        // KP_CANAL_SPECIES pins one species for review; otherwise the scene works
        // through the table so a long session is not the same plant twice.
        let forced = ProcessInfo.processInfo.environment["KP_CANAL_SPECIES"]
        let name = forced ?? SpeciesTable.names[Int(s % UInt32(SpeciesTable.names.count))]
        species = SpeciesTable.make(name, seed: s)
        plant = Plant(species.prm, species.mo, species.sp, seed: s)
        simTime = 0
        geomAge = 999          // force a geometry build on the first frame
        buffers.reset()
        restAfterDeath = 0
        camDist = 8
        el = 0.16
        motes.removeAll()
        moteBuf.removeAll()
        // Review harness: a specimen needs thousands of solver steps to become the
        // plant a parent would actually see after a few minutes, and the demo
        // runner is capped at fifteen seconds. KP_CANAL_PRESTEP grows one up front
        // so a screenshot shows a mature plant rather than a seedling.
        if let s = ProcessInfo.processInfo.environment["KP_CANAL_PRESTEP"], let n = Int(s), n > 0 {
            for _ in 0..<n { plant.step(1) }
            simTime = Float(n)
        }
    }

    func reset() {
        draining = false
        germinate()
    }

    // --- input: the child gives it light ----------------------------------

    func handle(_ e: InputEvent, _ ctx: EffectContext) {
        guard !draining else { return }
        switch e.kind {
        case .key:
            light = min(1, light + 0.14)
            // a key is a small drop of light, released where the cursor is
            dropLight(at: ctx.cursor, in: ctx.bounds, size: 0.55)
            ctx.audio?.note(for: keyString(e), intensity: ctx.intensity)
        case .click(let pt, _):
            light = min(1, light + 0.26)
            dropLight(at: pt, in: ctx.bounds, size: 1.0)
            ctx.audio?.drip(intensity: ctx.intensity)
        case .scroll(let dy):
            breeze = max(-1.4, min(1.4, breeze + CGFloat(dy) * 0.16))
            ctx.audio?.whoosh()
        }
    }
    private func keyString(_ e: InputEvent) -> String {
        if case let .key(s) = e.kind { return s }
        return " "
    }

    // --- light, as something that travels -----------------------------------
    //
    // A press or a click releases a drop of light at the cursor. It drifts to the
    // nearest growing point and is absorbed, and only then does anything happen:
    // that shoot surges, and the flowering signal its leaves make is topped up.
    // The causal chain is visible in that order — you see the drop go in, then the
    // tip flare, then the plant lean and lengthen — which is what makes it read as
    // the child's doing rather than as an animation that was going to play anyway.
    private struct Mote {
        var p: SIMD3<Float>
        var target: SIMD3<Float>
        var age: Float = 0
        var life: Float
        var size: Float
        var spin: Float
    }
    private var motes: [Mote] = []
    private var moteBuf: [Float] = []
    private var moteRng = SystemRandomNumberGenerator()

    private func dropLight(at screen: NSPoint, in bounds: CGRect, size: Float) {
        // a mash must not turn into a swarm; the plant can only use so much
        guard motes.count < 90 else { return }
        let from = worldPoint(screen, in: bounds)
        // Somewhere to go. A spent specimen has no growing point left, so the
        // drop simply fades where it was released rather than flying nowhere.
        let to = plant.nearestTip(to: from) ?? from
        motes.append(Mote(p: from, target: to, life: Float.random(in: 0.75...1.15, using: &moteRng),
                          size: size, spin: Float.random(in: 0...6.283, using: &moteRng)))
    }

    // Screen point -> the world plane the camera is focused on. Without this the
    // cursor and the plant are in unrelated spaces and none of the interaction
    // can line up with what the child is pointing at.
    private func worldPoint(_ screen: NSPoint, in bounds: CGRect) -> SIMD3<Float> {
        let w = max(1, bounds.width), h = max(1, bounds.height)
        let nx = Float((screen.x - bounds.minX) / w) * 2 - 1
        let ny = Float((screen.y - bounds.minY) / h) * 2 - 1
        let aspect = Float(w / h)
        let fwd = simd_normalize(cam.target - cam.eye)
        var right = simd_cross(fwd, SIMD3<Float>(0, 1, 0))
        if simd_length(right) < 1e-4 { right = SIMD3<Float>(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, fwd)
        let tf = tan(cam.fov / 2)
        let dir = simd_normalize(fwd + right * (nx * tf * aspect) + up * (ny * tf))
        // intersect the plane through the camera target, facing the camera
        let denom = simd_dot(dir, fwd)
        guard abs(denom) > 1e-5 else { return cam.target }
        let t = simd_dot(cam.target - cam.eye, fwd) / denom
        return cam.eye + dir * max(0.1, t)
    }

    private func stepMotes(_ dt: Float) {
        guard !motes.isEmpty else { return }
        for i in motes.indices.reversed() {
            var m = motes[i]
            m.age += dt
            let u = canalEase(m.age / m.life)
            // it re-aims as it travels, because the tip it is heading for is
            // itself growing and moving while the drop is in the air
            if let t = plant.nearestTip(to: m.p) { m.target = t }
            m.p = simd_mix(m.p, m.target, SIMD3<Float>(repeating: min(1, dt * (2.2 + 6 * u))))
            if m.age >= m.life {
                // arrival: the plant spends it
                plant.absorbLight(at: m.target, amount: 0.30 * m.size)
                motes.remove(at: i)
            } else {
                motes[i] = m
            }
        }
    }
    private func canalEase(_ t: Float) -> Float {
        let x = max(0, min(1, t)); return x * x * (3 - 2 * x)
    }

    // Motes get their own tiny vertex stream, rebuilt every frame. The plant's
    // geometry is only rebuilt ten times a second — fine for tissue that grows
    // slowly, far too coarse for something crossing the frame in a second.
    private func buildMotes(_ pal: CanalSim.Palette) {
        moteBuf.removeAll(keepingCapacity: true)
        for m in motes {
            let u = canalEase(m.age / m.life)
            // brightest as it lands, so the arrival is the accent
            let b = (1.3 + 3.6 * u) * m.size
            let flick = 0.85 + 0.15 * sin(m.spin + m.age * 22)
            // the species' own spark colour, pulled a third of the way toward its
            // vein accent so a drop belongs to the plant it is feeding
            let base = pal.spark + (pal.vein - pal.spark) * 0.35
            let c = base * (b * flick)
            let r = (0.075 + 0.075 * (1 - u)) * m.size * max(1, camDist * 0.075)
            moteBuf.append(contentsOf: [m.p.x, m.p.y, m.p.z, c.x, c.y, c.z, r])
        }
    }

    // --- simulation --------------------------------------------------------

    func update(_ ctx: EffectContext) {
        let dt = Float(ctx.dt)
        let aspect = Float(max(1, ctx.bounds.width / max(1, ctx.bounds.height)))
        // light decays back to a slow baseline, so an unattended plant still grows
        light += (0.22 - light) * min(1, ctx.dt * 0.22)
        breeze *= CGFloat(exp(-ctx.dt / 2.2))
        // waving the cursor stirs the air
        let vel = ctx.cursorVel
        let speed = sqrt(vel.x * vel.x + vel.y * vel.y)
        if speed > 150 {
            breeze = max(-1.4, min(1.4, breeze + CGFloat(vel.x) * 0.00030 * ctx.dt * 6))
        }

        // THE CURSOR IS THE SUN. It sets where the shoots lean (phototropism, in
        // Axis.step) and where the key light comes from, so simply moving the
        // mouse re-lights the specimen immediately and bends its growth over the
        // next few seconds. Two timescales from one gesture: one you see at once,
        // one you notice you caused.
        sun = worldPoint(ctx.cursor, in: ctx.bounds)
        plant.sun = sun
        // Leaning is gentle on purpose. A plant that snapped round to the pointer
        // would be a puppet; this is a plant that has noticed.
        plant.sunPull = 0.55 + 0.45 * Float(light)

        stepMotes(dt)

        // A finished specimen rests in frame for a few seconds, then the next one
        // germinates — the scene renews itself rather than ending.
        if plant.dead() {
            restAfterDeath += ctx.dt
            if restAfterDeath > 6 { germinate() }
        }

        // Step the simulation. Play raises the target rate a long way — an
        // engaged child should watch a seedling become a plant, not wait out a
        // fixed clock — but the loop is TIME-BOXED rather than step-capped,
        // because a step costs whatever the specimen currently costs: a seedling
        // is cheap and a canalising blade on a sixty-organ plant is not. A fixed
        // step cap would either starve the seedling or drop frames on the adult.
        // Pace. An earlier setting ran a specimen from seed to ripe in eleven
        // seconds, which is a plant dying every quarter minute — the opposite of
        // what this scene is for. The immediate answer to play is the light, the
        // lean and the drops; GROWTH stays slow enough that a specimen is a
        // companion for several minutes rather than a firework.
        let perSecond = Double(15 + 50 * light)
        stepBudget += perSecond * Double(ctx.dt)
        if stepBudget > 240 { stepBudget = 240 }
        let deadline = CACurrentMediaTime() + 0.0065
        var steps = 0
        while stepBudget >= 1 {
            plant.step(1)
            stepBudget -= 1
            steps += 1
            if CACurrentMediaTime() >= deadline { break }
        }
        simTime += Float(steps)

        updateCamera(dt, aspect: aspect)
        logCard(ctx.now)

        // Geometry is rebuilt a few times a second, not every frame — the sway in
        // the vertex shader is what keeps it looking continuous between rebuilds.
        geomAge += dt
        if geomAge > 0.10 {
            geomAge = 0
            _ = buildPlantScene(buffers, plant, livePalette(), cam, simTime,
                                viewportHeight: Float(max(1, ctx.bounds.height)))
        }
        buildMotes(livePalette().pal)
    }

    // The species' palette with the parts the child is currently moving folded in.
    private func livePalette() -> Species {
        var sp = species
        var pal = sp.pal
        pal.sway = Float(1 + breeze * 2.2)
        // The key light sits where the cursor is, so the specimen is lit from
        // wherever the child is pointing. This is the half of the interaction
        // that answers within one frame.
        if let s = sun {
            let d = s - camTarget
            if simd_length(d) > 1e-3 { pal.key = simd_normalize(d + SIMD3<Float>(0, 0.35, 0)) }
        }
        // and playing warms the whole specimen a little, so a burst of attention
        // reads across the plant rather than only at the tip that caught it
        pal.exposure *= Float(1 + light * 0.35)
        sp.pal = pal
        return sp
    }

    // The reference prints a specimen card — every number on it is something the
    // chemistry decided rather than something the code states. Under KP_SCENE it
    // is the only way to tell a rendering fault from a plant that simply grew
    // that way, so the isolation harness logs it once a second.
    private static let logging = ProcessInfo.processInfo.environment["KP_SCENE"] != nil
    private var lastLog: TimeInterval = 0
    private func logCard(_ now: TimeInterval) {
        guard CanalScene.logging, now - lastLog > 1 else { return }
        lastLog = now
        let c = plant.card()
        let div = c.divergence.map { String(format: "%.0f°", $0) } ?? "—"
        NSLog("[Bloom] %@ %@ | leaves %d flowers %d petals %d teeth %d fruit %d | " +
              "divergence %@ | steps %.0f | tri %d line %d pt %d motes %d | light %.2f cam d=%.1f",
              species.name, c.stage.rawValue, c.leaves, c.flowers, c.petals, c.teeth,
              c.fruit, div, simTime, buffers.triCount, buffers.lineCount, buffers.ptCount,
              motes.count, Double(light), camDist)
    }

    // A slow orbit that keeps the whole specimen in frame as it grows. Nothing
    // here is user-driven: kid mode has no camera controls, and a drifting shot
    // is the calm register this scene is supposed to sit in.
    private func updateCamera(_ dt: Float, aspect: Float) {
        let b = plant.bounds()
        az += dt * 0.055                               // one slow revolution
        // Frame it off the actual field of view rather than a rule of thumb: the
        // distance that fits a height h is (h/2)/tan(fov/2), and the width has to
        // clear the same cone divided by the aspect ratio. Guessing this is how
        // the first pass ended up with the specimen overflowing the frame.
        let t = tan(cam.fov / 2)
        let fitH = (b.h * 0.5) / max(1e-3, t)
        let fitW = (b.w * 0.5) / max(1e-3, t * aspect)
        let want = max(2.6, max(fitH, fitW) * 1.04 + 0.55)   // a little air around it
        camDist += (want - camDist) * min(1, dt * 0.6)
        let wantTarget = SIMD3<Float>(b.cx, b.cy + b.h * 0.06, b.cz)
        camTarget += (wantTarget - camTarget) * min(1, dt * 0.5)
        // the eye rises a little as the plant does, so it is never looking down at it
        el += (0.12 + 0.16 * min(1, b.h / 8) - el) * min(1, dt * 0.3)

        let ce = cos(el), se = sin(el)
        cam.target = camTarget
        cam.eye = camTarget + SIMD3<Float>(sin(az) * ce * camDist, se * camDist, cos(az) * ce * camDist)
        cam.dist = camDist
        cam.fov = 0.62
        cam.dofRange = max(2.5, camDist * 0.42)
        cam.fogNear = max(0, camDist - max(b.w, b.h) * 0.6)
    }

    // --- drawing ------------------------------------------------------------

    // Nothing goes through Core Graphics: the plant is entirely in the Metal
    // layer below this context. Kept empty rather than removed because the Scene
    // protocol is what the Director drives every scene through.
    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {}

    func liveCount() -> Int { plant.organCount() }

    // Called once per panel per frame by the overlay, with that screen's layer.
    func renderMetal(into layer: CAMetalLayer, bounds: CGRect) {
        let key = ObjectIdentifier(layer)
        var r = renderers[key]
        if r == nil {
            r = CanalRenderer()
            renderers[key] = r
        }
        guard let renderer = r else { return }
        renderer.upload(buffers)
        renderer.uploadMotes(moteBuf)
        renderer.draw(to: layer, cam: cam, pal: livePalette().pal, time: simTime)
    }

    func releaseMetal() { renderers.removeAll() }
}
