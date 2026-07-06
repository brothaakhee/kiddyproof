import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import KiddyproofCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let suppressor = InputSuppressor()
    private let overlay = OverlayWindowManager()
    private let exitController = ExitGestureController()
    private let watchdog = WatchdogClient()
    private let state = KidModeState.shared
    private lazy var healthMonitor = TapHealthMonitor(suppressor: suppressor)

    private let onboarding = OnboardingController()

    private var statusItem: NSStatusItem?
    private var securedPoll: Timer?
    private var demoTimer: Timer?
    private var sessionTimer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var savedPresentationOptions: NSApplication.PresentationOptions = []

    let settings = SettingsStore()
    private var demoMax: TimeInterval?   // demo-only watchdog backstop override
    private var settingsMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon; required for tapCreate to work

        let uncleanExit = CrashSentinel.begin()

        settings.pushToState()   // seed the shared snapshot before anything reads it
        UpdaterSupport.startIfPackaged()   // before the menu is built (adds its item)
        setupStatusItem()
        applyIsolationOverride()

        if uncleanExit && ProcessInfo.processInfo.environment["KP_DEMO"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { CrashSentinel.offerReport() }
        }

        // First launch: the guided flow owns the permission story (welcome → grant →
        // honest limits → how to exit). Later launches without the grant fall back to
        // the direct system prompt.
        if onboarding.shouldShowOnLaunch {
            onboarding.show()
        } else if !Permissions.isAccessibilityTrusted() {
            NSLog("[kiddyproof] Accessibility NOT granted — prompting.")
            Permissions.promptForAccessibility()
            Permissions.openAccessibilitySettings()
        }

        suppressor.onEnterChord = { [weak self] in self?.armKidMode() }
        suppressor.start()
        watchdog.startIfAvailable()
        exitController.onExit = { [weak self] in self?.disarmKidMode(reason: "parent exit gesture") }

        // If the failsafe process dies while a session is running, bail out loudly —
        // never keep running with an imaginary watchdog.
        watchdog.onWatchdogDied = { [weak self] in
            guard let self = self, self.state.isArmed() else { return }
            self.disarmKidMode(reason: "watchdog process died")
            self.alert(title: "Kid mode ended",
                       text: "The safety watchdog stopped unexpectedly, so kid mode was exited. You can start it again from the menu bar.")
        }

        // Continuous tap health: on unrecoverable tap death, FAIL LOUD — tear kid mode
        // down instead of leaving an armed-looking overlay over leaking input.
        healthMonitor.onUnrecoverable = { [weak self] detail in
            guard let self = self, self.state.isArmed() else { return }
            self.disarmKidMode(reason: "tap unrecoverable: \(detail)")
            self.alert(title: "Kid mode ended",
                       text: "Input blocking stopped working (usually a permissions change or a system glitch) and could not be restored, so kid mode was exited for safety. Relaunch kiddyproof before starting it again.")
        }

        // Any input event that reaches our overlay through the normal AppKit path is
        // PROOF the suppressing tap is not swallowing input — a live leak. Bail.
        overlay.onLeakDetected = { [weak self] in
            guard let self = self, self.state.isArmed() else { return }
            self.disarmKidMode(reason: "input leak detected at overlay")
            self.alert(title: "Kid mode ended",
                       text: "An input event slipped past the blocker, so kid mode was exited for safety. Relaunch kiddyproof before starting it again.")
        }

        installSystemObservers()

        NSLog("[kiddyproof] ready. Enter kid mode with ⌃⌥⌘K or the menu-bar item.")

        // Self-contained, time-boxed demo for capturing evidence: arm, animate effects,
        // then auto-exit and quit. Triple-guarded (app timer + watchdog + external kill).
        if let demo = ProcessInfo.processInfo.environment["KP_DEMO"], let secs = Double(demo) {
            runDemo(seconds: secs)
        }
    }

    // Isolation harness: KP_SCENE=<name> launches straight into one scene (switching
    // disabled) so it can be previewed/tuned alone. Transient — does NOT persist over the
    // parent's saved settings (we override the in-memory snapshot, not the store).
    private func applyIsolationOverride() {
        guard let name = ProcessInfo.processInfo.environment["KP_SCENE"] else { return }
        let names = overlay.sceneNames
        guard names.contains(name) else {
            NSLog("[kiddyproof] KP_SCENE='\(name)' not found. Available: \(names.joined(separator: ", "))")
            return
        }
        var s = settings.current
        s.defaultScene = name
        s.kidSwitching = false
        KidModeState.shared.update { $0.settings = s }
        NSLog("[kiddyproof] isolation preview: \(name)")
    }

    private func runDemo(seconds: Double) {
        demoMax = min(seconds + 3, 15) // tight watchdog backstop for the demo
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.armKidMode()
            // Arming is ASYNC when adaptive contrast captures the desktop first —
            // wait (bounded) for the commit instead of checking synchronously.
            self.awaitArmed(deadline: 2.5) { armed in
                guard armed else {
                    NSLog("[kiddyproof] demo: failed to arm; quitting."); NSApp.terminate(nil); return
                }
                self.continueDemo(seconds: seconds)
            }
        }
    }

    private func awaitArmed(deadline: TimeInterval, _ completion: @escaping (Bool) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        func poll() {
            if state.isArmed() { completion(true); return }
            if ProcessInfo.processInfo.systemUptime - start > deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
    }

    private func continueDemo(seconds: Double) {
        driveDemoEffects()
        // Show the live scene switch partway through — unless previewing one scene.
        if ProcessInfo.processInfo.environment["KP_SCENE"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.5) { [weak self] in
                self?.overlay.requestSceneSwitch()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.disarmKidMode(reason: "demo end")
            NSApp.terminate(nil)
        }
    }

    // Drives the input pipeline directly (no physical input available headlessly):
    // sweeps the virtual cursor and injects key + click InputEvents like a mashing
    // kid so the Director/scenes have something to react to.
    private func driveDemoEffects() {
        let letters = Array("HELLOKIDABC123").map(String.init)
        let center = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: 700, y: 400)
        var tick = 0
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] timer in
            guard let self = self, self.state.isArmed() else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let angle = Double(tick) * 0.45
            let p = NSPoint(x: center.x + CGFloat(cos(angle)) * 260, y: center.y + CGFloat(sin(angle * 0.7)) * 150)
            // Alternate ~3s "vacuum" (button held + click spikes) and ~3s "blow out" (keys),
            // so input-driven scenes like Black Hole show their full suck→capture→release loop.
            let suckPhase = (tick / 26) % 2 == 0
            self.state.update { s in
                s.virtualCursor = p
                s.cursorSeq &+= 1
                s.bumpHeartbeat()
                s.leftButtonDown = suckPhase
                if suckPhase {
                    if tick % 4 == 0 { s.pushEvent(InputEvent(kind: .click(p, .left), time: now)); s.bumpHeartbeat() }
                } else if tick % 2 == 0 {
                    s.pushEvent(InputEvent(kind: .key(letters[(tick / 2) % letters.count]), time: now)); s.bumpHeartbeat()
                }
            }
            tick += 1
        }
        RunLoop.main.add(t, forMode: .common)
        demoTimer = t
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🛡️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Enter Kid Mode (⌃⌥⌘K)", action: #selector(menuEnter), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sm = NSMenu(); sm.delegate = self      // rebuilt on open (always reflects current state)
        settingsItem.submenu = sm
        menu.addItem(settingsItem)
        settingsMenu = sm
        menu.addItem(.separator())
        let status = NSMenuItem(title: accessibilityStatusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Welcome & Safety Guide…", action: #selector(showOnboarding), keyEquivalent: ""))
        if UpdaterSupport.isAvailable {
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        item.menu = menu
        statusItem = item
    }

    private func accessibilityStatusLine() -> String {
        Permissions.isAccessibilityTrusted() ? "Accessibility: granted ✓" : "Accessibility: NOT granted ✗ (relaunch after granting)"
    }

    @objc private func menuEnter() { armKidMode() }
    @objc private func openSettings() { Permissions.openAccessibilitySettings() }
    @objc private func showOnboarding() { onboarding.show() }
    @objc private func checkForUpdates() { UpdaterSupport.checkForUpdates() }
    @objc private func quit() { settings.flush(); disarmKidMode(reason: "quit"); NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        settings.flush()
        CrashSentinel.endCleanly()
    }

    // MARK: - Settings submenu (rebuilt each time it opens, so it always reflects state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === settingsMenu else { return }
        menu.removeAllItems()
        // Parent-only: settings are unreachable while kid mode is active (this disablement
        // is the enforcement mechanism for single-writer + session-scoped semantics).
        if state.isArmed() {
            let m = NSMenuItem(title: "Unavailable while kid mode is active", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
            return
        }
        let s = settings.current
        addHeader("Default Scene", to: menu)
        for name in overlay.pickableSceneNames where !s.disabledScenes.contains(name) {
            let it = check(name, #selector(setDefaultScene(_:)), on: s.defaultScene == name)
            it.representedObject = name
            menu.addItem(it)
        }
        menu.addItem(.separator())
        // Per-scene enable/disable: every scene that made the cut is one list; the
        // parent curates it. The last enabled scene can't be disabled.
        let scenesItem = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
        let scenesMenu = NSMenu()
        for name in overlay.pickableSceneNames {
            let it = NSMenuItem(title: name, action: #selector(toggleScene(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = s.disabledScenes.contains(name) ? .off : .on
            scenesMenu.addItem(it)
        }
        scenesItem.submenu = scenesMenu
        menu.addItem(scenesItem)
        menu.addItem(check("Kid Can Change Scenes", #selector(toggleKidSwitching), on: s.kidSwitching))
        menu.addItem(check("Auto-Shuffle Scenes", #selector(toggleAutoShuffle), on: s.autoShuffle))
        menu.addItem(radio("Shuffle Every", [("15s", 15), ("30s", 30), ("60s", 60), ("2 min", 120)],
                           current: s.shuffleInterval, sel: #selector(setShuffleInterval(_:))))
        menu.addItem(check("Shake to Shuffle", #selector(toggleShake), on: s.shakeToShuffle))
        menu.addItem(.separator())
        let adaptive = check("Adaptive Contrast (Screen Recording)", #selector(toggleAdaptive), on: s.adaptiveContrast)
        if s.adaptiveContrast && !BackgroundSampler.hasPermission() {
            adaptive.title = "Adaptive Contrast (permission needed — relaunch after granting)"
        }
        menu.addItem(adaptive)
        menu.addItem(.separator())
        menu.addItem(check("Sound", #selector(toggleAudio), on: s.audioEnabled))
        menu.addItem(radio("Volume", [("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0)],
                           current: s.audioVolume, sel: #selector(setVolume(_:))))
        menu.addItem(intensityItem(s.intensityCeiling))
        menu.addItem(radio("Session Limit", [("2 min", 120), ("5 min", 300), ("10 min", 600), ("30 min", 1800), ("No limit", 0)],
                           current: s.maxSessionSeconds, sel: #selector(setSession(_:))))
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false
        menu.addItem(h)
    }
    private func check(_ title: String, _ sel: Selector, on: Bool) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self
        it.state = on ? .on : .off
        return it
    }
    private func radio(_ title: String, _ opts: [(String, Double)], current: Double, sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, val) in opts {
            let it = NSMenuItem(title: label, action: sel, keyEquivalent: ""); it.target = self
            it.representedObject = val
            it.state = abs(val - current) < 0.001 ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }
    private func intensityItem(_ current: KidSettings.Ceiling) -> NSMenuItem {
        let parent = NSMenuItem(title: "Intensity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for c in KidSettings.Ceiling.allCases {
            let it = NSMenuItem(title: c.label, action: #selector(setCeiling(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = c.rawValue
            it.state = current == c ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func setDefaultScene(_ i: NSMenuItem) { if let n = i.representedObject as? String { settings.update { $0.defaultScene = n } } }
    @objc private func toggleKidSwitching() { settings.update { $0.kidSwitching.toggle() } }
    @objc private func toggleScene(_ i: NSMenuItem) {
        guard let name = i.representedObject as? String else { return }
        let all = Set(overlay.pickableSceneNames)
        settings.update { s in
            if s.disabledScenes.contains(name) {
                s.disabledScenes.remove(name)
            } else {
                // Never allow zero enabled scenes.
                guard all.subtracting(s.disabledScenes).count > 1 else { return }
                s.disabledScenes.insert(name)
                if s.defaultScene == name,
                   let fallback = all.subtracting(s.disabledScenes).sorted().first {
                    s.defaultScene = fallback
                }
            }
        }
    }
    @objc private func toggleAutoShuffle() { settings.update { $0.autoShuffle.toggle() } }
    @objc private func toggleShake() { settings.update { $0.shakeToShuffle.toggle() } }
    @objc private func setShuffleInterval(_ i: NSMenuItem) { if let v = i.representedObject as? Double { settings.update { $0.shuffleInterval = v } } }
    @objc private func toggleAudio() { settings.update { $0.audioEnabled.toggle() } }
    @objc private func toggleAdaptive() {
        settings.update { $0.adaptiveContrast.toggle() }
        if settings.current.adaptiveContrast && !BackgroundSampler.hasPermission() {
            BackgroundSampler.requestPermission()   // one-time system prompt / listing
            alert(title: "One more step for Adaptive Contrast",
                  text: """
                  Allow kiddyproof under System Settings ▸ Privacy & Security ▸ Screen \
                  Recording, then QUIT and RELAUNCH kiddyproof (macOS applies the \
                  permission only to a freshly launched app).

                  What it's for: one low-resolution snapshot of your frozen desktop each \
                  time kid mode starts, so the effects can pick bold ink over bright \
                  windows and glowing light over dark ones. Nothing is recorded, stored, \
                  or sent — the snapshot never leaves the effects engine. Kid mode works \
                  fine without it.
                  """)
        }
    }
    @objc private func setVolume(_ i: NSMenuItem) { if let v = i.representedObject as? Double { settings.update { $0.audioVolume = v } } }
    @objc private func setSession(_ i: NSMenuItem) { if let v = i.representedObject as? Double { settings.update { $0.maxSessionSeconds = v } } }
    @objc private func setCeiling(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let c = KidSettings.Ceiling(rawValue: r) { settings.update { $0.intensityCeiling = c } }
    }

    // MARK: - System observers (sleep / lock / session / displays)

    // Sleep, screen lock, and fast-user-switch all pull the rug out from under a
    // session tap (and macOS may leave it installed-but-dead afterwards). The safe,
    // simple contract: any of these events ends kid mode cleanly. This also removes
    // the wake-time race where a suspended main app misses heartbeats and gets
    // spuriously SIGKILLed by the watchdog.
    private func installSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemInterruption(_:)),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemInterruption(_:)),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemInterruption(_:)),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemInterruption(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func systemInterruption(_ note: Notification) {
        guard state.isArmed() else { return }
        disarmKidMode(reason: "system interruption (\(note.name.rawValue))")
    }

    // Display plugged/unplugged or resolution changed mid-session: reconcile the
    // overlay panels, re-clamp the virtual cursor, and re-assert the cursor freeze.
    @objc private func screensChanged() {
        guard state.isArmed() else { return }
        let bounds = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        suppressor.clampBounds = bounds
        state.update { s in
            s.virtualCursor.x = min(max(s.virtualCursor.x, bounds.minX), bounds.maxX)
            s.virtualCursor.y = min(max(s.virtualCursor.y, bounds.minY), bounds.maxY)
        }
        overlay.reconcileScreens()
        CursorController.reassert()
        NSLog("[kiddyproof] display configuration changed — overlay reconciled.")
    }

    // MARK: - Arm / disarm

    private func armKidMode() {
        guard !state.isArmed() else { return }

        guard Permissions.isAccessibilityTrusted() else {
            alert(title: "Accessibility required",
                  text: "kiddyproof needs Accessibility permission to block input. Grant it in System Settings, then relaunch.")
            Permissions.openAccessibilitySettings()
            return
        }

        // Irreducible gap: refuse to arm while Secure Event Input is active.
        if SecureInputGuard.isActive() {
            alert(title: "Can't start kid mode",
                  text: "A password field or app with Secure Keyboard Entry is active, so keystrokes can't be blocked. Click away from it (or quit Terminal's Secure Keyboard Entry) and try again.")
            return
        }

        // Silent-disable race: a non-nil tap is not a healthy tap. Prove a real event
        // flows through the callback before we trust it.
        guard verifyTapIsLive() else {
            alert(title: "Input blocking isn't active yet",
                  text: "The event tap was created but no events are flowing — usually a stale permission after install. Quit and relaunch kiddyproof, then try again.")
            return
        }

        // Prepare the virtual cursor and clamp bounds.
        let bounds = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        suppressor.clampBounds = bounds
        state.update {
            $0.virtualCursor = NSEvent.mouseLocation
            $0.exitProgress = 0
            $0.exitChordHeld = false
            $0.leftButtonDown = false
        }

        // Adaptive contrast (opt-in): sample the frozen desktop ONCE before the
        // overlay covers it, then continue arming. Bounded: whichever of the capture
        // or a 0.7s deadline lands first completes the arm; failure just means the
        // session runs on the appearance proxy. KP_TESTBG paints over the desktop, so
        // sampling would lie — skip it there.
        if settings.current.adaptiveContrast, BackgroundSampler.hasPermission(),
           ProcessInfo.processInfo.environment["KP_TESTBG"] == nil {
            var completed = false
            let finish: (BackgroundLuminance?) -> Void = { [weak self] map in
                DispatchQueue.main.async {
                    guard let self = self, !completed else { return }
                    completed = true
                    self.commitArm(background: map)
                }
            }
            BackgroundSampler.capture(completion: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { finish(nil) }
        } else {
            commitArm(background: nil)
        }
    }

    // The commit half of arming — runs after the (optional) background capture.
    private func commitArm(background: BackgroundLuminance?) {
        // The capture window is async: re-check the two states that could have
        // changed underneath it.
        guard !state.isArmed() else { return }
        if SecureInputGuard.isActive() { return }

        // Engage the failsafe FIRST and gate on it: never enter kid mode without a
        // working watchdog (the parent must always be able to get out). On failure we
        // bail before freezing the cursor / showing the overlay / setting armed.
        // The in-app session timer owns the CLEAN session end; the watchdog deadline
        // runs 10s behind it as the SIGKILL backstop for a wedged app. 0 = NO LIMIT:
        // no timer, no deadline — the heartbeat protection still guards lockout.
        let sessionSeconds = demoMax ?? settings.current.maxSessionSeconds
        guard watchdog.arm(maxSeconds: sessionSeconds == 0 ? 0 : sessionSeconds + 10) else {
            alert(title: "Can't start kid mode",
                  text: "The safety watchdog couldn't be engaged, so kid mode was not started — you must always be able to exit. Quit and relaunch kiddyproof.")
            return
        }

        CursorController.freezeAndHide()
        overlay.backgroundMap = background
        overlay.show()
        state.setArmed(true)
        exitController.start()
        startSecurePoll()
        healthMonitor.start()
        if sessionSeconds > 0 { startSessionTimer(seconds: sessionSeconds) }
        engageKioskHardening()
        preventDisplaySleep()

        NSLog("[kiddyproof] KID MODE ARMED (\(sessionSeconds > 0 ? "limit \(Int(sessionSeconds))s" : "no limit")).")
    }

    private func disarmKidMode(reason: String) {
        guard state.isArmed() else { return }
        state.setArmed(false)
        healthMonitor.stop()
        demoTimer?.invalidate(); demoTimer = nil
        securedPoll?.invalidate(); securedPoll = nil
        sessionTimer?.invalidate(); sessionTimer = nil
        exitController.stop()
        overlay.hide()
        CursorController.restore()
        releaseKioskHardening()
        allowDisplaySleep()
        watchdog.disarm()
        NSLog("[kiddyproof] KID MODE EXITED (\(reason)).")
    }

    // Clean, in-app session end. The watchdog's deadline (sessionSeconds + 10) only
    // fires if this timer never got to run — i.e. the app was truly wedged.
    private func startSessionTimer(seconds: TimeInterval) {
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.state.isArmed() else { return }
            self.disarmKidMode(reason: "session limit reached")
            self.alert(title: "Kid mode ended",
                       text: "The session limit was reached, so kid mode exited on its own. Start it again from the menu bar or with ⌃⌥⌘K.")
        }
        RunLoop.main.add(t, forMode: .common)
        sessionTimer = t
    }

    // OS-level hardening independent of the tap: while armed, ask macOS itself to
    // disable Force Quit, process switching, session termination, and to hide the
    // menu bar and Dock. (This combo is the documented-consistent kiosk set.)
    private func engageKioskHardening() {
        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .autoHideDock, .autoHideMenuBar,
            .disableForceQuit, .disableProcessSwitching,
            .disableSessionTermination, .disableHideApplication,
        ]
    }
    private func releaseKioskHardening() {
        NSApp.presentationOptions = savedPresentationOptions
    }

    // Keep the display awake while a kid is playing so the idle timer can't drop the
    // session to the lock screen mid-play.
    private func preventDisplaySleep() {
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "kiddyproof kid mode is active" as CFString, &id)
        sleepAssertion = ok == kIOReturnSuccess ? id : 0
    }
    private func allowDisplaySleep() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    // Post a harmless synthetic mouse-move and confirm the callback observed it.
    // (The same probe runs continuously while armed — see TapHealthMonitor.)
    private func verifyTapIsLive() -> Bool {
        let before = state.heartbeat()
        TapHealthMonitor.postSyntheticProbe()
        // Wait up to ~250ms for the tap thread to register it.
        for _ in 0..<50 {
            if state.heartbeat() > before { return true }
            usleep(5000)
        }
        suppressor.reEnableIfNeeded()
        return false
    }

    private func startSecurePoll() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.state.isArmed() else { return }
            if SecureInputGuard.isActive() {
                // Disarm FIRST: this stops the render loop + cancels the heartbeat + sends
                // DISARM, so the blocking modal below can't be read by the watchdog as a
                // stalled renderTick and trigger a spurious SIGKILL.
                self.disarmKidMode(reason: "secure input activated mid-session")
                self.alert(title: "Kid mode interrupted",
                           text: "Secure input became active (a password field opened), so keystrokes can no longer be blocked. Kid mode was exited for safety.")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        securedPoll = t
    }

    private func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
