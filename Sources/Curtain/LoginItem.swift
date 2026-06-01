import Foundation
import ServiceManagement

/// Purpose: Toggle "open at login" via the modern SMAppService API (macOS 13+).
///          Only works for a real installed app bundle; a no-op when run loose.
/// SPORT: MASTER-LOGINITEM
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } }
        } catch {
            NSLog("Curtain: login item toggle failed: \(error.localizedDescription)")
        }
    }
}
