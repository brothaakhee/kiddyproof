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
| `TapHealthMonitor` (in `AppController`) | "A non-nil tap isn't a healthy tap" — proves live event flow before arming | synthetic event + heartbeat |
| `kiddywatchdog` | Separate tap-free process; SIGKILLs the app on livelock/timeout → input restored | `Process`, `kill(2)` |

## Build & run
```
swift build
./.build/debug/kiddyproof
```
Grant **Accessibility** when prompted, relaunch, then press **⌃⌥⌘K** (or use the menu-bar
🛡️ item) to enter kid mode. Exit by holding **⌃⌥⌘ for 3s** or **press-and-holding the
bottom-left corner for 3s**.

## Verified
- ✅ Builds clean (app + watchdog). ✅ Watchdog failsafe (heartbeat-loss, max-duration,
  clean-disarm). ✅ App boots, tap installs.
- 🖐️ End-to-end arm/block/effects/exit and the interception matrix require interactive
  testing — see `POC_TEST_PLAN.md`.

## Honest scope
This blocks all ordinary typing/clicking/scrolling and most chord shortcuts. It **cannot**
block the hardware power button, Force Quit, accessibility shortcuts, or multi-finger
Mission Control swipes (would need a root HID tap / DriverKit virtual-HID). It must refuse
to run when Secure Event Input is active. Not sandboxable / not Mac App Store — ships as a
Developer-ID-signed, notarized direct download. See `POC_TEST_PLAN.md` for the full list.
