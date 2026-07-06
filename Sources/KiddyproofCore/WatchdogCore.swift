import Foundation

// The watchdog's wire protocol and enforcement state machine, extracted so the
// safety-critical decisions ("do we SIGKILL the main app right now?") are pure,
// deterministic, and unit-tested. The kiddywatchdog executable is a thin shell
// around this: stdin lines → parse → apply; timer → verdict → kill.
public enum WatchdogCore {
    public enum Command: Equatable {
        case arm(maxSeconds: TimeInterval)
        case ping
        case disarm
        case unknown
    }

    // One command per line: "ARM <maxSeconds>" | "PING" | "DISARM".
    public static func parse(_ line: String) -> Command {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "ARM":
            let maxSeconds = parts.count > 1 ? (TimeInterval(parts[1]) ?? 120) : 120
            return .arm(maxSeconds: maxSeconds)
        case "PING": return .ping
        case "DISARM": return .disarm
        default: return .unknown
        }
    }

    public enum Verdict: Equatable {
        case ok
        case killHeartbeatLost   // main app armed but silent past the grace window
        case killDeadline        // max kid-mode duration reached
    }

    public struct Enforcement {
        public private(set) var enforcing = false
        public private(set) var lastPing: Date
        public private(set) var armDeadline: Date?

        public init(now: Date = Date()) {
            lastPing = now
        }

        public mutating func apply(_ command: Command, now: Date) {
            switch command {
            case .arm(let maxSeconds):
                enforcing = true
                lastPing = now
                // maxSeconds <= 0 = NO LIMIT: heartbeat enforcement only (the
                // parent-lockout protection never has an off switch).
                armDeadline = maxSeconds > 0 ? now.addingTimeInterval(maxSeconds) : nil
            case .ping:
                lastPing = now
            case .disarm:
                enforcing = false
                armDeadline = nil
            case .unknown:
                break
            }
        }

        public func verdict(now: Date, heartbeatGrace: TimeInterval) -> Verdict {
            guard enforcing else { return .ok }
            if now.timeIntervalSince(lastPing) > heartbeatGrace { return .killHeartbeatLost }
            if let d = armDeadline, now >= d { return .killDeadline }
            return .ok
        }
    }
}
