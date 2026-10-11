import Cocoa

/// Purpose: Reliably bring a window of this menu-bar (accessory) app to the front.
///          An accessory app launched while another app is frontmost often fails to
///          raise its window with `activate(ignoringOtherApps:)`, which on macOS 14+ is
///          also deprecated and cooperative-only. Switching to the regular activation
///          policy while a setup window is open gives it a Dock icon and normal
///          activation; it returns to accessory when the window closes.
/// SPORT: MASTER-APP
@MainActor
enum WindowFronting {
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        activateApp()
        let id = ObjectIdentifier(window)
        guard closeObservers[id] == nil else { return }
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let token = closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(token)
                }
                // Stay regular while any other titled window (e.g. Settings) is still open.
                let othersOpen = NSApp.windows.contains {
                    $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
                }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
