import AppKit

// Orchestrates the active scene and performs crossfaded switches. Render-thread
// confined (owned & driven by OverlayWindowManager) — no locks. Never runs two
// scenes at full budget: during the 0.6s crossfade the outgoing scene is
// "draining" (ignores new events, only ages out) while the incoming ramps in.
final class Director {
    private(set) var scenes: [Scene]
    private(set) var index = 0
    private var current: Scene
    private var incoming: Scene?
    private var transitionStart: TimeInterval = 0
    private let duration: TimeInterval = 0.6

    // Which scenes the kid may cycle through (set from settings at arm): the live,
    // non-parent-disabled set. Nil = every live scene.
    var enabledNames: Set<String>?

    private func isAllowed(_ s: Scene) -> Bool {
        s.category != .archived && (enabledNames?.contains(s.name) ?? true)
    }

    // Progress of the running crossfade (0…1), updated once per frame in update().
    private var fadeProgress: CGFloat = 1

    var activeName: String { incoming?.name ?? current.name }
    var skin: CursorSkin { incoming?.skin ?? current.skin }
    var reactivity: Reactivity { (incoming ?? current).reactivity }
    // The veil LERPS across the crossfade — a one-frame jump between scenes with
    // different veils reads as a full-screen flash, the exact artifact the calm bar
    // forbids.
    var veil: CGFloat {
        guard let inc = incoming else { return current.veil }
        return current.veil + (inc.veil - current.veil) * fadeProgress
    }
    var audioSwell: CGFloat { (incoming ?? current).audioSwell }
    var sceneNames: [String] { scenes.map { $0.name } }                              // all (incl. archived) — for KP_SCENE
    var pickableNames: [String] { scenes.filter { $0.category != .archived }.map { $0.name } }  // parent-selectable

    // Pick the active scene with no crossfade — used once at arm, before any frame.
    // A disabled/unknown default falls back to the first enabled scene.
    func select(named name: String) {
        guard incoming == nil else { return }
        var i = scenes.firstIndex(where: { $0.name == name && isAllowed($0) })
        if i == nil { i = scenes.firstIndex(where: { isAllowed($0) }) }
        guard let idx = i else { return }
        index = idx
        current = scenes[idx]
        current.draining = false   // never trust a stale drain flag from a previous session
    }

    init(scenes: [Scene]) {
        precondition(!scenes.isEmpty)
        self.scenes = scenes
        current = scenes[0]
    }

    func reset() {
        for s in scenes { s.reset() }
        index = 0; current = scenes[0]; incoming = nil
    }

    var isTransitioning: Bool { incoming != nil }

    func requestNext(now: TimeInterval) {
        guard incoming == nil else { return }   // ignore during transition
        // Next allowed scene after the current index (wrapping), skipping disallowed
        // categories and the current scene itself.
        let n = scenes.count
        var nextIndex = index
        for step in 1...n {
            let cand = (index + step) % n
            if cand != index, isAllowed(scenes[cand]) { nextIndex = cand; break }
        }
        guard nextIndex != index else { return }   // nothing else to switch to
        let next = scenes[nextIndex]
        next.reset()
        next.draining = false
        current.draining = true
        incoming = next
        index = nextIndex
        transitionStart = now
        fadeProgress = 0   // requestNext can land after update() this frame; never let a
                           // stale progress snap the veil for one frame
    }

    // Route a discrete input event to whichever scene is accepting input.
    func handle(_ event: InputEvent, _ ctx: EffectContext) {
        (incoming ?? current).handle(event, ctx)
    }

    func update(_ ctx: EffectContext) {
        if let inc = incoming {
            // Only the incoming scene simulates; the outgoing one is frozen and merely
            // fades out (its particles still draw at decreasing alpha). This caps work at
            // a single scene's budget during the 0.6s crossfade instead of doubling it.
            inc.update(ctx)
            let p = CGFloat((ctx.now - transitionStart) / duration)
            fadeProgress = smoothstep(p)
            if p >= 1 {
                current.reset()
                current = inc
                current.draining = false
                incoming = nil
                fadeProgress = 1
            }
        } else {
            current.update(ctx)
        }
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint, now: TimeInterval) {
        if let inc = incoming {
            // Each scene is composited through a TRANSPARENCY LAYER so the crossfade
            // alpha multiplies the whole scene as a group. A bare setAlpha would be
            // stomped by the scenes' own internal setAlpha calls, making every
            // transition a hard double-brightness pop instead of a fade.
            let p = smoothstep(CGFloat((now - transitionStart) / duration))
            if p < 0.999 {
                ctx.saveGState(); ctx.setAlpha(1 - p)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                current.draw(into: ctx, bounds: bounds, origin: origin)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            ctx.saveGState(); ctx.setAlpha(p)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            inc.draw(into: ctx, bounds: bounds, origin: origin)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        } else {
            current.draw(into: ctx, bounds: bounds, origin: origin)
        }
    }

    private func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x)); return t * t * (3 - 2 * t)
    }
}
