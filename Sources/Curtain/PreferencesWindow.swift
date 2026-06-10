import SwiftUI
import AppKit
import CurtainShared

/// Purpose: The single settings window. Every Curtain preference is a control here,
///          grouped by concern and bound to the same UserDefaults keys the headless
///          coordinator reads, so a change in the UI takes effect live.
/// Inputs: a SessionCoordinator (for the manual actions) plus a handful of injected
///          closures the AppDelegate wires (onboarding, menu-bar toggle).
/// Outputs: writes to UserDefaults via @AppStorage + Settings helpers; invokes the
///          coordinator and injected closures for side effects.
/// Constraints: SwiftUI + AppKit run on the main actor; the controller is @MainActor.
///          The coordinator is held weakly inside the escaping closures so the window
///          never extends the coordinator's lifetime. Bindings use Settings.Key.*
///          constants so keys match the headless side byte-for-byte.
/// SPORT: MASTER-PREFS
@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?
    private weak var coordinator: SessionCoordinator?
    var onMenuBarToggle: ((Bool) -> Void)?
    /// Wired by the AppDelegate to reopen the first-run setup flow.
    var openOnboarding: (() -> Void)?

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = PreferencesView(
            activateNow: { [weak coordinator] in coordinator?.activateNow() },
            testNow: { [weak coordinator] in coordinator?.testCurtain(seconds: 10) },
            markDisplayLink: { Self.markExternalsAsDisplayLink() },
            identifyDisplays: { Self.identifyDisplays() },
            enableDisconnectHelper: { [weak coordinator] on in coordinator?.enableDisconnectHelper(on) },
            openOnboarding: { [weak self] in self?.openOnboarding?() },
            onMenuBarToggle: { [weak self] on in self?.onMenuBarToggle?(on) }
        )
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Curtain"
        w.contentViewController = NSHostingController(rootView: view)
        w.setContentSize(NSSize(width: 620, height: 560))
        w.contentMinSize = NSSize(width: 600, height: 520)
        w.center(); w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Display helpers (shared with the menu)

    /// Mark every external (non-builtin) display as a DisplayLink, keyed by the
    /// stable per-display UUID so the mapping survives reboots and port changes.
    static func markExternalsAsDisplayLink() {
        var uuids: [String] = []
        for s in NSScreen.screens {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(id) == 0, let u = System.uuid(of: s) { uuids.append(u) }
        }
        Settings.displayLinkUUIDs = uuids
        let a = NSAlert(); a.messageText = "Curtain"
        a.informativeText = "Marked \(uuids.count) external display(s) as DisplayLink."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    /// Flash a big index + short UUID on each screen so the user can tell them apart.
    static func identifyDisplays() {
        var wins: [NSWindow] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let shortID = System.uuid(of: screen).map { String($0.prefix(8)) } ?? "unknown"
            let lbl = NSTextField(labelWithString: "\(i)\n\(shortID)")
            lbl.frame = NSRect(x: 0, y: screen.frame.height / 2 - 130, width: screen.frame.width, height: 260)
            lbl.alignment = .center; lbl.font = .systemFont(ofSize: 110, weight: .bold)
            lbl.textColor = .white; lbl.backgroundColor = .clear; lbl.isBezeled = false
            lbl.isEditable = false; lbl.maximumNumberOfLines = 2
            w.contentView?.addSubview(lbl); w.orderFrontRegardless(); wins.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { wins.forEach { $0.orderOut(nil) } }
    }
}

// MARK: - Settings import/export shape

/// A flat, versioned snapshot of every persisted preference, used for Export/Import.
struct SettingsSnapshot: Codable {
    var version = 1
    var values: [String: AnyCodable] = [:]
}

/// Minimal AnyCodable so a heterogeneous defaults dictionary survives JSON round-trips.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else { value = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [String]: try c.encode(a.map(AnyCodable.init))
        default: try c.encode("")
        }
    }
}

// MARK: - The SwiftUI settings form

private struct PreferencesView: View {
    // State shared across tabs that need to refresh or toggle together.
    @State private var hasPassword = Settings.hasPassword
    /// Bumped to force the dynamic display list to re-read after a Cover/DisplayLink toggle.
    @State private var displayRefresh = 0

    let activateNow: () -> Void
    let testNow: () -> Void
    let markDisplayLink: () -> Void
    let identifyDisplays: () -> Void
    let enableDisconnectHelper: (Bool) -> Void
    let openOnboarding: () -> Void
    let onMenuBarToggle: (Bool) -> Void

    /// The settings sections, shown as a System Settings style sidebar. Each case
    /// carries its sidebar title and SF Symbol; the order here is the sidebar order.
    private enum PrefSection: String, Identifiable, Hashable, CaseIterable {
        case general, appearance, idleEnd, security, disconnect, displays, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:    return "General"
            case .appearance: return "Appearance"
            case .idleEnd:    return "Idle & End"
            case .security:   return "Security"
            case .disconnect: return "Disconnect"
            case .displays:   return "Displays"
            case .advanced:   return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general:    return "gearshape"
            case .appearance: return "paintbrush"
            case .idleEnd:    return "moon.zzz"
            case .security:   return "lock.shield"
            case .disconnect: return "network.slash"
            case .displays:   return "display"
            case .advanced:   return "slider.horizontal.3"
            }
        }
    }

    @State private var selection: PrefSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: .infinity,
               minHeight: 560, idealHeight: 560, maxHeight: .infinity)
    }

    /// An always-visible source-list sidebar. A plain List inside the HStack keeps the
    /// translucent System Settings look without the split view that kept collapsing.
    /// Adapts the non-optional selection to the optional binding List wants for single
    /// selection. A nil set (clicking empty space) is ignored so a section is always shown.
    private var sidebarSelection: Binding<PrefSection?> {
        Binding<PrefSection?>(
            get: { selection },
            set: { if let new = $0 { selection = new } }
        )
    }

    private var sidebar: some View {
        List(PrefSection.allCases, selection: sidebarSelection) { section in
            Label(section.title, systemImage: section.symbol)
                .tag(section)
        }
        .listStyle(.sidebar)
    }

    /// The right-hand content for the selected sidebar section.
    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            PrefGeneralTab(
                activateNow: activateNow,
                testNow: testNow,
                onMenuBarToggle: onMenuBarToggle
            )
        case .appearance:
            PrefAppearanceTab()
        case .idleEnd:
            PrefIdleEndTab()
        case .security:
            PrefSecurityTab(hasPassword: $hasPassword)
        case .disconnect:
            PrefDisconnectTab(enableDisconnectHelper: enableDisconnectHelper)
        case .displays:
            PrefDisplaysTab(
                displayRefresh: displayRefresh,
                identifyDisplays: identifyDisplays,
                markDisplayLink: markDisplayLink,
                onMarkDisplayLink: { displayRefresh += 1 }
            )
        case .advanced:
            PrefAdvancedTab(
                openOnboarding: openOnboarding,
                exportSettings: exportSettings,
                importSettings: importSettings,
                resetToDefaults: resetToDefaults
            )
        }
    }

    // MARK: - Reset / Export / Import

    private func resetToDefaults() {
        let d = UserDefaults.standard
        for key in Self.exportableKeys { d.removeObject(forKey: key) }
        Settings.registerDefaults()
        LoginItem.set(d.bool(forKey: Settings.Key.launchAtLogin))
        hasPassword = Settings.hasPassword
        displayRefresh += 1
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Curtain-Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let d = UserDefaults.standard
        var snapshot = SettingsSnapshot()
        for key in Self.exportableKeys {
            if let obj = d.object(forKey: key) { snapshot.values[key] = AnyCodable(obj) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) { try? data.write(to: url) }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) else { return }
        let d = UserDefaults.standard
        for (key, wrapped) in snapshot.values where Self.exportableKeys.contains(key) {
            d.set(wrapped.value, forKey: key)
        }
        LoginItem.set(d.bool(forKey: Settings.Key.launchAtLogin))
        hasPassword = Settings.hasPassword
        displayRefresh += 1
    }

    /// Every non-secret preference key, used by Reset/Export/Import. Password hash,
    /// salt, and algo are deliberately excluded so a snapshot never leaks the secret.
    /// armDisarmHotkey removed — EmergencyHotkey is intentionally hardcoded and there
    /// is no runtime reader for that key.
    static let exportableKeys: [String] = [
        Settings.Key.armed, Settings.Key.launchAtLogin, Settings.Key.showInMenuBar,
        Settings.Key.onStartActivate, Settings.Key.connectGraceSeconds, Settings.Key.notifyOnActivate, Settings.Key.playSoundOnActivate,
        Settings.Key.coverStyle, Settings.Key.coverColor, Settings.Key.coverMessage, Settings.Key.coverShowClock,
        Settings.Key.revealTrigger, Settings.Key.revealKeyCombo,
        Settings.Key.idleEnabled, Settings.Key.idleMinutes, Settings.Key.idleSource,
        Settings.Key.onIdleDisconnect, Settings.Key.onIdleLock, Settings.Key.onIdleScreenOff, Settings.Key.onIdleDeactivate,
        Settings.Key.onEndLock, Settings.Key.onEndScreenOff, Settings.Key.onEndDeactivate,
        Settings.Key.onUnlockAction, Settings.Key.passwordBoxTimeoutSeconds,
        Settings.Key.requirePasswordToDeactivateFromMenu, Settings.Key.accessibilityMissingBehavior,
        Settings.Key.disconnectFeatureEnabled,
        Settings.Key.displayLinkUUIDs, Settings.Key.perDisplayCoverDisabled,
        Settings.Key.coverScope, Settings.Key.passwordBoxPlacement, Settings.Key.passwordBoxSpecificUUID, Settings.Key.newDisplayPolicy,
        Settings.Key.diagnosticsLoggingEnabled,
    ]
}
