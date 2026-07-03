import AppKit

// The deliberate parent-exit gesture. Two independent channels, both designed to be
// un-triggerable by toddler mashing and to survive the failure modes:
//   - Mouse corner-hold (PRIMARY): press-and-hold in the bottom-left corner for 3s.
//     Mouse events survive Secure Event Input, so this always works.
//   - Modifier chord (SECONDARY): hold Ctrl+Opt+Cmd for 3s. Fast and easy, but can be
//     blinded by Secure Event Input — hence it is the backup, not the primary.
// A sustained 3-second hold is essentially impossible to produce by random flailing.
final class ExitGestureController {
    var onExit: (() -> Void)?
    private var timer: Timer?
    private var chordStart: TimeInterval?
    private var cornerStart: TimeInterval?
    private var fired = false
    private let holdSeconds: TimeInterval = 3.0
    private let state = KidModeState.shared

    private var cornerRect: NSRect {
        // Bottom-left 120x120 of whichever screen owns that origin (main screen here).
        guard let s = NSScreen.screens.first else { return .zero }
        return NSRect(x: s.frame.minX, y: s.frame.minY, width: 120, height: 120)
    }

    func start() {
        fired = false; chordStart = nil; cornerStart = nil
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        state.update { $0.exitProgress = 0 }
    }

    private func tick() {
        guard !fired else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let (chordHeld, buttonDown, cursor) = state.read { ($0.exitChordHeld, $0.leftButtonDown, $0.virtualCursor) }

        // Chord channel.
        if chordHeld { if chordStart == nil { chordStart = now } } else { chordStart = nil }
        let chordProgress = chordStart.map { (now - $0) / holdSeconds } ?? 0

        // Corner-hold channel.
        let inCorner = NSPointInRect(cursor, cornerRect)
        if buttonDown && inCorner { if cornerStart == nil { cornerStart = now } } else { cornerStart = nil }
        let cornerProgress = cornerStart.map { (now - $0) / holdSeconds } ?? 0

        let progress = min(1, max(chordProgress, cornerProgress))
        state.update { $0.exitProgress = progress }

        if progress >= 1 {
            fired = true
            onExit?()
        }
    }
}
