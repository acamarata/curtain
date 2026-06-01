import Cocoa

// Curtain — a privacy curtain for macOS Screen Sharing.
// Normally launches as a background menu-bar agent (no Dock icon).
//
// Hidden build helper: `Curtain --render-icon <dir>` writes an .iconset of PNGs so
// install.sh can build AppIcon.icns without shipping any image assets.

if CommandLine.arguments.contains("--render-icon"),
   let dirIndex = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.indices.contains(dirIndex + 1) {
    CurtainIcon.exportIconset(to: CommandLine.arguments[dirIndex + 1])   // offscreen bitmap render
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // background agent; settings window still shows
app.run()
