# Roadmap

kiddyproof 1.0.4 is shipped and selling. This is the work ahead, roughly in order.

## Verification
- **Run the interactive drills in `POC_TEST_PLAN.md`** — the interception matrix (B),
  cursor freeze (C), exit gestures (D), Secure Event Input (E), lockout drills (F) and the
  signed/notarized silent-disable race (G) — and record BLOCKED vs LEAKED per row.
- **Automate what the drills prove.** Turn the interception matrix into a repeatable
  harness built on synthetic `CGEvent`s and the `KP_DEMO` path, so a macOS update that
  changes event-tap behavior fails a test instead of a parent.

## Safety and coverage
- **Thermal downgrade.** Drop effect density when `ProcessInfo.thermalState` rises
  (the TODO in `docs/ARCHITECTURE.md`).
- **Metal renderer.** Move effects off the 60 Hz CoreGraphics timer when profiling
  shows it's needed. This also unblocks the parked plant scene.
- **Close the honest-scope gaps where possible.** Research a DriverKit virtual-HID path
  for multi-finger Mission Control swipes and accessibility shortcuts, which a session
  event tap cannot block.

## Play
- **KiddyCat.** Finish the 3D cat the site calls a work in progress: more reactions,
  idle behaviors, and keyboard-driven tricks.
- **Plant scene.** Resume the auxin-canalisation scene parked on the
  `plant-canalisation` branch once the Metal renderer lands.
- **Effects Tier B.** Opt-in ScreenCaptureKit "warp the real desktop" effects, which
  need the Screen Recording permission (`docs/ARCHITECTURE.md` → WarpRenderer).

## Distribution
- **Intel Macs.** Ship a universal (arm64 + x86_64) build; today's releases are Apple
  Silicon only.
- **Paywall experiments.** Evaluate the no-trial hard paywall on the `hard-paywall`
  branch against the current 3-day trial, using the edge download and install counts.
