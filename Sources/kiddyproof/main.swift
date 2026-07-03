import AppKit

// Entry point. Runs as an .accessory app (no Dock icon, lives in the menu bar).
// Activation policy (.accessory) is set in AppController.applicationDidFinishLaunching,
// where it is documented as required for CGEventTap to work.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
