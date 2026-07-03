import Foundation

// The exit gesture's timing core, extracted for unit testing: two independent hold
// channels (modifier chord, corner-hold), each requiring a CONTINUOUS hold of
// `holdSeconds`; any release resets that channel; overall progress is the max of the
// two. Deliberate 3-second holds are statistically unreachable by random mashing —
// this struct is where that property actually lives, so it is tested directly.
public struct ExitGestureLogic {
    public let holdSeconds: TimeInterval
    private var chordStart: TimeInterval?
    private var cornerStart: TimeInterval?

    public init(holdSeconds: TimeInterval = 3.0) {
        self.holdSeconds = holdSeconds
    }

    public mutating func reset() {
        chordStart = nil
        cornerStart = nil
    }

    // Feed the current sampled state; returns overall progress 0…1 (>= 1 means exit).
    public mutating func progress(chordHeld: Bool, cornerHeld: Bool, now: TimeInterval) -> Double {
        if chordHeld { if chordStart == nil { chordStart = now } } else { chordStart = nil }
        if cornerHeld { if cornerStart == nil { cornerStart = now } } else { cornerStart = nil }
        let chord = chordStart.map { (now - $0) / holdSeconds } ?? 0
        let corner = cornerStart.map { (now - $0) / holdSeconds } ?? 0
        return min(1, max(chord, corner))
    }
}
