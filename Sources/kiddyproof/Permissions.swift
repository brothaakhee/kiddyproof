import AppKit
import ApplicationServices

// Accessibility (not merely Input Monitoring) is mandatory for a SUPPRESSING tap.
// It is granted by hand in System Settings and usually needs a relaunch to take hold.
enum Permissions {
    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
