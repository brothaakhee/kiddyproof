import AppKit
import KiddyproofCore

// App-side licensing: persists the license key and the trial's first-launch
// date, and answers "may kid mode arm?". Validation itself is pure logic in
// KiddyproofCore.License (unit-tested); this file owns persistence and UI.
//
// The first-launch date is recorded in BOTH UserDefaults and a file in
// Application Support, and the EARLIEST wins — deleting one of them doesn't
// restart the trial. (A determined attacker can beat any client-side trial;
// this only needs to keep honest households honest.)
final class LicenseManager {
    private static let keyDefault = "com.kiddyproof.license.key"
    private static let firstLaunchDefault = "com.kiddyproof.firstLaunch"

    private let supportMarker: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("kiddyproof/.firstrun")
    }()

    private(set) var firstLaunch: Date

    init() {
        var candidates: [Date] = []
        if let d = UserDefaults.standard.object(forKey: Self.firstLaunchDefault) as? Date {
            candidates.append(d)
        }
        if let text = try? String(contentsOf: supportMarker, encoding: .utf8),
           let t = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            candidates.append(Date(timeIntervalSince1970: t))
        }
        let resolved = candidates.min() ?? Date()
        firstLaunch = resolved
        // (Re)write both stores so a missing one is healed with the old date.
        UserDefaults.standard.set(resolved, forKey: Self.firstLaunchDefault)
        try? FileManager.default.createDirectory(at: supportMarker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(resolved.timeIntervalSince1970).write(to: supportMarker,
                                                          atomically: true, encoding: .utf8)
    }

    var storedKey: String? {
        UserDefaults.standard.string(forKey: Self.keyDefault)
    }

    var entitlement: License.Entitlement {
        License.entitlement(licenseKey: storedKey, firstLaunch: firstLaunch)
    }

    // Menu/status line, e.g. "Licensed ✓" or "Trial — 5 days left".
    var statusLine: String {
        switch entitlement {
        case .licensed: return "Licensed ✓"
        case .trial(let d): return "Free trial — \(d) day\(d == 1 ? "" : "s") left"
        case .expired: return "Trial ended — license required"
        }
    }

    // Try to store a key; returns the payload on success, nil if invalid.
    @discardableResult
    func store(key: String) -> License.Payload? {
        guard let payload = License.verify(key: key) else { return nil }
        UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: Self.keyDefault)
        return payload
    }

    // MARK: UI

    // Purchase page. One source of truth — shown in the paywall and the menu.
    static let purchaseURL = URL(string: "https://kiddyproof.app/buy")!

    // Modal license prompt. Returns true if a valid key was entered (or one
    // was already stored and still validates).
    func promptForLicense(reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "kiddyproof license"
        alert.informativeText = reason + "\n\nPaste your license key below, or choose Buy to get one."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "KIDDY.…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Buy kiddyproof…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if store(key: field.stringValue) != nil {
                confirm(title: "License activated",
                        text: "Thank you! kiddyproof is now fully unlocked on this Mac.")
                return true
            }
            confirm(title: "Invalid license key",
                    text: "That key didn't validate. Check for missing characters and try again.")
            return false
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Self.purchaseURL)
            return false
        default:
            return false
        }
    }

    private func confirm(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
