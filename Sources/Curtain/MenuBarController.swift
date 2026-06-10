import Cocoa

/// Purpose: Optional menu-bar presence (the curtains glyph) with quick actions.
///          Reflects active + armed state and routes actions to the coordinator.
/// SPORT: MASTER-MENUBAR
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var armedItem: NSMenuItem?
    private weak var coordinator: SessionCoordinator?
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onQuit: (() -> Void)?

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator; super.init() }

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = CurtainIcon.menuBarImage()
        let menu = NSMenu()
        add(menu, "Open Curtain Settings…", #selector(openSettings))
        add(menu, "Setup…", #selector(openSetup))
        menu.addItem(.separator())
        armedItem = add(menu, "Armed", #selector(toggleArmed))
        add(menu, "Activate Now", #selector(activate))
        add(menu, "Deactivate", #selector(deactivate))
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
        img.isTemplate = !active     // active = tinted/filled, idle = template (adapts)
        button.image = img
        button.contentTintColor = active ? NSColor.systemRed : nil
    }

    /// Update the Armed menu item state and the icon tooltip.
    func reflect(armed: Bool) {
        armedItem?.state = armed ? .on : .off
        statusItem?.button?.toolTip = armed ? "Armed" : "Disarmed"
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
    @objc private func test() { coordinator?.testCurtain(seconds: 10) }
    @objc private func quit() { onQuit?() }
}
