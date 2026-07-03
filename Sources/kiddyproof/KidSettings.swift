import CoreGraphics
import Foundation

// The whole parent-settings vector as one immutable, Codable value. Delivered to the
// render/tap threads as a single snapshot through the existing KidModeState lock, so a
// reader always sees an internally-consistent set (never a torn half-applied edit).
struct KidSettings: Codable, Equatable {
    enum Ceiling: String, Codable, CaseIterable {
        case calm, balanced, wild
        var multiplier: CGFloat { switch self { case .calm: return 0.45; case .balanced: return 1.0; case .wild: return 1.8 } }
        var label: String { switch self { case .calm: return "Calm"; case .balanced: return "Balanced"; case .wild: return "Wild" } }
    }

    var defaultScene: String
    var kidSwitching: Bool          // may the kid change scenes (orb / shuffle / shake)
    var energeticEnabled: Bool      // include the opt-in higher-energy scenes
    var autoShuffle: Bool
    var shuffleInterval: Double     // seconds
    var shakeToShuffle: Bool
    var audioEnabled: Bool
    var audioVolume: Double         // 0…1
    var intensityCeiling: Ceiling
    var maxSessionSeconds: Double

    static let `default` = KidSettings(
        defaultScene: "Black Hole", kidSwitching: true, energeticEnabled: false, autoShuffle: false,
        shuffleInterval: 30, shakeToShuffle: true, audioEnabled: true, audioVolume: 0.8,
        intensityCeiling: .balanced, maxSessionSeconds: 120)

    // UserDefaults is user-writable and survives version changes — always clamp.
    func clamped() -> KidSettings {
        var s = self
        s.shuffleInterval = min(600, max(10, s.shuffleInterval))
        s.audioVolume = min(1, max(0, s.audioVolume))
        s.maxSessionSeconds = min(1800, max(15, s.maxSessionSeconds))
        return s
    }
}

// Main-thread-only owner of settings: loads/persists and pushes each change into
// KidModeState as a snapshot. Writes are debounced but flushed synchronously on quit.
final class SettingsStore {
    static let key = "com.kiddyproof.settings.v1"
    private(set) var current: KidSettings
    private var writeWork: DispatchWorkItem?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(KidSettings.self, from: data) {
            current = s.clamped()
        } else {
            current = .default
        }
    }

    func pushToState() { KidModeState.shared.update { $0.settings = current } }

    func update(_ mutate: (inout KidSettings) -> Void) {
        var s = current
        mutate(&s)
        current = s.clamped()
        KidModeState.shared.update { $0.settings = current }   // live snapshot, immediate
        scheduleWrite()                                        // disk write, debounced
    }

    private func scheduleWrite() {
        writeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeNow() }
        writeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func writeNow() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // Call on quit/terminate so an in-flight debounced edit is never lost.
    func flush() {
        writeWork?.cancel(); writeWork = nil
        writeNow()
    }
}
