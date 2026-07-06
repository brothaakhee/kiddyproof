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
    public var disabledScenes: Set<String> // parent-disabled scenes (empty = all enabled)
    public var autoShuffle: Bool
    public var shuffleInterval: Double     // seconds
    public var shakeToShuffle: Bool
    public var audioEnabled: Bool
    public var audioVolume: Double         // 0…1
    public var intensityCeiling: Ceiling
    public var maxSessionSeconds: Double
    public var adaptiveContrast: Bool      // opt-in: sample the desktop (Screen Recording) at arm

    public static let `default` = KidSettings(
        defaultScene: "Black Hole", kidSwitching: true, disabledScenes: [], autoShuffle: false,
        shuffleInterval: 30, shakeToShuffle: true, audioEnabled: true, audioVolume: 0.8,
        intensityCeiling: .balanced, maxSessionSeconds: 600, adaptiveContrast: false)

    public init(defaultScene: String, kidSwitching: Bool, disabledScenes: Set<String>, autoShuffle: Bool,
                shuffleInterval: Double, shakeToShuffle: Bool, audioEnabled: Bool, audioVolume: Double,
                intensityCeiling: Ceiling, maxSessionSeconds: Double, adaptiveContrast: Bool) {
        self.defaultScene = defaultScene
        self.kidSwitching = kidSwitching
        self.disabledScenes = disabledScenes
        self.autoShuffle = autoShuffle
        self.shuffleInterval = shuffleInterval
        self.shakeToShuffle = shakeToShuffle
        self.audioEnabled = audioEnabled
        self.audioVolume = audioVolume
        self.intensityCeiling = intensityCeiling
        self.maxSessionSeconds = maxSessionSeconds
        self.adaptiveContrast = adaptiveContrast
    }

    // Forward-compatible decoding: fields added in later versions fall back to their
    // defaults instead of failing the whole payload (which would silently reset every
    // saved parent setting on upgrade).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KidSettings.default
        defaultScene = try c.decodeIfPresent(String.self, forKey: .defaultScene) ?? d.defaultScene
        kidSwitching = try c.decodeIfPresent(Bool.self, forKey: .kidSwitching) ?? d.kidSwitching
        disabledScenes = try c.decodeIfPresent(Set<String>.self, forKey: .disabledScenes) ?? d.disabledScenes
        autoShuffle = try c.decodeIfPresent(Bool.self, forKey: .autoShuffle) ?? d.autoShuffle
        shuffleInterval = try c.decodeIfPresent(Double.self, forKey: .shuffleInterval) ?? d.shuffleInterval
        shakeToShuffle = try c.decodeIfPresent(Bool.self, forKey: .shakeToShuffle) ?? d.shakeToShuffle
        audioEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? d.audioEnabled
        audioVolume = try c.decodeIfPresent(Double.self, forKey: .audioVolume) ?? d.audioVolume
        intensityCeiling = try c.decodeIfPresent(Ceiling.self, forKey: .intensityCeiling) ?? d.intensityCeiling
        maxSessionSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSessionSeconds) ?? d.maxSessionSeconds
        adaptiveContrast = try c.decodeIfPresent(Bool.self, forKey: .adaptiveContrast) ?? d.adaptiveContrast
    }

    // UserDefaults is user-writable and survives version changes — always clamp.
    // maxSessionSeconds == 0 is the explicit NO-LIMIT sentinel (parent's choice;
    // the watchdog's heartbeat protection still guards lockout).
    public func clamped() -> KidSettings {
        var s = self
        s.shuffleInterval = min(600, max(10, s.shuffleInterval))
        s.audioVolume = min(1, max(0, s.audioVolume))
        if s.maxSessionSeconds != 0 {
            s.maxSessionSeconds = min(3600, max(15, s.maxSessionSeconds))
        }
        return s
    }
}
