import Foundation

// Launches and talks to the kiddywatchdog helper. While armed, we ping it ~2x/sec.
// If the main app livelocks (no pings) or the session runs too long, the watchdog
// SIGKILLs us — and because our tap dies with the process, input is restored.
final class WatchdogClient {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var pingSource: DispatchSourceTimer?
    private var lastRenderTick: UInt64 = 0
    private let pingQueue = DispatchQueue(label: "kiddyproof.heartbeat")

    // Resolve the helper next to our own executable.
    private func watchdogURL() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = exe.deletingLastPathComponent().appendingPathComponent("kiddywatchdog")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    func startIfAvailable() {
        guard process == nil else { return }
        guard let url = watchdogURL() else {
            NSLog("[kiddyproof] watchdog binary not found next to main executable — failsafe disabled.")
            return
        }
        let p = Process()
        p.executableURL = url
        let pipe = Pipe()
        p.standardInput = pipe
        do {
            try p.run()
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
    // pings only when the render loop has actually advanced a frame. So a busy-but-
    // progressing main thread never false-triggers the watchdog, while a true freeze
    // (renderTick stops) correctly stops pings → the watchdog kills and restores input.
    // Returns false if the initial ARM couldn't be delivered (failsafe NOT engaged).
    @discardableResult
    func arm(maxSeconds: TimeInterval) -> Bool {
        guard send("ARM \(Int(maxSeconds))") else { return false }
        let src = DispatchSource.makeTimerSource(queue: pingQueue)
        src.schedule(deadline: .now() + 0.3, repeating: 0.3)
        // lastRenderTick is touched ONLY on pingQueue (no cross-thread race).
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let tick = KidModeState.shared.read { $0.renderTick }
            if tick != self.lastRenderTick { self.lastRenderTick = tick; self.send("PING") }
        }
        src.resume()
        pingSource = src
        return true
    }

    func disarm() {
        pingSource?.cancel()
        pingSource = nil
        if !send("DISARM") {
            NSLog("[kiddyproof] WARNING: DISARM not delivered — watchdog may still be enforcing; closing pipe as backstop.")
        }
    }

    // Deterministic teardown so repeated arm/disarm or abnormal shutdown never orphans
    // a watchdog process. Closing stdin gives it its expected EOF exit; terminate() is
    // the backstop.
    deinit {
        pingSource?.cancel()
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
    }
}
