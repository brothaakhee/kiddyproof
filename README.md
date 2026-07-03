# kiddyproof

A native macOS app that lets a parent hand the keyboard to a small child without the kid
affecting any real work. One shortcut drops a transparent "kid mode" cage over the screen:
the real desktop stays visible and untouched, **all** typing/clicking/scrolling is swallowed
before it reaches any app, and the input instead drives playful visual feedback (click
ripples, big flying letters, a black-hole cursor). Only a deliberate parent gesture exits.

This repo is a **proof-of-concept** that validates the load-bearing mechanisms. The
architecture was designed and adversarially stress-tested before any code was written (see
`docs/ARCHITECTURE.md`).

## How it works (the real mechanism)

The blocking is **not** done by the overlay — it's done by a **`CGEventTap`**. The overlay
is purely visual.

| Component | Responsibility | Key APIs |
|---|---|---|
| `InputSuppressor` | Suppressing session tap on a dedicated thread; swallows input, copies a tiny summary for visuals | `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap)` |
| `CursorController` | Freezes & hides the real cursor (the tap alone does NOT stop pointer motion) | `CGAssociateMouseAndMouseCursorPosition`, `CGDisplayHideCursor` |
| `OverlayWindowManager` | Transparent shielding-level panel per screen; shows real desktop through it; 2nd input barrier | `NSPanel`, `CGShieldingWindowLevel()` |
| `EffectsView` | Permission-free Core Graphics feedback driven by the event ring buffer | `NSView`/`CoreGraphics` |
| `ExitGestureController` | Mouse corner-hold (survives Secure Input) + ⌃⌥⌘ chord, 3s hold | timer + observed deltas |
| `SecureInputGuard` | Refuses to arm / bails if Secure Event Input is active (irreducible gap) | `IsSecureEventInputEnabled()` |
| `TapHealthMonitor` | Continuous 1 Hz probe while armed: verify → re-enable → recreate → fail-loud disarm | synthetic event + heartbeat |
| `kiddywatchdog` | Separate tap-free process; SIGKILLs the app on livelock/timeout → input restored. Pings require real tap flow; watchdog death is detected and disarms loudly | `Process`, `kill(2)` |
| `OnboardingController` | First-launch parent flow: permission grant (live-polled) + the honest-limits disclosure in-product | AppKit |
| OS hardening (armed) | Kiosk `presentationOptions` (no Force Quit / app switching), display-sleep prevention, clean disarm on sleep/lock/fast-user-switch, display-reconfig reconciliation | `NSApplication.presentationOptions`, `IOPMAssertion`, `NSWorkspace` |

## Build & run
```
swift build
./.build/debug/kiddyproof
```
Grant **Accessibility** when prompted, relaunch, then press **⌃⌥⌘K** (or use the menu-bar
🛡️ item) to enter kid mode. Exit by holding **⌃⌥⌘ for 3s** or **press-and-holding the
bottom-left corner for 3s**.

## Build, test, package
```
swift build                      # debug build (app + watchdog)
swift test                       # unit tests: settings clamping, watchdog protocol/enforcement, exit-gesture timing
Scripts/package.sh               # release .app bundle + DMG (ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=kiddyproof Scripts/package.sh   # ship
```

## Verified
- ✅ Builds clean (app + watchdog). ✅ Unit tests pass (KiddyproofCore).
- ✅ Watchdog failsafe live-drilled: heartbeat-loss kill, max-duration kill, clean disarm.
- ✅ App boots, tap installs, full arm→effects→clean-exit cycle in the KP_DEMO harness.
- 🖐️ The physical-input interception matrix and secure-input/TCC-revocation drills
  require interactive testing at the machine — see `POC_TEST_PLAN.md`.

## Honest scope
This blocks all ordinary typing/clicking/scrolling and most chord shortcuts. It **cannot**
block the hardware power button, Force Quit, accessibility shortcuts, or multi-finger
Mission Control swipes (would need a root HID tap / DriverKit virtual-HID). It must refuse
to run when Secure Event Input is active. Not sandboxable / not Mac App Store — ships as a
Developer-ID-signed, notarized direct download. See `POC_TEST_PLAN.md` for the full list.
