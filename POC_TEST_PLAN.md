# kiddyproof POC — Test Plan

Proves the three riskiest mechanisms end-to-end: (1) a suppressing `CGEventTap` that
blocks keyboard+mouse+scroll while still observing events, (2) a transparent overlay +
cursor freeze, (3) a survivable two-channel exit backed by an external watchdog.

## Status legend
- ✅ verified automatically in this environment
- 🖐️ requires interactive testing at the machine (cannot be done headlessly)

## Build & run
```
swift build
./.build/debug/kiddyproof          # menu-bar 🛡️ icon; no Dock icon (.accessory)
```
First run will prompt for **Accessibility** (System Settings ▸ Privacy & Security ▸
Accessibility). Grant it, then **relaunch** — TCC grants for the suppressing tap usually
need a relaunch to take effect.

## Automated results (already run; last updated 2026-07-03)
- ✅ `swift build` — all targets (`kiddyproof`, `kiddywatchdog`, `KiddyproofCore`) compile clean.
- ✅ `swift test` — 21 unit tests pass: settings clamping/codable, watchdog protocol +
  enforcement verdicts (heartbeat loss, deadline, disarm, re-arm), exit-gesture hold
  timing incl. a 60s deterministic random-mash simulation that never fires.
- ✅ Watchdog **heartbeat-loss kill**: victim goes silent → SIGKILLed in ~3s (live drill).
- ✅ Watchdog **max-duration auto-exit**: deadline reached → SIGKILLed in ~1.2s (live drill).
  Note: the max-duration SIGKILL is now the *backstop*; an in-app timer ends ordinary
  sessions cleanly 10s before the watchdog deadline.
- ✅ Watchdog **clean disarm**: after `DISARM`, silence does NOT kill.
- ✅ App boots, launches watchdog, installs the tap in idle/pass-through.
- ✅ Full KP_DEMO cycle with the hardened safety core: arm (health-gated, watchdog-gated,
  kiosk flags + sleep assertion), effects run, clean in-app exit, watchdog DISARM + EOF
  shutdown.
- ✅ **Secure-input hard-refuse observed live**: with Secure Keyboard Entry active
  system-wide, the app refused to arm (drill E1's first half) — verified 2026-07-03.
- ✅ `Scripts/package.sh` — release build → `dist/kiddyproof.app` (Info.plist lints,
  Sparkle.framework embedded, watchdog beside the main binary, ad-hoc + hardened-runtime
  signed) → `dist/kiddyproof-0.1.0.dmg`. Developer-ID signing + notarization take
  `SIGN_IDENTITY` / `NOTARY_PROFILE` env vars (see script header).

## Interactive checklist (🖐️ run these at the machine)

### A. Core suppression
1. Open **TextEdit** and **Safari** underneath. Arm kid mode (⌃⌥⌘K).
2. Mash the keyboard → **nothing** should appear in TextEdit.
3. Click/scroll wildly → Safari must **not** click links or scroll.
4. Confirm fun feedback renders: click ripples, big rising letters, black-hole cursor.

### B. Interception matrix — record BLOCKED vs LEAKED
Expected from the research: the first group is blocked, the second group **leaks** and is
the parent-facing residual-risk disclosure.

Expected BLOCKED: ⌘Space (Spotlight), ⌘Tab (app switcher), ⌘Q, ⌘Shift-4 (screenshot),
ordinary typing/clicking/scrolling, Mission Control **key**.

Expected LEAKED (cannot be blocked by a non-root session tap):
- Hardware power / Touch ID button (sleep/lock/power dialog)
- Force Quit ⌘⌥⎋
- Accessibility shortcuts (⌘F5 VoiceOver, triple-press Touch ID, ⌥⌘8 Zoom)
- 3/4-finger Mission Control / Spaces / Launchpad **trackpad swipes**
- Media/brightness keys on some hardware

### C. Cursor freeze
- During kid mode the **system cursor must not move** (hot corners / Dock reveal must NOT
  trigger). The app draws its own black-hole cursor from observed deltas.
- On exit the real cursor reappears. Force-crash the app (`kill -SEGV <pid>`) → cursor
  must still come back (crash-safe restore).

### D. Exit gestures (both must work; neither must trigger by random mashing)
- **Mouse corner-hold (primary):** press-and-hold in the bottom-left corner 3s → green
  progress ring fills → exits. Works even under Secure Input.
- **Modifier chord (secondary):** hold ⌃⌥⌘ for 3s → exits.
- Have someone mash randomly for 30s → must NOT accidentally exit.

### E. Secure Event Input gap (irreducible)
1. Open Terminal ▸ enable **Secure Keyboard Entry**. Try to arm → app must **refuse**
   with a clear message.
2. Arm kid mode first, then focus a password field / enable Secure Keyboard Entry → the
   secure-input poll must **bail loudly** and exit kid mode.

### F. Lockout drills (parent must ALWAYS regain control)
1. `kill -STOP <kiddyproof pid>` (simulate livelock) → watchdog SIGKILLs it; input returns
   within ~2-3s. ✅ (mechanism verified in isolation)
2. Revoke Accessibility in System Settings mid-session → watchdog restores input.
3. Wait out the 120s max duration → auto-exit fires. ✅ (mechanism verified)

### G. Signed/notarized build (surfaces the real silent-disable race)
Build an `.app`, sign with Developer ID + Hardened Runtime, notarize, staple, and launch
from `/Applications` via Finder (NOT Xcode/CLI). The health gate must refuse to show ARMED
if no events flow.

## Known irreducible limitations (disclose to parents)
- Secure Event Input blinds keystroke blocking (handled by refuse/bail).
- Power button, Force Quit, accessibility shortcuts, multi-finger Mission Control swipes
  cannot be guaranteed-blocked without a root HID tap or DriverKit virtual-HID (Karabiner-
  class effort) — out of scope for v1.
- Another app in **native fullscreen** (Safari video, Keynote, a game) or Stage Manager:
  the overlay renders behind it. Input is still tap-blocked, but the visual cage/FX are
  absent there.
- The "warp the real desktop" black-hole effect needs ScreenCaptureKit + Screen Recording
  permission (Tier B, opt-in, not in this POC).
