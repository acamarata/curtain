import Cocoa

/// Purpose: Optional menu-bar presence (the curtains glyph) with quick actions.
///          Can be shown/hidden per the "Show in menu bar" setting.
/// SPORT: MASTER-MENUBAR
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var coordinator: SessionCoordinator?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator; super.init() }

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = CurtainIcon.menuBarImage()
        let menu = NSMenu()
        add(menu, "Open Curtain Settings…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Activate Now", #selector(activate))
        add(menu, "Deactivate", #selector(deactivate))
        add(menu, "Test Curtain (10s)", #selector(test))
        menu.addItem(.separator())
        add(menu, "Quit Curtain", #selector(quit), key: "q")
        item.menu = menu
        statusItem = item
        reflect(active: coordinator?.isActive ?? false)
    }

    func hide() {
        if let i = statusItem { NSStatusBar.system.removeStatusItem(i) }
        statusItem = nil
    }

    /// Update the icon to reflect active/idle. Active = highlighted (non-template).
    func reflect(active: Bool) {
        guard let button = statusItem?.button else { return }
        let img = CurtainIcon.menuBarImage()
        img.isTemplate = !active     // active = tinted/filled, idle = template (adapts)
        button.image = img
        button.contentTintColor = active ? NSColor.systemRed : nil
    }

    // MARK: - Actions
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func activate() { coordinator?.activateNow() }
    @objc private func deactivate() { coordinator?.deactivateNow() }
    @objc private func test() { coordinator?.testCurtain() }
    @objc private func quit() { onQuit?() }
}
