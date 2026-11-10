# kiddyproof

A native macOS app that lets a parent hand the keyboard to a small child without the kid
affecting any real work. One shortcut drops a transparent "kid mode" cage over the screen:
the real desktop stays visible and untouched, **all** typing/clicking/scrolling is swallowed
before it reaches any app, and the input instead drives playful visual feedback (click
ripples, big flying letters, a black-hole cursor). Only a deliberate parent gesture exits.

**Download:** [kiddyproof.app](https://kiddyproof.app) ·
[Releases](https://github.com/brothaakhee/kiddyproof-releases/releases) —
macOS 14 Sonoma+, Apple Silicon. 3-day free trial, then a one-time license.
Developer-ID signed; auto-updates via Sparkle. Source is MIT-licensed (this
repo); signed, notarized binaries ship from the releases repo.

**Who it's for:** parents of toddlers and preschoolers who want to let a kid bang on the
laptop — or sit in on a video call — without losing a document, closing a tab, or
emailing the boss.

**Built with:** Swift 5.9 + AppKit, Core Graphics event taps and drawing,
SceneKit/GLTFSceneKit for the 3D cat, Sparkle 2 for updates, and Swift Package
Manager. The landing page is static HTML on Caddy; the purchase-activation
service is a small Node server; download metering is a Cloudflare Worker.

The architecture was designed and adversarially stress-tested before any code was
written (see `docs/ARCHITECTURE.md`).

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
swift test                       # unit tests: settings clamping, watchdog protocol/enforcement, exit-gesture timing, licensing
Scripts/package.sh               # release .app bundle + DMG (ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=kiddyproof VERSION=1.0.0 Scripts/package.sh   # ship
```

## License keys (seller side)
License keys are offline Ed25519 signatures verified in
`Sources/KiddyproofCore/License.swift` — no server, no phone-home. The private
key lives in `secrets/` (gitignored; **back it up**). Issue a customer key:
```
swift Scripts/make_license.swift issue customer@example.com
```
The app grants a 3-day trial from first launch; arming kid mode after that
requires a key (menu bar → Enter License Key…).

## Site & updates
`site/` is the kiddyproof.app landing page + Sparkle appcast, deployed on
Railway. Each release: build the DMG, attach it to a GitHub Release on
`kiddyproof-releases`, add the `sign_update` enclosure line to
`site/appcast.xml`, redeploy the site.

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

## Roadmap
See [`ROADMAP.md`](ROADMAP.md).

## License
MIT — see [`LICENSE`](LICENSE). Third-party pieces keep their own licenses:
[Sparkle](https://github.com/sparkle-project/Sparkle) (MIT-style),
[GLTFSceneKit](https://github.com/magicien/GLTFSceneKit) (MIT), the Fraunces and
Hanken Grotesk webfonts (SIL Open Font License 1.1). The 3D cat meshes in `Assets/`
were generated for this project with Meshy. The parked `plant-canalisation` branch
ports code from [aj-dev-smith/canalisation](https://github.com/aj-dev-smith/canalisation) (MIT).
