import Cocoa

/// Purpose: Menu-bar agent that wires the monitor, curtain, and input filter together.
/// Lifecycle (the entire product):
///   connect    -> show curtain, block physical input, allow remote, keep displays awake
///   password   -> end the Screen Sharing session, drop the curtain (optionally confirm)
///   idle 30m   -> end session, lock the Mac, sleep displays
///   disconnect -> lock the Mac, sleep displays
/// SPORT: MASTER-APP
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SessionMonitor()
    private let curtain = CurtainController()
    private let input = InputFilter()
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenuBar()

        input.onPhysicalKey = { [weak self] kc, chars in self?.curtain.physicalKey(kc, chars) }

        curtain.onUnlock = { [weak self] in self?.unlockFromDesk() }

        monitor.onConnect = { [weak self] in self?.sessionStarted() }
        monitor.onDisconnect = { [weak self] in self?.sessionEnded(lock: true) }
        monitor.onIdleTimeout = { [weak self] in self?.idleTimedOut() }
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.curtain.tick()
        }

        if !AXIsProcessTrusted() { promptForAccessibility() }
    }

    // MARK: - Lifecycle handlers

    private func sessionStarted() {
        guard Config.shared.enabled else { return }
        curtain.show()
        System.preventDisplaySleep()
        if !input.start() { /* Accessibility missing; curtain still hides the screen */ }
        updateMenuBarState(active: true)
    }

    private func sessionEnded(lock: Bool) {
        input.stop()
        curtain.hide()
        System.allowDisplaySleep()
        updateMenuBarState(active: false)
        if lock {
            System.lockScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { System.sleepDisplays() }
        }
    }

    private func idleTimedOut() {
        System.endScreenShareSession()      // kick the idle remote operator
        sessionEnded(lock: true)
    }

    /// Host typed the correct password at the desk: end the remote session and reveal the desktop.
    private func unlockFromDesk() {
        input.stop()
        curtain.hide()
        System.allowDisplaySleep()
        updateMenuBarState(active: false)
        let alert = NSAlert()
        alert.messageText = "End the remote session?"
        alert.informativeText = "Unlocked at this Mac. Disconnect the active Screen Sharing session?"
        alert.addButton(withTitle: "Disconnect Remote")
        alert.addButton(withTitle: "Keep Connected")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            System.endScreenShareSession()
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarState(active: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "Curtain", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        func add(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self; menu.addItem(item); return item
        }
        let enabled = add("Armed", #selector(toggleEnabled))
        enabled.state = Config.shared.enabled ? .on : .off
        _ = add("Set Password…", #selector(setPassword))
        _ = add("Identify Displays", #selector(identifyDisplays))
        _ = add("Mark Current Externals as DisplayLink", #selector(markDisplayLink))
        menu.addItem(.separator())
        _ = add("Test Curtain (10s)", #selector(testCurtain))
        menu.addItem(.separator())
        _ = add("Quit Curtain", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func updateMenuBarState(active: Bool) {
        if let b = statusItem.button {
            b.title = active ? "🔒" : (Config.shared.enabled ? "👁" : "○")
        }
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        Config.shared.enabled.toggle(); Config.shared.save()
        item.state = Config.shared.enabled ? .on : .off
        if !Config.shared.enabled, curtain.isShown { sessionEnded(lock: false) }
        updateMenuBarState(active: curtain.isShown)
    }

    @objc private func setPassword() {
        let alert = NSAlert()
        alert.messageText = "Set Curtain Password"
        alert.informativeText = "Typed at the desk to end a remote session."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            Config.shared.setPassword(field.stringValue)
        }
    }

    @objc private func markDisplayLink() {
        // Externals = every non-built-in display. Practical default for DisplayLink setups.
        var serials: [UInt32] = []
        for s in NSScreen.screens {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
            if CGDisplayIsBuiltin(id) == 0 { serials.append(System.serial(of: s)) }
        }
        Config.shared.displayLinkSerials = serials; Config.shared.save()
        notify("Marked \(serials.count) display(s) as DisplayLink.")
    }

    @objc private func identifyDisplays() {
        // Briefly flash a big number on each display so the user knows the index/serial.
        var wins: [NSWindow] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let lbl = NSTextField(labelWithString: "\(i)\nserial \(System.serial(of: screen))")
            lbl.frame = NSRect(x: 0, y: screen.frame.height/2 - 120, width: screen.frame.width, height: 240)
            lbl.alignment = .center; lbl.font = .systemFont(ofSize: 120, weight: .bold)
            lbl.textColor = .white; lbl.backgroundColor = .clear; lbl.isBezeled = false; lbl.isEditable = false
            lbl.maximumNumberOfLines = 2
            w.contentView?.addSubview(lbl)
            w.orderFrontRegardless(); wins.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { wins.forEach { $0.orderOut(nil) } }
    }

    @objc private func testCurtain() {
        curtain.show(); System.preventDisplaySleep(); _ = input.start()
        updateMenuBarState(active: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.input.stop(); self?.curtain.hide(); System.allowDisplaySleep()
            self?.updateMenuBarState(active: false)
        }
    }

    @objc private func quit() { sessionEnded(lock: false); NSApp.terminate(nil) }

    // MARK: - Permission + notify

    private func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        notify("Grant Curtain Accessibility in System Settings, then relaunch, so it can block desk input.")
    }

    private func notify(_ text: String) {
        let a = NSAlert(); a.messageText = "Curtain"; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
