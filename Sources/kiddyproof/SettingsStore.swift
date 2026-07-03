import Foundation
import KiddyproofCore

// Main-thread-only owner of settings: loads/persists and pushes each change into
// KidModeState as a snapshot. Writes are debounced but flushed synchronously on quit.
// (The KidSettings value type itself lives in KiddyproofCore, where its clamping is
// unit-tested.)
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
