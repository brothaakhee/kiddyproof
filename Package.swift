// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kiddyproof",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Update channel for the direct-download app. Only active when running from a
        // packaged .app whose Info.plist carries SUFeedURL (see Scripts/package.sh);
        // plain `swift run` development builds skip Sparkle entirely.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure, UI-free logic shared by both executables — and unit-testable: settings
        // model + clamping, the watchdog wire protocol/enforcement state machine, and
        // the exit-gesture hold timing.
        .target(
            name: "KiddyproofCore",
            path: "Sources/KiddyproofCore"
        ),
        // The main agent app: owns the suppressing event tap, the overlay, effects,
        // cursor control, secure-input guard and the exit gesture.
        .executableTarget(
            name: "kiddyproof",
            dependencies: [
                "KiddyproofCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/kiddyproof"
        ),
        // A separate, tap-free helper process. Because it never installs a tap it can
        // never be wedged by Secure Event Input / TCC revocation / tap timeout, so it is
        // the load-bearing parent-lockout failsafe: it SIGKILLs the main app on heartbeat
        // loss or max-duration, and process death tears the tap down -> input restored.
        .executableTarget(
            name: "kiddywatchdog",
            dependencies: ["KiddyproofCore"],
            path: "Sources/kiddywatchdog"
        ),
        .testTarget(
            name: "KiddyproofCoreTests",
            dependencies: ["KiddyproofCore"],
            path: "Tests/KiddyproofCoreTests"
        ),
    ]
)
