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

    // Which categories the kid may cycle through (set from settings at arm). Calm-only
    // by default; energetic scenes are opt-in.
    var allowedCategories: Set<SceneCategory> = [.calm]

    var activeName: String { incoming?.name ?? current.name }
    var skin: CursorSkin { incoming?.skin ?? current.skin }
    var reactivity: Reactivity { (incoming ?? current).reactivity }
    var veil: CGFloat { (incoming ?? current).veil }
    var audioSwell: CGFloat { (incoming ?? current).audioSwell }
    var sceneNames: [String] { scenes.map { $0.name } }                              // all (incl. archived) — for KP_SCENE
    var pickableNames: [String] { scenes.filter { $0.category != .archived }.map { $0.name } }  // parent-selectable

    // Pick the active scene with no crossfade — used once at arm, before any frame.
    func select(named name: String) {
        guard incoming == nil, let i = scenes.firstIndex(where: { $0.name == name }) else { return }
        index = i
        current = scenes[i]
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
            if cand != index, allowedCategories.contains(scenes[cand].category) { nextIndex = cand; break }
        }
        guard nextIndex != index else { return }   // nothing else to switch to
        let next = scenes[nextIndex]
        next.reset()
        next.draining = false
        current.draining = true
        incoming = next
        index = nextIndex
        transitionStart = now
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
            if p >= 1 {
                current.reset()
                current = inc
                current.draining = false
                incoming = nil
            }
        } else {
            current.update(ctx)
        }
    }

    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint, now: TimeInterval) {
        if let inc = incoming {
            let p = smoothstep(CGFloat((now - transitionStart) / duration))
            ctx.saveGState(); ctx.setAlpha(1 - p)
            current.draw(into: ctx, bounds: bounds, origin: origin)
            ctx.restoreGState()
            ctx.saveGState(); ctx.setAlpha(p)
            inc.draw(into: ctx, bounds: bounds, origin: origin)
            ctx.restoreGState()
        } else {
            current.draw(into: ctx, bounds: bounds, origin: origin)
        }
    }

    private func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x)); return t * t * (3 - 2 * t)
    }
}
