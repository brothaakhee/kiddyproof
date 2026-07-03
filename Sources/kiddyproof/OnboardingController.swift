import AppKit

// Parent-facing onboarding: a small paged window shown on first launch (and any time
// from the menu). Four pages: what this is → the Accessibility grant (live-polled,
// with the relaunch caveat) → the HONEST LIMITS disclosure the architecture mandates
// ("must disclose to parents" — in the product, not just in a markdown file) → how to
// enter and exit. The window is plain AppKit to match the rest of the app.
final class OnboardingController: NSObject {
    static let completedKey = "com.kiddyproof.onboarding.v1"

    private var window: NSWindow?
    private var pageIndex = 0
    private var permissionPoll: Timer?

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)

    var shouldShowOnLaunch: Bool {
        !UserDefaults.standard.bool(forKey: Self.completedKey)
    }

    private struct Page {
        let title: String
        let body: String
        let action: (label: String, run: () -> Void)?
    }

    private lazy var pages: [Page] = [
        Page(
            title: "Welcome to kiddyproof",
            body: """
            One shortcut turns your Mac into a safe, playful cage: your real screen stays \
            visible and untouched, while your child's typing, clicking, and scrolling is \
            swallowed before it can reach any app — and drives gentle visual effects instead.

            You keep working state exactly as you left it. Your child gets a screen that \
            responds to them. Nobody can send that email.
            """,
            action: nil),
        Page(
            title: "One permission: Accessibility",
            body: """
            Blocking input requires macOS's Accessibility permission (System Settings ▸ \
            Privacy & Security ▸ Accessibility). kiddyproof uses it for exactly one thing: \
            the event tap that swallows input while kid mode is on. Nothing is logged, \
            stored, or sent anywhere.

            Important: after granting, QUIT and RELAUNCH kiddyproof — macOS usually applies \
            the grant only to a freshly launched app.
            """,
            action: ("Open System Settings…", { Permissions.openAccessibilitySettings() })),
        Page(
            title: "Honest limits — please read once",
            body: """
            A few escapes sit below what any Mac app can intercept. We tell you exactly \
            where the edges are, so you never have to guess:

            • The hardware power / Touch ID button can still sleep or lock the Mac.
            • Force Quit (⌘⌥⎋) and accessibility shortcuts (like ⌘F5) are OS-reserved and \
            may get through.
            • A flat little hand on the trackpad can trigger 3/4-finger Mission Control or \
            Spaces swipes.
            • Closing the lid, or the idle auto-lock, ends the session (kiddyproof keeps \
            the display awake while armed, but can't stop the lid).
            • If a password field or an app with Secure Keyboard Entry is focused, macOS \
            makes keystrokes unblockable — kiddyproof refuses to start, and exits loudly if \
            it happens mid-session.
            • Over another app in native fullscreen (a video, a game) the visual effects \
            can't paint — input is still blocked there.

            For everything else — ordinary typing, clicking, scrolling, and most shortcuts \
            — kid mode verifies its own blocking continuously, and an independent watchdog \
            process ends the session if anything ever wedges. Best for roughly ages 1–3: \
            old enough to love cause and effect, young enough not to copy your exit gesture.
            """,
            action: nil),
        Page(
            title: "In and out",
            body: """
            Enter: press ⌃⌥⌘K, or use the 🛡️ menu-bar icon.

            Exit (two ways, both deliberate 3-second holds a mashing child can't produce):
            • Hold the ⌃⌥⌘ keys for 3 seconds, or
            • Press-and-hold the mouse in the BOTTOM-LEFT corner for 3 seconds.
            A progress ring fills as you hold.

            Sessions also end on their own at the session limit (set it in Settings; \
            2 minutes by default) — so a forgotten kid mode never runs all day.
            """,
            action: nil),
    ]

    func showIfNeeded() {
        if shouldShowOnLaunch { show() }
    }

    func show() {
        if window == nil { buildWindow() }
        pageIndex = 0
        renderPage()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "kiddyproof"
        w.isReleasedWhenClosed = false

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.preferredMaxLayoutWidth = 500
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        actionButton.target = self
        actionButton.action = #selector(runPageAction)
        backButton.target = self
        backButton.action = #selector(goBack)
        nextButton.target = self
        nextButton.action = #selector(goNext)
        nextButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [backButton, NSView(), actionButton, statusLabel, NSView(), nextButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, bodyLabel, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 28),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -28),
        ])
        w.contentView = content
        window = w
    }

    private func renderPage() {
        let page = pages[pageIndex]
        titleLabel.stringValue = page.title
        bodyLabel.stringValue = page.body
        backButton.isHidden = pageIndex == 0
        nextButton.title = pageIndex == pages.count - 1 ? "Done" : "Continue"

        if let action = page.action {
            actionButton.isHidden = false
            actionButton.title = action.label
        } else {
            actionButton.isHidden = true
        }

        // Live permission status on the Accessibility page.
        permissionPoll?.invalidate(); permissionPoll = nil
        if pageIndex == 1 {
            updatePermissionStatus()
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updatePermissionStatus()
            }
            RunLoop.main.add(t, forMode: .common)
            permissionPoll = t
        } else {
            statusLabel.stringValue = ""
        }
    }

    private func updatePermissionStatus() {
        if Permissions.isAccessibilityTrusted() {
            statusLabel.stringValue = "✓ Granted"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "Not granted yet"
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func runPageAction() {
        pages[pageIndex].action?.run()
    }

    @objc private func goBack() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        renderPage()
    }

    @objc private func goNext() {
        if pageIndex < pages.count - 1 {
            pageIndex += 1
            renderPage()
        } else {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            permissionPoll?.invalidate(); permissionPoll = nil
            window?.orderOut(nil)
        }
    }
}
