import AppKit

// Shared mutable state touched by the tap thread (writer of input) and the render
// thread (reader/drainer). All access goes through a single NSLock via update/read,
// which operate on an inout value-type Storage so re-entrancy is impossible.
final class KidModeState {
    static let shared = KidModeState()

    struct Storage {
        var armed = false
        var virtualCursor = NSPoint.zero
        var leftButtonDown = false
        var exitChordHeld = false
        var eventHeartbeat: UInt64 = 0
        var cursorSeq: UInt64 = 0           // bumped on each cursor move (render-derived velocity)
        var renderTick: UInt64 = 0          // bumped once per rendered frame (true main-thread liveness)
        var exitProgress: Double = 0

        // Live settings snapshot, written by the main thread, read on the render tick.
        var settings = KidSettings.default

        private var events: [InputEvent] = []
        private let eventCap = 4096          // drained every frame; headroom is cheap

        mutating func bumpHeartbeat() { eventHeartbeat &+= 1 }

        mutating func pushEvent(_ e: InputEvent) {
            events.append(e)
            if events.count > eventCap {
                events.removeFirst(events.count - eventCap)
                NSLog("[kiddyproof] InputEvent ring overflow — dropping oldest (cap \(eventCap))")
            }
        }
        mutating func drainEvents() -> [InputEvent] {
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }
    }

    private var storage = Storage()
    private let lock = NSLock()

    func update<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
    func read<T>(_ body: (Storage) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(storage)
    }

    func setArmed(_ value: Bool) { update { $0.armed = value } }
    func isArmed() -> Bool { read { $0.armed } }
    func heartbeat() -> UInt64 { read { $0.eventHeartbeat } }
}
