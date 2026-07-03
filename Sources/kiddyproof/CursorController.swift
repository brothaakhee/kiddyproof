import AppKit
import CoreGraphics

// Freezing the cursor is NOT automatic: returning nil from the tap still lets the
// physical pointer move (verified), so it could still trigger hot corners or reveal
// the Dock. We decouple the cursor from the hardware and hide it; the overlay draws
// its own "black hole" cursor from the deltas the tap observes.
//
// These calls are foreground-only, so the app activates itself before arming. Restore
// is made crash-safe with signal/atexit handlers — if the app dies the cursor must
// always come back.
// The bare CG restore sequence as a top-level function: only async-signal-safe CG calls,
// no captured context — so it can be referenced from atexit / signal C function pointers
// as well as from restore(). Single source of truth for the safety-critical un-hide.
private func kpRestoreCursorRaw() {
    CGAssociateMouseAndMouseCursorPosition(1)
    CGDisplayShowCursor(CGMainDisplayID())
}

enum CursorController {
    private static var hidden = false

    static func freezeAndHide() {
        NSApp.activate(ignoringOtherApps: true)
        CGAssociateMouseAndMouseCursorPosition(0) // decouple physical movement
        CGDisplayHideCursor(CGMainDisplayID())
        // Re-associate immediately after hiding to dodge the known "cursor won't hide"
        // ordering bug while keeping it hidden.
        CGAssociateMouseAndMouseCursorPosition(0)
        hidden = true
        installCrashSafeRestore()
    }

    static func restore() {
        guard hidden else { return }
        kpRestoreCursorRaw()
        hidden = false
    }

    private static var installedHandlers = false
    private static func installCrashSafeRestore() {
        guard !installedHandlers else { return }
        installedHandlers = true
        atexit { kpRestoreCursorRaw() }
        for sig in [SIGINT, SIGTERM, SIGSEGV, SIGABRT] {
            signal(sig) { _ in
                kpRestoreCursorRaw()
                _exit(1)
            }
        }
    }
}
