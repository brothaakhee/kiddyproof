import AppKit
import SceneKit
import GLTFSceneKit

// KIDDY IN 3D — the third skin for the shared cat brain: our own Blender-
// authored cat (Scripts/build_cat.py) rendered with SceneKit into the
// existing CGContext pipeline. The KiddyCat state machine keeps owning
// behavior, locomotion, and ballistics; this class only maps states to the
// model's authored animation clips and draws the frame.
//
// Clip switching: exactly ONE clip's players are attached at a time, and
// transitions use SceneKit's own blend-in/out. Stacking every clip and
// mixing with blendFactor does NOT work: non-additive animations on the
// same channel resolve as "last attached wins, lerped toward the REST pose
// by its blendFactor", so any stacked arrangement collapses to rest.
final class KiddyCat3D {

    private let scene: SCNScene
    private let renderer: SCNRenderer
    private let modelRoot: SCNNode
    // Every clip's players with their home node and key, detached at init.
    private var clips: [String: [(node: SCNNode, key: String, player: SCNAnimationPlayer)]] = [:]
    private var activeClip = ""
    private let fade: TimeInterval = 0.28
    private var loaded = false

    // Square offscreen canvas; the cat is framed by an orthographic side camera.
    private let canvas = CGSize(width: 560, height: 560)
    private let camScale: CGFloat = 1.70   // ortho half-height in model units
    private let camHeight: CGFloat = 0.90  // camera aim height in model units
    private var yaw: CGFloat = 0           // current smoothed facing yaw
    // Our built cat faces +X in the glTF; the side camera looks down -Z, so
    // facing screen-right is yaw 0 and screen-left is yaw π.
    private func yawTarget(_ facing: CGFloat) -> CGFloat { facing >= 0 ? 0 : .pi }

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
        key.light!.intensity = 1700
        key.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 700
        fill.eulerAngles = SCNVector3(-0.3, -2.2, 0)
        scene.rootNode.addChildNode(fill)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 800
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
        // GLTFSceneKit attaches every channel of every clip simultaneously,
        // keyed by generated UUIDs — clip identity is never preserved (its
        // loader calls addAnimation(_, forKey: nil) per channel). But the
        // attachment ORDER is deterministic: animations outer, channels
        // inner. So each node's animationKeys zips 1:1 with the channel list
        // the GLB's own JSON declares for that node. Parse it and regroup.
        let channelOwners = Self.channelOwners(glbURL: url)   // nodeName → [clipName]
        scene.rootNode.enumerateHierarchy { node, _ in
            let keys = node.animationKeys
            guard !keys.isEmpty else { return }
            let owners = channelOwners[node.name ?? ""] ?? []
            for (i, key) in keys.enumerated() {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                node.removeAnimation(forKey: key)
                guard i < owners.count else { continue }
                player.animation.usesSceneTimeBase = false
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.animation.blendInDuration = fade
                player.animation.blendOutDuration = fade
                clips[owners[i], default: []].append((node, key, player))
            }
        }
        NSLog("KiddyCat3D: clips loaded: \(clips.keys.sorted()) players: \(clips.values.map(\.count))")
        switchClip(to: "Idle")
        loaded = true
    }

    // Minimal GLB reader: for every node name, the ordered list of clip names
    // owning each animation channel that targets it — the ground truth for
    // regrouping the loader's anonymously-keyed players.
    private static func channelOwners(glbURL: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: glbURL), data.count > 20 else { return [:] }
        let jsonLen = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard data.count >= 20 + Int(jsonLen),
              let json = try? JSONSerialization.jsonObject(
                  with: data.subdata(in: 20..<20 + Int(jsonLen))) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]],
              let animations = json["animations"] as? [[String: Any]] else { return [:] }
        var owners: [String: [String]] = [:]
        for anim in animations {
            let name = anim["name"] as? String ?? "?"
            for channel in anim["channels"] as? [[String: Any]] ?? [] {
                guard let target = channel["target"] as? [String: Any],
                      let idx = target["node"] as? Int, idx < nodes.count,
                      let nodeName = nodes[idx]["name"] as? String else { continue }
                owners[nodeName, default: []].append(name)
            }
        }
        return owners
    }

    // Detach the old clip (SceneKit blends back toward rest over `fade`) and
    // attach the new one (blends in over `fade`) — one clip active at a time.
    private func switchClip(to name: String) {
        guard name != activeClip, let group = clips[name] else { return }
        if let old = clips[activeClip] {
            for (node, key, _) in old {
                node.removeAnimation(forKey: key, blendOutDuration: CGFloat(fade))
            }
        }
        for (node, key, player) in group {
            node.addAnimationPlayer(player, forKey: key)
            player.play()
        }
        activeClip = name
    }

    // Map the shared brain's state to an authored clip.
    private func clip(for state: KiddyCat.State, speed: CGFloat) -> String {
        switch state {
        case .walk, .stalk: return "Walk"
        case .trot: return "Run"
        case .sit, .groom: return "Sit"
        case .lie: return "Lie"
        case .pounceWindup: return "Jump_Start"
        case .pounceAir, .startle: return "Jump_Loop"
        case .eat: return "Idle_Eating"
        case .play: return "Headbutt"
        default: return "Idle"
        }
    }

    // Advance clip cross-fades and facing; called from KiddyCat.update.
    func update(dt: CGFloat, state: KiddyCat.State, speed: CGFloat, facing: CGFloat,
                size: CGFloat) {
        guard loaded else { return }
        switchClip(to: clip(for: state, speed: speed))
        // Kill foot-slide: play locomotion clips at the rate the ground is
        // actually passing. One authored Walk cycle advances ~0.48 model
        // units; px-per-model-unit on screen is size × 2.2 (see draw()).
        let unitsPerSecond = abs(speed) / (size * 2.2)
        let walkRate = max(0.4, min(3.0, unitsPerSecond / 0.48))
        clips["Walk"]?.forEach { $0.player.speed = walkRate }
        // The Run clip is authored at 24/14 ≈ 1.7 cycles/s advancing ~0.8 units.
        let runRate = max(0.5, min(3.0, unitsPerSecond / (0.8 * 1.7)))
        clips["Run"]?.forEach { $0.player.speed = runRate }
        // Smooth turn: yaw eases toward the travel direction.
        let wantYaw = yawTarget(facing)
        yaw += (wantYaw - yaw) * min(1, dt * 8)
        modelRoot.eulerAngles = SCNVector3(0, yaw, 0)
    }

    // Render the current frame and composite it into the overlay context.
    // pos/groundY/size are the brain's world coordinates.
    func draw(into ctx: CGContext, origin: CGPoint, pos: NSPoint, groundY: CGFloat,
              size: CGFloat, now: TimeInterval) {
        guard loaded else { return }
        // Real-time players evaluate against the CoreAnimation clock — the
        // snapshot must be stamped on that same timeline.
        let img = renderer.snapshot(atTime: CACurrentMediaTime(), with: canvas,
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
