import AppKit
import KiddyproofCore

// The deliberate parent-exit gesture. Two independent channels, both designed to be
// un-triggerable by toddler mashing and to survive the failure modes:
//   - Mouse corner-hold (PRIMARY): press-and-hold in the bottom-left corner for 3s.
//     Mouse events survive Secure Event Input, so this always works.
//   - Modifier chord (SECONDARY): hold Ctrl+Opt+Cmd for 3s. Fast and easy, but can be
//     blinded by Secure Event Input — hence it is the backup, not the primary.
// The hold-timing state machine lives in KiddyproofCore.ExitGestureLogic (unit-tested);
// this controller samples the shared state at 20 Hz and feeds it.
final class ExitGestureController {
    var onExit: (() -> Void)?
    private var timer: Timer?
    private var logic = ExitGestureLogic(holdSeconds: 3.0)
    private var fired = false
    private let state = KidModeState.shared

    private var cornerRect: NSRect {
        // Bottom-left 120x120 of the PRIMARY screen (origin 0,0) — the same screen the
        // overlay draws the exit ring and hint on, so the UI always points at the real
        // exit zone even in multi-display arrangements. Recomputed every tick, so a
        // display change mid-session is picked up automatically.
        let s = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        guard let screen = s else { return .zero }
        return NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 120, height: 120)
    }

    func start() {
        fired = false
        logic.reset()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        state.update { $0.exitProgress = 0 }
    }

    private var wasHolding = false
    private var wasButtonDown = false
    private var pressStartedInCorner = false

    private func tick() {
        guard !fired else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let (chordHeld, buttonDown, cursor) = state.read { ($0.exitChordHeld, $0.leftButtonDown, $0.virtualCursor) }

        // The corner hold only counts if the PRESS BEGAN inside the corner: a parent
        // deliberately aims there before pressing. A held drag that drifts into the
        // corner (Black Hole's click-hold vacuum, exactly what the scene teaches a kid
        // to do) must never convert into an exit.
        let inCorner = NSPointInRect(cursor, cornerRect)
        if buttonDown && !wasButtonDown { pressStartedInCorner = inCorner }
        if !buttonDown { pressStartedInCorner = false }
        wasButtonDown = buttonDown
        let cornerHeld = buttonDown && inCorner && pressStartedInCorner

        // Safety telemetry: an exit hold starting/firing is always worth a log line —
        // it is the difference between "parent left deliberately" and a gesture bug.
        let holding = chordHeld || cornerHeld
        if holding != wasHolding {
            wasHolding = holding
            NSLog("[kiddyproof] exit-hold \(holding ? "STARTED" : "released"): chord=\(chordHeld) corner=\(cornerHeld) button=\(buttonDown) cursor=(\(Int(cursor.x)),\(Int(cursor.y)))")
        }

        let progress = logic.progress(chordHeld: chordHeld, cornerHeld: cornerHeld, now: now)
        state.update { $0.exitProgress = progress }

        if progress >= 1 {
            fired = true
            NSLog("[kiddyproof] exit gesture FIRED: chord=\(chordHeld) corner=\(cornerHeld) cursor=(\(Int(cursor.x)),\(Int(cursor.y)))")
            onExit?()
        }
    }
}
