import AppKit
import Sparkle

// Sparkle update channel, active ONLY when running as a packaged .app whose
// Info.plist carries SUFeedURL (Scripts/package.sh writes it). Development builds
// (`swift run`, bare executable) have no bundle identity, so Sparkle is skipped
// entirely and the "Check for Updates…" menu item is hidden.
enum UpdaterSupport {
    private static var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool { controller != nil }

    static func startIfPackaged() {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            NSLog("[kiddyproof] not a packaged bundle (or no SUFeedURL) — updater disabled.")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
