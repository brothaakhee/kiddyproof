import CoreGraphics
import Foundation

// The whole parent-settings vector as one immutable, Codable value. Delivered to the
// render/tap threads as a single snapshot through the existing KidModeState lock, so a
// reader always sees an internally-consistent set (never a torn half-applied edit).
public struct KidSettings: Codable, Equatable {
    public enum Ceiling: String, Codable, CaseIterable {
        case calm, balanced, wild
        public var multiplier: CGFloat { switch self { case .calm: return 0.45; case .balanced: return 1.0; case .wild: return 1.8 } }
        public var label: String { switch self { case .calm: return "Calm"; case .balanced: return "Balanced"; case .wild: return "Wild" } }
    }

    public var defaultScene: String
    public var kidSwitching: Bool          // may the kid change scenes (orb / shuffle / shake)
    public var energeticEnabled: Bool      // include the opt-in higher-energy scenes
    public var autoShuffle: Bool
    public var shuffleInterval: Double     // seconds
    public var shakeToShuffle: Bool
    public var audioEnabled: Bool
    public var audioVolume: Double         // 0…1
    public var intensityCeiling: Ceiling
    public var maxSessionSeconds: Double

    public static let `default` = KidSettings(
        defaultScene: "Black Hole", kidSwitching: true, energeticEnabled: false, autoShuffle: false,
        shuffleInterval: 30, shakeToShuffle: true, audioEnabled: true, audioVolume: 0.8,
        intensityCeiling: .balanced, maxSessionSeconds: 120)

    public init(defaultScene: String, kidSwitching: Bool, energeticEnabled: Bool, autoShuffle: Bool,
                shuffleInterval: Double, shakeToShuffle: Bool, audioEnabled: Bool, audioVolume: Double,
                intensityCeiling: Ceiling, maxSessionSeconds: Double) {
        self.defaultScene = defaultScene
        self.kidSwitching = kidSwitching
        self.energeticEnabled = energeticEnabled
        self.autoShuffle = autoShuffle
        self.shuffleInterval = shuffleInterval
        self.shakeToShuffle = shakeToShuffle
        self.audioEnabled = audioEnabled
        self.audioVolume = audioVolume
        self.intensityCeiling = intensityCeiling
        self.maxSessionSeconds = maxSessionSeconds
    }

    // UserDefaults is user-writable and survives version changes — always clamp.
    public func clamped() -> KidSettings {
        var s = self
        s.shuffleInterval = min(600, max(10, s.shuffleInterval))
        s.audioVolume = min(1, max(0, s.audioVolume))
        s.maxSessionSeconds = min(1800, max(15, s.maxSessionSeconds))
        return s
    }
}
