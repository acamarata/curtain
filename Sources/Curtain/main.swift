import Cocoa

// Curtain — a privacy curtain for macOS Screen Sharing.
// Entry point: a background menu-bar agent (no Dock icon).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
