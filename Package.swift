// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kiddyproof",
    platforms: [.macOS(.v14)],
    targets: [
        // The main agent app: owns the suppressing event tap, the overlay, effects,
        // cursor control, secure-input guard and the exit gesture.
        .executableTarget(
            name: "kiddyproof",
            path: "Sources/kiddyproof"
        ),
        // A separate, tap-free helper process. Because it never installs a tap it can
        // never be wedged by Secure Event Input / TCC revocation / tap timeout, so it is
        // the load-bearing parent-lockout failsafe: it SIGKILLs the main app on heartbeat
        // loss or max-duration, and process death tears the tap down -> input restored.
        .executableTarget(
            name: "kiddywatchdog",
            path: "Sources/kiddywatchdog"
        ),
    ]
)
