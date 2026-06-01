import SwiftUI
import AppKit

/// Purpose: The single settings window (Caffeine-style). Binds to the same
///          UserDefaults keys the coordinator reads, so changes take effect live.
/// SPORT: MASTER-PREFS
final class PreferencesWindowController {
    private var window: NSWindow?
    private weak var coordinator: SessionCoordinator?
    var onMenuBarToggle: ((Bool) -> Void)?

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = PreferencesView(
            activateNow: { [weak self] in self?.coordinator?.activateNow() },
            testNow: { [weak self] in self?.coordinator?.testCurtain() },
            markDisplayLink: { Self.markExternalsAsDisplayLink() },
            identifyDisplays: { Self.identifyDisplays() },
            onMenuBarToggle: { [weak self] on in self?.onMenuBarToggle?(on) }
        )
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Curtain"
        w.contentViewController = NSHostingController(rootView: view)
        w.center(); w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Display helpers (shared with menu)

    static func markExternalsAsDisplayLink() {
        var serials: [UInt32] = []
        for s in NSScreen.screens {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
            if CGDisplayIsBuiltin(id) == 0 { serials.append(System.serial(of: s)) }
        }
        Settings.displayLinkSerials = serials
        let a = NSAlert(); a.messageText = "Curtain"
        a.informativeText = "Marked \(serials.count) external display(s) as DisplayLink."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    static func identifyDisplays() {
        var wins: [NSWindow] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let lbl = NSTextField(labelWithString: "\(i)\nserial \(System.serial(of: screen))")
            lbl.frame = NSRect(x: 0, y: screen.frame.height/2 - 130, width: screen.frame.width, height: 260)
            lbl.alignment = .center; lbl.font = .systemFont(ofSize: 110, weight: .bold)
            lbl.textColor = .white; lbl.backgroundColor = .clear; lbl.isBezeled = false
            lbl.isEditable = false; lbl.maximumNumberOfLines = 2
            w.contentView?.addSubview(lbl); w.orderFrontRegardless(); wins.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { wins.forEach { $0.orderOut(nil) } }
    }
}

/// The SwiftUI settings form.
private struct PreferencesView: View {
    // App
    @AppStorage(Settings.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Settings.Key.showInMenuBar) private var showInMenuBar = true
    // Start
    @AppStorage(Settings.Key.onStartActivate) private var onStartActivate = true
    // Idle
    @AppStorage(Settings.Key.idleEnabled) private var idleEnabled = true
    @AppStorage(Settings.Key.idleMinutes) private var idleMinutes = 30
    @AppStorage(Settings.Key.onIdleDisconnect) private var idleDisconnect = true
    @AppStorage(Settings.Key.onIdleLock) private var idleLock = true
    @AppStorage(Settings.Key.onIdleScreenOff) private var idleScreenOff = true
    @AppStorage(Settings.Key.onIdleDeactivate) private var idleDeactivate = true
    // End
    @AppStorage(Settings.Key.onEndLock) private var endLock = true
    @AppStorage(Settings.Key.onEndScreenOff) private var endScreenOff = true
    @AppStorage(Settings.Key.onEndDeactivate) private var endDeactivate = true
    // Password
    @AppStorage(Settings.Key.onPasswordDisconnect) private var passwordDisconnect = true
    @State private var newPassword = ""

    let activateNow: () -> Void
    let testNow: () -> Void
    let markDisplayLink: () -> Void
    let identifyDisplays: () -> Void
    let onMenuBarToggle: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                group("Application") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { LoginItem.set($0) }
                    Toggle("Show in menu bar", isOn: $showInMenuBar)
                        .onChange(of: showInMenuBar) { onMenuBarToggle($0) }
                    HStack {
                        Button("Activate Now", action: activateNow)
                        Button("Test (10s)", action: testNow)
                    }
                }

                group("On session start") {
                    Toggle("Activate curtain when a remote session begins", isOn: $onStartActivate)
                }

                group("On session idle") {
                    Toggle("Act after the session is idle", isOn: $idleEnabled)
                    if idleEnabled {
                        Stepper("Idle timeout: \(idleMinutes) min", value: $idleMinutes, in: 1...240)
                        Toggle("Disconnect the remote session", isOn: $idleDisconnect)
                        Toggle("Lock the Mac", isOn: $idleLock)
                        Toggle("Turn off the displays", isOn: $idleScreenOff)
                        Toggle("Deactivate the curtain", isOn: $idleDeactivate)
                    }
                }

                group("On session end (disconnect)") {
                    Toggle("Lock the Mac", isOn: $endLock)
                    Toggle("Turn off the displays", isOn: $endScreenOff)
                    Toggle("Deactivate the curtain", isOn: $endDeactivate)
                }

                group("Security") {
                    Toggle("Disconnect remote when password is entered at the desk", isOn: $passwordDisconnect)
                    HStack {
                        SecureField("New unlock password", text: $newPassword)
                        Button("Set") { if !newPassword.isEmpty { Settings.setPassword(newPassword); newPassword = "" } }
                    }
                    Text(Settings.hasPassword ? "A password is set." : "No password set (default: “curtain”).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                group("Displays") {
                    Text("DisplayLink monitors can't be hidden invisibly; mark them so the curtain covers them too.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Identify Displays", action: identifyDisplays)
                        Button("Mark Externals as DisplayLink", action: markDisplayLink)
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: CurtainIcon.appIcon(size: 48))
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading) {
                Text("Curtain").font(.title2).bold()
                Text("Privacy for macOS Screen Sharing").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2).bold().foregroundStyle(.secondary)
            content()
        }
    }
}
