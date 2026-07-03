import Foundation

// Launches and talks to the kiddywatchdog helper. While armed, we ping it ~2x/sec.
// If the main app livelocks (no pings) or the session runs too long, the watchdog
// SIGKILLs us — and because our tap dies with the process, input is restored.
//
// Liveness is verified in BOTH directions:
//   • Watchdog → us: pings require the render tick to advance AND the tap heartbeat
//     to be fresh (the 1 Hz TapHealthMonitor probe keeps it fresh while healthy), so
//     a wedged tap — not just a frozen main thread — eventually stops the pings and
//     triggers the SIGKILL backstop.
//   • Us → watchdog: we close our copy of the pipe's read end and ignore SIGPIPE, so
//     writes to a dead watchdog actually fail; a terminationHandler tells us the
//     moment it dies so the owner can bail out of kid mode instead of running with
//     an imaginary failsafe.
final class WatchdogClient {
    // Fired on the main queue if the watchdog process dies while we still need it.
    var onWatchdogDied: (() -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var pingSource: DispatchSourceTimer?
    private var lastRenderTick: UInt64 = 0
    private var lastHeartbeat: UInt64 = 0
    private var lastHeartbeatChange = Date()
    private let pingQueue = DispatchQueue(label: "kiddyproof.heartbeat")
    // The tap health probe fires at 1 Hz; if the heartbeat hasn't moved in this long
    // the tap is genuinely wedged and pings must stop so the watchdog kills us.
    private let heartbeatStaleLimit: TimeInterval = 5.0

    var isRunning: Bool { process?.isRunning ?? false }

    // Resolve the helper next to our own executable (SwiftPM layout) or in the app
    // bundle's MacOS directory (packaged layout) — both put it beside the main binary.
    private func watchdogURL() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = exe.deletingLastPathComponent().appendingPathComponent("kiddywatchdog")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    func startIfAvailable() {
        guard process == nil || process?.isRunning != true else { return }
        guard let url = watchdogURL() else {
            NSLog("[kiddyproof] watchdog binary not found next to main executable — failsafe disabled.")
            return
        }
        signal(SIGPIPE, SIG_IGN) // dead-watchdog writes must throw, not kill us
        let p = Process()
        p.executableURL = url
        let pipe = Pipe()
        p.standardInput = pipe
        // An intentional replacement (restart/deinit) clears `process` BEFORE killing
        // the old one, so `self.process === proc` is only true for an UNEXPECTED death.
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, self.process === proc else { return }
                self.process = nil
                self.stdinPipe = nil
                NSLog("[kiddyproof] watchdog DIED unexpectedly (status \(proc.terminationStatus)).")
                self.onWatchdogDied?()
                self.startIfAvailable() // try to bring the failsafe back for next time
            }
        }
        do {
            try p.run()
            // Drop our copy of the read end: the child holds the only reader now, so
            // its death makes our writes fail (EPIPE) instead of silently succeeding.
            try? pipe.fileHandleForReading.close()
            self.process = p
            self.stdinPipe = pipe
            NSLog("[kiddyproof] watchdog launched (pid \(p.processIdentifier)).")
        } catch {
            NSLog("[kiddyproof] failed to launch watchdog: \(error)")
        }
    }

    // Returns false if the line could not be delivered (pipe gone / write failed) so
    // callers can treat a failed ARM/DISARM as a real failsafe problem instead of
    // silently assuming the watchdog heard them.
    @discardableResult
    private func send(_ line: String) -> Bool {
        guard let h = stdinPipe?.fileHandleForWriting,
              let data = (line + "\n").data(using: .utf8) else { return false }
        do { try h.write(contentsOf: data); return true }
        catch { NSLog("[kiddyproof] watchdog pipe write failed for '\(line)': \(error)"); return false }
    }

    // Heartbeat runs on a BACKGROUND timer (immune to main-thread render load) and
    // pings only when (a) the render loop has advanced a frame AND (b) the tap
    // callback's event heartbeat is fresh. A busy-but-progressing main thread never
    // false-triggers the watchdog, while a true freeze OR a dead tap stops the pings
    // → the watchdog kills us and the dying tap releases input.
    // Returns false if the initial ARM couldn't be delivered (failsafe NOT engaged).
    @discardableResult
    func arm(maxSeconds: TimeInterval) -> Bool {
        guard isRunning, send("ARM \(Int(maxSeconds))") else { return false }
        let src = DispatchSource.makeTimerSource(queue: pingQueue)
        src.schedule(deadline: .now() + 0.3, repeating: 0.3)
        // lastRenderTick / lastHeartbeat* are touched ONLY on pingQueue (no race).
        lastHeartbeatChange = Date()
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let (tick, hb) = KidModeState.shared.read { ($0.renderTick, $0.eventHeartbeat) }
            if hb != self.lastHeartbeat {
                self.lastHeartbeat = hb
                self.lastHeartbeatChange = Date()
            }
            let tapFresh = Date().timeIntervalSince(self.lastHeartbeatChange) < self.heartbeatStaleLimit
            if tick != self.lastRenderTick && tapFresh {
                self.lastRenderTick = tick
                self.send("PING")
            }
        }
        src.resume()
        pingSource = src
        return true
    }

    func disarm() {
        pingSource?.cancel()
        pingSource = nil
        if !send("DISARM") {
            // The watchdog may still be enforcing against a dead pipe. Restart it so a
            // stale ARM state can't SIGKILL us seconds after a clean exit.
            NSLog("[kiddyproof] WARNING: DISARM not delivered — restarting the watchdog.")
            restart()
        }
    }

    private func restart() {
        let old = process
        process = nil // mark the coming exit as intentional before killing it
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        old?.terminate()
        startIfAvailable()
    }

    // Deterministic teardown so repeated arm/disarm or abnormal shutdown never orphans
    // a watchdog process. Closing stdin gives it its expected EOF exit; terminate() is
    // the backstop.
    deinit {
        pingSource?.cancel()
        let old = process
        process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        old?.terminate()
    }
}
