import Foundation
import ServiceManagement

/// Purpose: Toggle "open at login" via the modern SMAppService API (macOS 13+).
///          Only works for a real installed app bundle; a no-op when run loose.
///          `public` because the thin `Curtain` executable (AppDelegate,
///          PreferencesWindow, OnboardingWindow) calls `set(_:)` across the
///          CurtainCore module boundary.
/// Scope note (T-P1-E08-03, confirmed against Apple's SMAppService docs): this file
///          governs ONLY whether Curtain launches at the NEXT login via
///          `SMAppService.mainApp` — that API has no KeepAlive/crash-relaunch
///          semantics and does nothing if the already-running process dies mid-
///          session. Runtime crash-relaunch supervision is a SEPARATE, independent
///          registration — `SMAppService.agent`, see AppSupervisor.swift in the
///          `Curtain` executable target — deliberately left untouched here so the
///          two concerns (launch-at-login vs. crash supervision) can't couple.
/// SPORT: MASTER-LOGINITEM
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Curtain: login item toggle failed: \(error.localizedDescription)")
        }
    }
}
