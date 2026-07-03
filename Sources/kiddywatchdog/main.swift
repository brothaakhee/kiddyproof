import Foundation
import KiddyproofCore

// kiddywatchdog — the parent-lockout failsafe.
//
// This process installs NO event tap, so it can never be wedged by Secure Event
// Input, a tap timeout, or TCC revocation. It is launched as a CHILD of the main
// kiddyproof app and communicates over its stdin pipe. Its only job: if the main
// app stops sending heartbeats while kid mode is armed, or kid mode exceeds its
// maximum duration, SIGKILL the main app. Killing the main process tears down its
// CGEventTap, which immediately restores keyboard and mouse input to the user.
//
// Protocol (one command per line on stdin — parsed by WatchdogCore, unit-tested):
//   ARM <maxSeconds>   begin enforcing; start the max-duration deadline
//   PING               liveness heartbeat (main sends these ~2x/second while armed)
//   DISARM             stop enforcing (kid mode exited cleanly)
// EOF on stdin (main process died) -> exit quietly; the tap is already gone.

let parentPID = getppid()

// Shared enforcement state, guarded by a lock (touched by the reader thread and the
// enforcement timer). The decisions themselves live in WatchdogCore.Enforcement.
final class State {
    let lock = NSLock()
    var enforcement = WatchdogCore.Enforcement()
    func withLock<T>(_ body: (inout WatchdogCore.Enforcement) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&enforcement)
    }
}
let state = State()

// How long the main app may go silent (while armed) before we assume it is wedged.
// Low enough to restore a locked-out parent quickly; high enough that a transient slow
// frame on weak hardware doesn't trigger a spurious kill.
let heartbeatGrace: TimeInterval = 3.5

func log(_ msg: String) {
    FileHandle.standardError.write("[watchdog] \(msg)\n".data(using: .utf8)!)
}

func killMain(reason: String) {
    // PID-reuse guard: if the main app already died we get reparented (getppid()
    // changes), so never SIGKILL an innocent recycled pid.
    guard getppid() == parentPID else {
        log("main process already gone (reparented); not killing pid \(parentPID).")
        exit(0)
    }
    log("KILLING main pid \(parentPID): \(reason). Input will be restored as the tap dies with the process.")
    kill(parentPID, SIGKILL)
    exit(0)
}

// Enforcement loop on a background queue.
let timerQueue = DispatchQueue(label: "watchdog.enforce")
func scheduleCheck() {
    timerQueue.asyncAfter(deadline: .now() + 0.25) {
        let verdict = state.withLock { $0.verdict(now: Date(), heartbeatGrace: heartbeatGrace) }
        let enforcing = state.withLock { $0.enforcing }
        if enforcing {
            // Is the parent still alive at all? (kill with signal 0 just probes.)
            if kill(parentPID, 0) != 0 {
                log("main process gone; exiting.")
                exit(0)
            }
        }
        switch verdict {
        case .ok: break
        case .killHeartbeatLost:
            killMain(reason: "heartbeat lost (>\(heartbeatGrace)s) — main app appears livelocked")
        case .killDeadline:
            killMain(reason: "max kid-mode duration reached — auto-exit failsafe")
        }
        scheduleCheck()
    }
}
scheduleCheck()

log("started, guarding main pid \(parentPID)")

// Read commands line-by-line from stdin. readLine() returns nil on EOF (parent died).
while let line = readLine(strippingNewline: true) {
    let command = WatchdogCore.parse(line)
    state.withLock { $0.apply(command, now: Date()) }
    switch command {
    case .arm(let maxSeconds): log("ARMED, max duration \(maxSeconds)s")
    case .disarm: log("DISARMED (clean exit)")
    case .ping, .unknown: break
    }
}

log("stdin closed (main exited); shutting down.")
exit(0)
