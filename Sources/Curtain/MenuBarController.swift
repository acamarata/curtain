import Cocoa
import CurtainCore

/// Purpose: Optional menu-bar presence (the curtains glyph) with quick actions.
///          Reflects active + armed state and routes actions to the coordinator.
/// SPORT: MASTER-MENUBAR
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var armedItem: NSMenuItem?
    private weak var coordinator: SessionCoordinator?
    // Latest known active/armed flags, tracked independently so reflect(active:)
    // and reflect(armed:) — which each only receive one half of the state — can
    // still recompute a single combined accessibility label reflecting both.
    private var lastActive = false
    private var lastArmed = false
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onQuit: (() -> Void)?

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator; super.init() }

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = CurtainIcon.menuBarImage()
        item.button?.setAccessibilityLabel("Curtain")
        let menu = NSMenu()
        add(menu, "Open Curtain Settings…", #selector(openSettings))
        add(menu, "Setup…", #selector(openSetup))
        menu.addItem(.separator())
        armedItem = add(menu, "Armed", #selector(toggleArmed))
        add(menu, "Activate Now", #selector(activate))
        add(menu, "Deactivate", #selector(deactivate))
        // Accessible equivalent of EmergencyHotkey.swift's fixed Control+Option+Command+U
        // combo (see that file's doc comment): a VoiceOver/keyboard-reachable menu item
        // that performs the SAME unconditional force-deactivate (coordinator.deactivateNow(),
        // not the gated requestDeactivateFromMenu() the "Deactivate" item above uses), so
        // users who can't discover or physically perform the 4-key chord still have an
        // escape that bypasses requirePasswordToDeactivateFromMenu. NOTE: unlike the
        // Carbon hotkey (which needs no Accessibility permission to itself fire), this
        // menu item's reachability depends on VoiceOver/Switch Control/keyboard menu
        // navigation, which macOS gates on Accessibility trust for the assistive tech —
        // so this is a secondary/best-effort path, not a full guarantee-parity with the
        // hotkey. See T-P1-E07-03 acceptance evidence for the full investigation.
        add(menu, "Force Deactivate (Emergency)", #selector(forceDeactivate))
        add(menu, "Test Curtain (10s)", #selector(test))
        menu.addItem(.separator())
        add(menu, "Quit Curtain", #selector(quit), key: "q")
        item.menu = menu
        statusItem = item
        reflect(active: coordinator?.isActive ?? false)
        reflect(armed: coordinator?.isArmed ?? false)
    }

    func hide() {
        if let i = statusItem { NSStatusBar.system.removeStatusItem(i) }
        statusItem = nil
        armedItem = nil
    }

    /// Update the icon to reflect active/idle. Active = highlighted (non-template).
    func reflect(active: Bool) {
        guard let button = statusItem?.button else { return }
        let img = CurtainIcon.menuBarImage()
        img.isTemplate = !active  // active = tinted/filled, idle = template (adapts)
        button.image = img
        button.contentTintColor = active ? NSColor.systemRed : nil
        lastActive = active
        updateAccessibilityLabel()
    }

    /// Update the Armed menu item state and the icon tooltip.
    func reflect(armed: Bool) {
        armedItem?.state = armed ? .on : .off
        statusItem?.button?.toolTip = armed ? "Armed" : "Disarmed"
        lastArmed = armed
        updateAccessibilityLabel()
    }

    /// Recompute the status item's VoiceOver label from the latest known
    /// active/armed flags. toolTip (line above) is left untouched — toolTip is
    /// not a reliable VoiceOver source for NSStatusItem buttons, so this is an
    /// addition, not a replacement, of the existing visual/hover behavior.
    private func updateAccessibilityLabel() {
        let armedPart = lastArmed ? "armed" : "disarmed"
        let activePart = lastActive ? "session active" : "idle"
        statusItem?.button?.setAccessibilityLabel("Curtain: \(armedPart), \(activePart)")
    }

    // MARK: - Actions
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSetup() { onOpenSetup?() }
    @objc private func toggleArmed() {
        guard let coordinator else { return }
        coordinator.setArmed(!coordinator.isArmed)
        reflect(armed: coordinator.isArmed)
    }
    @objc private func activate() { coordinator?.activateNow() }
    @objc private func deactivate() {
        // If gated, the coordinator already presented the password box; nothing else to do.
        _ = coordinator?.requestDeactivateFromMenu()
    }
    /// Accessible equivalent of EmergencyHotkey's force-deactivate. Calls the identical
    /// unconditional path the hotkey handler calls (SessionCoordinator.deactivateNow()) —
    /// deliberately NOT requestDeactivateFromMenu(), which the "Deactivate" item above
    /// uses and which can refuse when requirePasswordToDeactivateFromMenu is on. See the
    /// menu-construction comment above and EmergencyHotkey.swift's doc comment.
    @objc private func forceDeactivate() { coordinator?.deactivateNow() }
    @objc private func test() { coordinator?.testCurtain(seconds: 10) }
    @objc private func quit() { onQuit?() }
}
