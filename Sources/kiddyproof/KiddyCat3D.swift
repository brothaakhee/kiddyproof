import AppKit
import SceneKit
import GLTFSceneKit

// KIDDY IN 3D — the third skin for the shared cat brain. A professionally
// animated, CC0 low-poly cat (Quaternius, poly.pizza) rendered with SceneKit
// into the existing CGContext pipeline. The KiddyCat state machine keeps
// owning behavior, locomotion, and ballistics; this class only maps states
// to the model's authored animation clips (cross-faded, never cut), points
// the model in the travel direction, and draws the frame.
final class KiddyCat3D {

    private let scene: SCNScene
    private let renderer: SCNRenderer
    private let modelRoot: SCNNode
    private var clips: [String: [SCNAnimationPlayer]] = [:]
    private var weights: [String: CGFloat] = [:]
    private var activeClip = "Idle"
    private var loaded = false

    // Square offscreen canvas; the cat is framed by an orthographic side camera.
    private let canvas = CGSize(width: 560, height: 560)
    private let camScale: CGFloat = 1.70   // ortho half-height in model units
    private let camHeight: CGFloat = 0.90  // camera aim height in model units
    private var yaw: CGFloat = .pi / 2     // current smoothed facing yaw

    init?() {
        guard let url = Bundle.module.url(forResource: "cat", withExtension: "glb") else {
            NSLog("KiddyCat3D: cat.glb missing from bundle")
            return nil
        }
        let modelScene: SCNScene
        do {
            let source = try GLTFSceneSource(url: url)
            modelScene = try source.scene()
        } catch {
            NSLog("KiddyCat3D: failed to load cat.glb: \(error)")
            return nil
        }
        scene = modelScene
        scene.background.contents = nil    // transparent frames

        // modelRoot carries facing yaw; an inner node re-centers the model's
        // bounding box on the origin so rotation and framing stay symmetric.
        modelRoot = SCNNode()
        let inner = SCNNode()
        for child in scene.rootNode.childNodes where child.camera == nil && child.light == nil {
            inner.addChildNode(child)
        }
        let (minB, maxB) = inner.boundingBox
        inner.position = SCNVector3(-(minB.x + maxB.x) / 2, 0, -(minB.z + maxB.z) / 2)
        modelRoot.addChildNode(inner)
        scene.rootNode.addChildNode(modelRoot)

        // Soft, even studio lighting: key + fill + ambient. No harsh shadows —
        // the kid-mode aesthetic is calm.
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 350
        fill.eulerAngles = SCNVector3(-0.3, -2.2, 0)
        scene.rootNode.addChildNode(fill)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 420
        scene.rootNode.addChildNode(ambient)

        // Orthographic side camera, slightly high for a gentle 3/4 read.
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera!.usesOrthographicProjection = true
        camNode.camera!.orthographicScale = camScale
        camNode.position = SCNVector3(0, camHeight, 7)
        camNode.eulerAngles = SCNVector3(-0.10, 0, 0)
        scene.rootNode.addChildNode(camNode)

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("KiddyCat3D: no Metal device")
            return nil
        }
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camNode
        renderer.autoenablesDefaultLighting = false

        // Collect every animation player the loader attached across the node
        // tree and group them into clips. Keys arrive either as the glTF names
        // ("AnimalArmature|…|Walk") or as indexed fallbacks — normalize both.
        // This GLB's animation order (from its JSON): the ORDER table below.
        let ORDER = ["Death", "Headbutt", "Idle", "Idle_Eating",
                     "Jump_Loop", "Jump_Start", "Run", "Walk"]
        func clipName(from key: String) -> String {
            if let last = key.components(separatedBy: "|").last,
               ORDER.contains(last) { return last }
            if let idx = Int(key.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .last(where: { !$0.isEmpty }) ?? ""), idx < ORDER.count {
                return ORDER[idx]
            }
            return key
        }
        // Offscreen SCNRenderer only advances scene-time-based animations, so
        // every kept clip is switched to the scene clock (renderer.sceneTime is
        // set per frame) and clip selection happens purely through blendFactor.
        // Stray per-channel players (UUID/rotation/translation keys) duplicate
        // the named groups — remove them or they'd overlay the pose at will.
        scene.rootNode.enumerateHierarchy { node, _ in
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                let name = clipName(from: key)
                guard ORDER.contains(name) else {
                    node.removeAnimation(forKey: key)
                    continue
                }
                player.animation.usesSceneTimeBase = true
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.blendFactor = 0
                player.play()
                clips[name, default: []].append(player)
                weights[name] = 0
            }
        }
        NSLog("KiddyCat3D: clips loaded: \(clips.keys.sorted()) players: \(clips.values.map(\.count))")
        weights["Idle"] = 1
        clips["Idle"]?.forEach { $0.blendFactor = 1 }
        activeClip = "Idle"
        loaded = true
    }

    // Map the shared brain's state to an authored clip.
    private func clip(for state: KiddyCat.State, speed: CGFloat) -> String {
        switch state {
        case .walk, .stalk: return "Walk"
        case .trot: return "Run"
        case .pounceWindup: return "Jump_Start"
        case .pounceAir, .startle: return "Jump_Loop"
        case .eat: return "Idle_Eating"
        case .play: return "Headbutt"
        default: return "Idle"
        }
    }

    // Advance clip cross-fades and facing; called from KiddyCat.update.
    func update(dt: CGFloat, state: KiddyCat.State, speed: CGFloat, facing: CGFloat) {
        guard loaded else { return }
        let want = clip(for: state, speed: speed)
        if want != activeClip, clips[want] != nil {
            activeClip = want
        }
        // Cross-fade clip weights (~0.22s); scene time drives playback.
        let k = min(1, dt * 4.5)
        for (name, group) in clips {
            let target: CGFloat = name == activeClip ? 1 : 0
            var wgt = weights[name] ?? 0
            wgt += (target - wgt) * k
            if wgt < 0.005, target == 0 { wgt = 0 }
            weights[name] = wgt
            group.forEach { $0.blendFactor = wgt }
        }
        // Smooth turn: yaw eases toward the travel direction.
        let wantYaw: CGFloat = facing >= 0 ? .pi / 2 : -.pi / 2
        yaw += (wantYaw - yaw) * min(1, dt * 8)
        modelRoot.eulerAngles = SCNVector3(0, yaw, 0)
    }

    // Render the current frame and composite it into the overlay context.
    // pos/groundY/size are the brain's world coordinates.
    func draw(into ctx: CGContext, origin: CGPoint, pos: NSPoint, groundY: CGFloat,
              size: CGFloat, now: TimeInterval) {
        guard loaded else { return }
        renderer.sceneTime = now
        let img = renderer.snapshot(atTime: now, with: canvas,
                                    antialiasingMode: .multisampling4X)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // The ortho camera frames [-camScale, +camScale] vertically around
        // camHeight; model feet sit at y=0 → feet land at this frame fraction.
        let drawH = size * 2 * camScale * 2.2
        let feetFrac = 0.5 - camHeight / (2 * camScale)
        let x = pos.x - origin.x - drawH / 2
        let y = pos.y - origin.y - drawH * feetFrac
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
        ctx.draw(cg, in: CGRect(x: x, y: y, width: drawH, height: drawH))
    }
}
