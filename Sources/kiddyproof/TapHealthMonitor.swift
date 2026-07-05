import AppKit
import CoreGraphics

// Continuous mid-session tap health: "a non-nil tap is not a healthy tap" applies for
// the WHOLE session, not just at arm time. Once per second (on its own queue, never
// the main thread) this posts a harmless synthetic mouse-move and requires the tap
// callback's heartbeat to advance. Escalation on failure:
//   probe 1 fails → re-enable the tap, retry next tick
//   probe 2 fails → recreate the tap from scratch
//   probe 3 fails → UNRECOVERABLE: fail loud (tear kid mode down) rather than leave
//                   an overlay up over leaking input.
// Side benefit: the 1 Hz synthetic probe guarantees the event heartbeat advances while
// the tap is healthy even if the kid touches nothing, which is what lets the watchdog
// client condition its pings on real tap flow (a wedged tap stops the pings → SIGKILL).
final class TapHealthMonitor {
    // Called on the main queue when the tap is dead and could not be restored.
    var onUnrecoverable: ((String) -> Void)?

    private let suppressor: InputSuppressor
    private let state = KidModeState.shared
    private let queue = DispatchQueue(label: "kiddyproof.taphealth", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var failures = 0
    private var recreating = false

    init(suppressor: InputSuppressor) {
        self.suppressor = suppressor
    }

    func start() {
        stop()
        failures = 0
        recreating = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // Marks our synthetic probes so the tap callback can recognize them. A probe must
    // prove the callback is alive and NOTHING else — an untagged probe carries empty
    // modifier flags and was observed resetting a parent's in-progress ⌃⌥⌘ exit hold
    // once per second, making the chord exit impossible to complete.
    static let probeTag: Int64 = 0x6B50_5052   // "kPPR"

    // Post a synthetic mouse-move at the current location (zero delta, so it drives no
    // visuals) and wait briefly for the callback to observe it.
    static func postSyntheticProbe() {
        let loc = CGEvent(source: nil)?.location ?? .zero
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: loc, mouseButton: .left) {
            e.setIntegerValueField(.eventSourceUserData, value: probeTag)
            e.post(tap: .cgSessionEventTap)
        }
    }

    private func probe() {
        guard !recreating, state.isArmed() else { return }
        suppressor.reEnableIfNeeded()

        let before = state.heartbeat()
        Self.postSyntheticProbe()
        // We are on our own serial queue — a short blocking wait is fine here.
        var flowed = false
        for _ in 0..<60 { // up to ~300ms
            if state.heartbeat() > before { flowed = true; break }
            usleep(5000)
        }
        if flowed {
            failures = 0
            return
        }

        failures += 1
        NSLog("[kiddyproof] tap health probe FAILED (\(failures)); enabled=\(suppressor.isTapEnabled)")
        switch failures {
        case 1:
            suppressor.reEnableIfNeeded() // cheap fix first; retry next tick
        case 2:
            recreating = true
            suppressor.recreate { [weak self] ok in
                // Completion is on main; hop back to our queue for state.
                self?.queue.async {
                    guard let self = self else { return }
                    self.recreating = false
                    if ok { self.failures = 0 } // next probe re-verifies real flow
                }
            }
        default:
            stop()
            DispatchQueue.main.async { [weak self] in
                self?.onUnrecoverable?("The input-blocking tap died and could not be restored.")
            }
        }
    }
}
