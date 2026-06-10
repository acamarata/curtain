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

// The AppKit bootstrap is main-actor work; top-level code is nonisolated under Swift 6,
// so run it inside an assumeIsolated block (process start is already on the main thread).
// app.run() blocks here and never returns, so `delegate` and the signal source stay
// retained on this stack. NSApplication.delegate is weak, so `delegate` must be held.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)     // background agent; settings window still shows

    // SIGTERM (launchd stop / `kill`): a C signal handler can't safely touch AppKit, so
    // ignore the default action and route the signal through a DispatchSource on the main
    // queue, where it can run cleanup before exiting.
    signal(SIGTERM, SIG_IGN)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        MainActor.assumeIsolated { delegate.cleanup() }
        exit(0)
    }
    sigtermSource.resume()

    app.run()
}
