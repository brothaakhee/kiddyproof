import AppKit

// No-cloud crash detection, in keeping with the product's "no account, no cloud"
// promise: a marker file exists exactly while the app runs; finding one at launch
// means the previous run ended uncleanly (crash, SIGKILL — including a watchdog
// rescue). We tell the parent once and offer a pre-filled email report. Nothing is
// collected or sent automatically.
enum CrashSentinel {
    private static var markerURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kiddyproof", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.marker")
    }()

    // Call early at launch. Returns true if the PREVIOUS run ended uncleanly.
    @discardableResult
    static func begin() -> Bool {
        let unclean = FileManager.default.fileExists(atPath: markerURL.path)
        FileManager.default.createFile(atPath: markerURL.path, contents: Data("running\n".utf8))
        return unclean
    }

    // Call on every clean shutdown path.
    static func endCleanly() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func offerReport() {
        let a = NSAlert()
        a.messageText = "kiddyproof didn't shut down cleanly last time"
        a.informativeText = """
        That can be a crash — or the safety watchdog doing its job and force-ending a \
        wedged session (which is by design). If this keeps happening, we'd like to know. \
        Nothing is reported automatically; kiddyproof never phones home.
        """
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Email a Report…")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let body = "What was happening when it ended?\n\n—\nkiddyproof \(version), macOS \(os)"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:hello@kiddyproof.app?subject=kiddyproof%20crash%20report&body=\(body)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
