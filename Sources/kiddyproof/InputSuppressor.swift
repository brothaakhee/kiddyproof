import AppKit
import CoreGraphics

// The load-bearing mechanism. A single CGEventTap at the session level, head-inserted,
// in DEFAULT (suppressing) mode. It runs on a dedicated high-priority thread and its
// callback does almost nothing: classify, copy a little state for the renderer, and
// return nil (swallow) or the event (pass through). All real work happens elsewhere.
//
// Idle state: pass everything through, but watch for the ENTER chord (Ctrl+Opt+Cmd+K)
// and swallow + arm when seen. Armed state: swallow every input event, while updating
// the virtual cursor / button / modifier-chord state that the exit gesture and effects
// read.
final class InputSuppressor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private(set) var runLoop: CFRunLoop?

    // K. Enter chord is Ctrl+Opt+Cmd+K.
    static let kKeyCodeK: Int64 = 40

    // Called (on main) when the parent presses the enter chord while idle.
    var onEnterChord: (() -> Void)?

    // Bounds the virtual cursor is clamped to while armed (set on arm).
    var clampBounds: NSRect = .zero

    private let state = KidModeState.shared

    func start() {
        let t = Thread { [weak self] in self?.threadMain() }
        t.qualityOfService = .userInteractive
        t.name = "kiddyproof.tap"
        t.start()
        self.thread = t
    }

    private func threadMain() {
        self.runLoop = CFRunLoopGetCurrent()
        if !installTap() {
            // Almost always means Accessibility is not granted, the app is sandboxed,
            // or the activation policy is wrong. Keep the run loop alive anyway so a
            // later recreate() attempt (e.g. after the parent grants permission) has a
            // thread to land on.
            NSLog("[kiddyproof] tapCreate FAILED — Accessibility not granted?")
        }
        // A run loop with no sources exits immediately; park a far-future timer so the
        // thread stays serviceable for recreate() even if the tap failed to install.
        let keepAlive = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3.15e9, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .commonModes)
        CFRunLoopRun()
    }

    // Creates + enables the tap on the current (tap) thread. Returns success.
    @discardableResult
    private func installTap() -> Bool {
        // Everything a toddler can hit with keyboard/trackpad/mouse/scroll, plus
        // NX_SYSDEFINED (bit 14) so media/volume/brightness keys are swallowed too.
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= (1 << CGEventMask(t.rawValue)) }
        mask |= (1 << 14) // NX_SYSDEFINED: media/special keys arrive here, not as keyDown

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // suppressing tap (NOT listenOnly)
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[kiddyproof] event tap installed and enabled (idle/pass-through).")
        return true
    }

    func reEnableIfNeeded() {
        guard let tap = tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            NSLog("[kiddyproof] tap was disabled — re-enabling.")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    var isTapEnabled: Bool {
        guard let tap = tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // Last-resort recovery for a dead-but-installed tap (TCC desync, Launch Services
    // race, post-wake wedge): tear the tap down and build a fresh one, on the tap
    // thread so it never races the callback. Completion fires on the main queue.
    func recreate(completion: @escaping (Bool) -> Void) {
        guard let rl = runLoop else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                self.runLoopSource = nil
            }
            if let old = self.tap {
                CGEvent.tapEnable(tap: old, enable: false)
                CFMachPortInvalidate(old)
                self.tap = nil
            }
            let ok = self.installTap()
            NSLog("[kiddyproof] tap recreate → \(ok ? "OK" : "FAILED")")
            DispatchQueue.main.async { completion(ok) }
        }
        CFRunLoopWakeUp(rl)
    }

    private enum Action { case pass, swallow, enter }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that is too slow or on certain user input; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        // Our own health probes prove the callback is alive and must do NOTHING else:
        // bump the heartbeat and vanish. (They carry empty modifier flags, so letting
        // them fall through would reset a parent's in-progress ⌃⌥⌘ exit hold.)
        if event.getIntegerValueField(.eventSourceUserData) == TapHealthMonitor.probeTag {
            let armed = state.update { s -> Bool in s.bumpHeartbeat(); return s.armed }
            return armed ? nil : Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let chord = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
        let now = ProcessInfo.processInfo.systemUptime
        // Extract the character BEFORE taking the lock: keyboardGetUnicodeString hits
        // the TIS layout and allocates — the render tick contends this lock at 60Hz.
        let keyStr: String? = type == .keyDown ? Self.character(from: event) : nil

        // One lock per event: bump heartbeat, branch on armed, mutate, decide outcome.
        let action: Action = state.update { s in
            s.bumpHeartbeat()

            if !s.armed {
                // Idle: only intercept the enter chord; pass everything else through.
                if type == .keyDown && chord
                    && event.getIntegerValueField(.keyboardEventKeycode) == InputSuppressor.kKeyCodeK {
                    return .enter
                }
                return .pass
            }

            s.exitChordHeld = chord
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                var p = s.virtualCursor
                p.x += event.getDoubleValueField(.mouseEventDeltaX)
                p.y -= event.getDoubleValueField(.mouseEventDeltaY) // delta is y-down; screen is y-up
                if clampBounds.width > 0 {
                    p.x = min(max(p.x, clampBounds.minX), clampBounds.maxX)
                    p.y = min(max(p.y, clampBounds.minY), clampBounds.maxY)
                }
                s.virtualCursor = p
                s.cursorSeq &+= 1
            case .leftMouseDown:
                s.leftButtonDown = true
                s.pushEvent(InputEvent(kind: .click(s.virtualCursor, .left), time: now))
            case .leftMouseUp:
                s.leftButtonDown = false
            case .rightMouseDown:
                s.pushEvent(InputEvent(kind: .click(s.virtualCursor, .right), time: now))
            case .otherMouseDown:
                s.pushEvent(InputEvent(kind: .click(s.virtualCursor, .other), time: now))
            case .keyDown:
                if let str = keyStr, !str.isEmpty {
                    s.pushEvent(InputEvent(kind: .key(str), time: now))
                }
            case .scrollWheel:
                let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                if dy != 0 { s.pushEvent(InputEvent(kind: .scroll(dy), time: now)) }
            default:
                break
            }
            return .swallow
        }

        switch action {
        case .pass: return Unmanaged.passUnretained(event)
        case .enter:
            DispatchQueue.main.async { [weak self] in self?.onEnterChord?() }
            return nil // swallow so "K" is never typed
        case .swallow: return nil // the underlying apps never see it
        }
    }

    private static func character(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        if length == 0 { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        // Filter control characters so we show real glyphs (letters, digits, space).
        if s.unicodeScalars.allSatisfy({ $0.value < 32 }) { return nil }
        return s.uppercased()
    }
}

// Top-level C callback — must not capture state; the instance comes via userInfo.
private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<InputSuppressor>.fromOpaque(userInfo).takeUnretainedValue()
    return suppressor.handle(type: type, event: event)
}
