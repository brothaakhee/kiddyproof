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
        // glTF/GLB loader bridging into SceneKit — used for the animated 3D cat.
        // Source-built (no binary artifacts), pinned to master: the last tagged
        // release predates modern Swift.
        .package(url: "https://github.com/magicien/GLTFSceneKit", branch: "master"),
    ],
    targets: [
        // Pure, UI-free logic shared by both executables — and unit-testable: settings
        // model + clamping, the watchdog wire protocol/enforcement state machine, and
        // the exit-gesture hold timing.
        .target(
            name: "KiddyproofCore",
            path: "Sources/KiddyproofCore"
        ),
        // The auxin-canalisation plant simulation, ported from
        // github.com/aj-dev-smith/canalisation. Pure Foundation/simd with no UI and no
        // AppKit, so the whole developmental model — margin patterning, blade
        // canalisation, phyllotaxis — is unit-testable headlessly against the
        // reference implementation's own test harnesses.
        .target(
            name: "CanalSim",
            path: "Sources/CanalSim"
        ),
        // The main agent app: owns the suppressing event tap, the overlay, effects,
        // cursor control, secure-input guard and the exit gesture.
        .executableTarget(
            name: "kiddyproof",
            dependencies: [
                "KiddyproofCore",
                "CanalSim",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GLTFSceneKit", package: "GLTFSceneKit"),
            ],
            path: "Sources/kiddyproof",
            resources: [
                // Quaternius animated cat (Public Domain / CC0, poly.pizza).
                .copy("Resources/cat.glb"),
                // Shading for the canalisation plant. Copied rather than compiled
                // into a metallib: CanalRenderer builds it at launch, so there is
                // one source of truth and no dependence on how SwiftPM chooses to
                // treat a .metal file inside an executable target.
                .copy("Resources/CanalShaders.metal"),
            ]
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
        // Fidelity tests for the canalisation port: the structures the model is
        // supposed to produce (teeth from convergence points, a vein hierarchy,
        // reproducibility from a seed) checked against the reference's own numbers.
        .testTarget(
            name: "CanalSimTests",
            dependencies: ["CanalSim"],
            path: "Tests/CanalSimTests"
        ),
    ]
)
