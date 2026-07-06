import AppKit
import QuartzCore

// Owns the overlay panels AND the whole effects runtime: the Director (scenes),
// the shared cursor effect, the intensity meter, the scene orb, and audio. ONE
// CADisplayLink (on the primary view) drives simulation once per frame; every
// EffectsView then just draws the already-stepped state for its screen.
final class OverlayWindowManager: NSObject {
    // Fired (once per session, on main) if a real input event reaches an overlay view
    // through the normal AppKit path — impossible while the suppressing tap is healthy,
    // so it is treated as proof of a live input leak.
    var onLeakDetected: (() -> Void)?
    private var leakReported = false

    private var panels: [NSPanel] = []
    private var views: [EffectsView] = []
    private var renderTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastExitProgress: Double = 0
    private var lastChordHeld = false
    private var armTime: CFTimeInterval = 0
    private var hintAlpha: CGFloat = 0          // exit hint: shows on arm, fades, reappears on exit-approach

    // Session-scoped scene-shuffle controls (set at show()).
    private var autoShuffle = false
    private var shuffleInterval: TimeInterval = 30
    private var nextShuffleAt: TimeInterval = 0
    private var shakeEnabled = false
    private var shakeReversals = 0
    private var lastShakeVX: CGFloat = 0
    private var lastShuffle: TimeInterval = 0

    private let state = KidModeState.shared
    let audio = KidAudio()
    private let mash = MashMeter()
    private let cursorFX = CursorEffect()
    private let orb = SceneOrb()
    // Calm scenes are the default world (Black Hole first — the flagship & default);
    // the two energetic scenes are opt-in via settings and never cycle otherwise.
    private lazy var director = Director(scenes: [
        CalmBlackholeScene(), FireworksScene(), PhysicsScene(),
        CalmDriftScene(), CalmConstellationScene(), CalmRipplesScene(), CalmPetalsScene(),
        CalmGravitationalScene(), CalmSpiderwebScene(), CalmPuzzleScene(),
    ])
    // Optional slow-motion for inspecting a scene in the isolation harness (KP_SLOMO).
    private let slomo: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["KP_SLOMO"], let v = Double(s), v > 0 { return CGFloat(v) }
        return 1
    }()

    private var simBounds: CGRect = .zero

    // Adaptive contrast: set by the arm sequence BEFORE show() when the parent has
    // opted in + granted Screen Recording; nil otherwise. Session-static.
    var backgroundMap: BackgroundLuminance?
    private var fallbackLightness: CGFloat = 0.3

    override init() {
        super.init()
        audio.boot()   // build the audio graph once at launch for zero arm-latency
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }
    // Orb center: top-right of the primary screen (diagonal from the bottom-left exit zone).
    private var orbCenter: NSPoint {
        guard let s = primaryScreen() else { return .zero }
        return NSPoint(x: s.frame.maxX - 120, y: s.frame.maxY - 120)
    }

    func show() {
        guard renderTimer == nil else { return }   // idempotent: a double-arm must never
        leakReported = false                       // stack panels or double-step the sim
        // One simulation spanning ALL monitors (matches the cursor's clamp bounds): each
        // screen's panel is a window into this shared global-coordinate sim, so the effect
        // is seamless across displays and the cursor's hole follows it onto any monitor.
        simBounds = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        if simBounds.isEmpty { simBounds = primaryScreen()?.frame ?? .zero }
        // No luminance map (or KP_TESTBG painting over the desktop): one proxy value
        // for the whole session — system light mode reads as a light background.
        switch ProcessInfo.processInfo.environment["KP_TESTBG"] {
        case "white": fallbackLightness = 0.92; backgroundMap = nil
        case "gray": fallbackLightness = 0.55; backgroundMap = nil
        case "black": fallbackLightness = 0.08; backgroundMap = nil
        default:
            fallbackLightness = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? 0.7 : 0.15
        }
        cursorFX.reset(); mash.reset(); orb.reset(); director.reset()
        // Session-scoped settings: sampled ONCE at arm (snapshot under the lock).
        let s = state.read { $0.settings }
        director.allowedCategories = s.energeticEnabled ? [.calm, .energetic] : [.calm]
        director.select(named: s.defaultScene)
        orb.enabled = s.kidSwitching
        audio.setEnabled(s.audioEnabled); audio.setVolume(Float(s.audioVolume))
        autoShuffle = s.autoShuffle && s.kidSwitching
        shuffleInterval = s.shuffleInterval
        nextShuffleAt = CACurrentMediaTime() + s.shuffleInterval
        shakeEnabled = s.shakeToShuffle && s.kidSwitching
        shakeReversals = 0; lastShakeVX = 0; lastShuffle = 0
        orb.onCycle = { [weak self] in self?.director.requestNext(now: CACurrentMediaTime()) }

        for screen in NSScreen.screens { addPanel(for: screen) }

        armTime = CACurrentMediaTime(); hintAlpha = 1   // show the exit hint on entry, then fade

        // A plain 60Hz timer drives sim + redraw (proven reliable; avoids the
        // CADisplayLink↔CATransaction flush coupling that saturated this GPU).
        lastTick = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        renderTimer = t
    }

    func hide() {
        audio.setEnabled(false)        // silence AND pause the whole engine when kid mode ends
        renderTimer?.invalidate(); renderTimer = nil
        backgroundMap = nil            // the desktop unfreezes; the sample is stale
        for p in panels { p.orderOut(nil) }
        panels.removeAll(); views.removeAll()
    }

    private func addPanel(for screen: NSScreen) {
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setFrame(screen.frame, display: true)
        let view = EffectsView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.manager = self
        view.screenOrigin = screen.frame.origin
        panel.contentView = view
        panel.orderFrontRegardless()
        panels.append(panel); views.append(view)
    }

    // Incremental display reconciliation (never tear-down-and-rebuild-all, which would
    // open a coverage gap): add panels for new screens, drop panels whose screen is
    // gone, and re-frame panels whose screen moved or changed resolution.
    func reconcileScreens() {
        guard renderTimer != nil else { return }   // only while showing
        let screens = NSScreen.screens
        simBounds = screens.reduce(NSRect.zero) { $0.union($1.frame) }
        if simBounds.isEmpty { simBounds = primaryScreen()?.frame ?? .zero }

        // Match panels to screens by proximity of origin; a panel with no screen dies.
        var unclaimed = Set(panels.indices)
        for screen in screens {
            if let i = unclaimed.first(where: { views[$0].screenOrigin == screen.frame.origin }) {
                unclaimed.remove(i)
                if panels[i].frame != screen.frame {
                    panels[i].setFrame(screen.frame, display: true)
                    views[i].frame = NSRect(origin: .zero, size: screen.frame.size)
                }
            } else {
                addPanel(for: screen)
            }
        }
        for i in unclaimed.sorted(by: >) {
            panels[i].orderOut(nil)
            panels.remove(at: i); views.remove(at: i)
        }
    }

    // Called by EffectsView when a real AppKit input event lands on the overlay while
    // armed. The tap swallows everything when healthy, so this only happens if input
    // is leaking — report once and let the owner tear kid mode down.
    fileprivate func inputReachedOverlay() {
        guard state.isArmed(), !leakReported else { return }
        leakReported = true
        NSLog("[kiddyproof] INPUT LEAK: an event reached the overlay through AppKit.")
        onLeakDetected?()
    }

    // Programmatic scene switch (used by the demo / could be a parent hotkey).
    func requestSceneSwitch() { director.requestNext(now: CACurrentMediaTime()) }

    var sceneNames: [String] { director.sceneNames }                 // all, incl. archived (KP_SCENE)
    var pickableSceneNames: [String] { director.pickableNames }      // parent-selectable (no drafts)

    private func step() {
        let now = CACurrentMediaTime()
        let realDt = lastTick == 0 ? 1.0 / 60.0 : min(max(now - lastTick, 0), 1.0 / 30.0)
        lastTick = now
        let dt = realDt / Double(slomo)     // slow-motion for isolation inspection (1 = normal)

        let snap = state.update { s -> (NSPoint, UInt64, CGFloat, [InputEvent], Bool) in
            s.renderTick &+= 1     // proves the render loop is making progress (decoupled heartbeat)
            lastExitProgress = s.exitProgress   // one snapshot drives all per-frame visuals
            lastChordHeld = s.exitChordHeld
            return (s.virtualCursor, s.eventHeartbeat, s.settings.intensityCeiling.multiplier, s.drainEvents(), s.leftButtonDown)
        }
        let cursor = snap.0
        updateHint(cursor: cursor, now: now, dt: CGFloat(dt))
        mash.update(heartbeat: snap.1, dt: CGFloat(dt), reactivity: director.reactivity, ceilingMult: snap.2)
        cursorFX.update(cursor: cursor, dt: CGFloat(dt), now: now)

        let ctx = EffectContext(dt: CGFloat(dt), now: now, intensity: mash.intensity,
                                bounds: simBounds, cursor: cursor,
                                cursorVel: cursorFX.currentVelocity, leftButtonDown: snap.4,
                                audio: audio.enabled ? audio : nil,
                                background: backgroundMap, fallbackLightness: fallbackLightness)

        // Single drain → split orb taps from scene events.
        var taps: [NSPoint] = []
        for e in snap.3 {
            if case let .click(p, .left) = e.kind, orb.enabled, orb.contains(p, center: orbCenter) {
                taps.append(p)
            } else {
                director.handle(e, ctx)
            }
        }
        director.update(ctx)
        audio.setSwell(director.audioSwell, dt: CGFloat(dt))     // continuous scene audio (vacuum hum)
        orb.update(center: orbCenter, cursor: cursor, taps: taps, dt: CGFloat(dt), now: now)
        maybeShuffle(now: now)

        for v in views { v.needsDisplay = true }
    }

    // Exit hint visibility: full for ~4s after arming, then fades to keep the screen pure;
    // reappears the instant the parent heads to leave (cursor in/near the bottom-left exit
    // corner, the ⌃⌥⌘ chord held, or the exit hold already underway).
    private func updateHint(cursor: NSPoint, now: TimeInterval, dt: CGFloat) {
        var nearExit = false
        if let s = primaryScreen() {
            nearExit = cursor.x < s.frame.minX + 220 && cursor.y < s.frame.minY + 220
        }
        let approaching = lastChordHeld || lastExitProgress > 0.01 || nearExit
        let target: CGFloat = (now - armTime < 4.0 || approaching) ? 1 : 0
        hintAlpha += (target - hintAlpha) * min(1, dt * 4)
    }

    // Hands-free scene variety: timer-based auto-shuffle and shake-to-shuffle (rapid
    // horizontal cursor reversals). Both gated by settings (session-scoped) and a 2s
    // cooldown; the Director also no-ops switch requests during a crossfade.
    private func maybeShuffle(now: TimeInterval) {
        let cool = now - lastShuffle > 2.0
        if autoShuffle && now >= nextShuffleAt {
            nextShuffleAt = now + shuffleInterval
            if cool { director.requestNext(now: now); lastShuffle = now; return }
        }
        guard shakeEnabled else { return }
        let vx = cursorFX.currentVelocity.x
        if abs(vx) > 900 {
            if vx.sign != lastShakeVX.sign && abs(lastShakeVX) > 900 { shakeReversals += 1 }
            lastShakeVX = vx
        } else if abs(vx) < 200 {
            shakeReversals = max(0, shakeReversals - 1)
            lastShakeVX = 0
        }
        if shakeReversals >= 5 && cool {
            director.requestNext(now: now); lastShuffle = now; shakeReversals = 0
        }
    }

    // Read-only draw of the current stepped state, called by each EffectsView.
    // Dev aid: KP_TESTBG=white|gray|black paints a solid backdrop so effect contrast can
    // be checked against extreme backgrounds without fighting window management.
    private static let testBG: CGColor? = {
        switch ProcessInfo.processInfo.environment["KP_TESTBG"] {
        case "white": return NSColor.white.cgColor
        case "gray": return NSColor(white: 0.55, alpha: 1).cgColor
        case "black": return NSColor.black.cgColor
        default: return nil
        }
    }()

    // Cached ink-brush stamps for the exit ring: a red→green hue ramp + a dark bleed
    // backing (so the brushy arc reads on any wallpaper).
    private static let inkHues: [CGImage] = (0...15).map {
        inkSprite(NSColor(hue: 0.34 * CGFloat($0) / 15, saturation: 0.85, brightness: 0.95, alpha: 1))
    }
    private static let inkDark = inkSprite(NSColor(white: 0, alpha: 1))

    fileprivate func render(into ctx: CGContext, bounds: CGRect, origin: CGPoint) {
        let now = CACurrentMediaTime()
        if let bg = Self.testBG { ctx.setBlendMode(.normal); ctx.setFillColor(bg); ctx.fill(bounds) }
        // The ONLY background: a light translucent dusk so glows read on any wallpaper.
        // The parent's real screen stays visible through it (the core premise).
        let veil = director.veil
        if veil > 0.01 {
            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor(white: 0, alpha: veil).cgColor)
            ctx.fill(bounds)
        }
        director.draw(into: ctx, bounds: bounds, origin: origin, now: now)
        cursorFX.draw(into: ctx, origin: origin, skin: director.skin, now: now)
        if orb.enabled { orb.draw(into: ctx, origin: origin, now: now) }
        // Exit ring + hint only on the PRIMARY screen — the exit corner lives there
        // (ExitGestureController), so drawing it on every screen would point parents
        // at corners that don't exit.
        let primaryOrigin = primaryScreen()?.frame.origin ?? .zero
        if origin == primaryOrigin { drawExitAndHint(into: ctx, bounds: bounds) }
    }

    private func drawExitAndHint(into ctx: CGContext, bounds: CGRect) {
        let progress = lastExitProgress
        if progress > 0.01 {
            // A hand-painted ink brush stroke: overlapping soft dabs sweep clockwise from
            // 12 o'clock, hue ramping red → green so the tapered tip only turns green at
            // 100% — the cue you're about to break out. A dark bleed backing keeps it
            // readable on any wallpaper.
            let center = NSPoint(x: 78, y: 78), r: CGFloat = 44, p = CGFloat(progress), start = CGFloat.pi / 2
            ctx.setBlendMode(.normal)
            func brushW(_ t: CGFloat) -> CGFloat {
                let base = 5.6 + 1.6 * sin(t * 19)                                   // ink-bleed width variation
                let taper: CGFloat = t > 0.86 ? max(0.4, 1 - (t - 0.86) / 0.14 * 0.6) : 1   // brush tip
                return base * taper
            }
            let stamps = max(4, Int(p * 90))
            var pts: [(x: CGFloat, y: CGFloat, w: CGFloat, hue: Int)] = []
            pts.reserveCapacity(stamps + 1)
            for i in 0...stamps {
                let t = CGFloat(i) / CGFloat(stamps), frac = t * p                   // frac = fraction of full circle
                let a = start - frac * 2 * .pi, rr = r + sin(t * 33) * 1.4           // wobble = hand-painted edge
                pts.append((center.x + cos(a) * rr, center.y + sin(a) * rr, brushW(t), min(15, Int(frac * 16))))
            }
            ctx.setAlpha(0.32)
            for q in pts { let w = q.w + 2; ctx.draw(Self.inkDark, in: CGRect(x: q.x - w, y: q.y - w, width: w * 2, height: w * 2)) }
            ctx.setAlpha(0.95)
            for q in pts { let w = q.w; ctx.draw(Self.inkHues[q.hue], in: CGRect(x: q.x - w, y: q.y - w, width: w * 2, height: w * 2)) }
            ctx.setAlpha(1)
        }
        // Pure by default — the exit hint only shows on entry / when the parent goes to leave.
        guard hintAlpha > 0.01 else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6 * hintAlpha)   // soft halo → readable on any wallpaper
        shadow.shadowBlurRadius = 5; shadow.shadowOffset = .zero
        NSAttributedString(string: "Hold ⌃⌥⌘ or the bottom-left corner for 3 seconds to exit", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.85 * hintAlpha),
            .shadow: shadow,
        ]).draw(at: NSPoint(x: 24, y: bounds.height - 40))
    }
}

final class EffectsView: NSView {
    weak var manager: OverlayWindowManager?
    var screenOrigin: NSPoint = .zero
    override var isFlipped: Bool { false }   // bottom-left origin to match screen coords

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        manager?.render(into: ctx, bounds: bounds, origin: screenOrigin)
    }

    // While the suppressing tap is healthy, NO input event can reach this view via the
    // normal AppKit path (the tap returns nil before WindowServer routes anything).
    // So any event landing here while armed is proof of a leak — the overlay doubles
    // as both a physical input sink (clicks are absorbed here, not by the apps below)
    // and a tripwire that tears kid mode down. Synthetic health probes are mouseMoved
    // events, which NSView ignores without a tracking area, so they can't false-fire.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { manager?.inputReachedOverlay() }
    override func rightMouseDown(with event: NSEvent) { manager?.inputReachedOverlay() }
    override func otherMouseDown(with event: NSEvent) { manager?.inputReachedOverlay() }
    override func scrollWheel(with event: NSEvent) { manager?.inputReachedOverlay() }
    override func keyDown(with event: NSEvent) { manager?.inputReachedOverlay() }
}
