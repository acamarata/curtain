import Foundation
import CryptoKit

/// Purpose: Single source of truth for every Curtain preference, backed by
///          UserDefaults so the SwiftUI settings view (@AppStorage) and the
///          headless coordinator read/write the exact same keys.
/// Inputs: none (reads/writes the standard user defaults under the keys below).
/// Outputs: typed get/set accessors + password helpers.
/// Constraints: password is stored as a salted SHA256 hash, never plaintext.
/// SPORT: MASTER-SETTINGS
enum Settings {

    /// Defaults key strings. The SwiftUI view binds to these same strings via @AppStorage.
    enum Key {
        static let launchAtLogin       = "launchAtLogin"
        static let showInMenuBar       = "showInMenuBar"
        // On session start
        static let onStartActivate     = "onStart.activateCurtain"
        // On idle
        static let idleEnabled         = "idle.enabled"
        static let idleMinutes         = "idle.minutes"
        static let onIdleDisconnect    = "onIdle.disconnect"
        static let onIdleLock          = "onIdle.lock"
        static let onIdleScreenOff     = "onIdle.screenOff"
        static let onIdleDeactivate    = "onIdle.deactivate"
        // On session end (disconnect)
        static let onEndLock           = "onEnd.lock"
        static let onEndScreenOff      = "onEnd.screenOff"
        static let onEndDeactivate     = "onEnd.deactivate"
        // On password entered at the desk
        static let onPasswordDisconnect = "onPassword.disconnect"
        // Security + displays
        static let passwordHash        = "password.hash"
        static let passwordSalt        = "password.salt"
        static let displayLinkSerials  = "displayLinkSerials"
    }

    /// Register sensible defaults once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.launchAtLogin: true,
            Key.showInMenuBar: true,
            Key.onStartActivate: true,
            Key.idleEnabled: true,
            Key.idleMinutes: 30,
            Key.onIdleDisconnect: true,
            Key.onIdleLock: true,
            Key.onIdleScreenOff: true,
            Key.onIdleDeactivate: true,
            Key.onEndLock: true,
            Key.onEndScreenOff: true,
            Key.onEndDeactivate: true,
            Key.onPasswordDisconnect: true,
        ])
    }

    // MARK: - Typed accessors (headless side)
    private static let d = UserDefaults.standard
    static var launchAtLogin: Bool { get { d.bool(forKey: Key.launchAtLogin) } set { d.set(newValue, forKey: Key.launchAtLogin) } }
    static var showInMenuBar: Bool { get { d.bool(forKey: Key.showInMenuBar) } set { d.set(newValue, forKey: Key.showInMenuBar) } }
    static var onStartActivate: Bool { d.bool(forKey: Key.onStartActivate) }
    static var idleEnabled: Bool { d.bool(forKey: Key.idleEnabled) }
    static var idleMinutes: Int { max(1, d.integer(forKey: Key.idleMinutes)) }
    static var onPasswordDisconnect: Bool { d.bool(forKey: Key.onPasswordDisconnect) }

    static var onIdle: ActionSet {
        ActionSet(disconnect: d.bool(forKey: Key.onIdleDisconnect),
                  lock: d.bool(forKey: Key.onIdleLock),
                  screenOff: d.bool(forKey: Key.onIdleScreenOff),
                  deactivateCurtain: d.bool(forKey: Key.onIdleDeactivate))
    }
    static var onEnd: ActionSet {
        ActionSet(disconnect: false,                                   // already disconnected
                  lock: d.bool(forKey: Key.onEndLock),
                  screenOff: d.bool(forKey: Key.onEndScreenOff),
                  deactivateCurtain: d.bool(forKey: Key.onEndDeactivate))
    }

    static var displayLinkSerials: [UInt32] {
        get { (d.array(forKey: Key.displayLinkSerials) as? [Int])?.map { UInt32(truncatingIfNeeded: $0) } ?? [] }
        set { d.set(newValue.map { Int($0) }, forKey: Key.displayLinkSerials) }
    }

    // MARK: - Password
    static func setPassword(_ plain: String) {
        var salt = d.string(forKey: Key.passwordSalt) ?? ""
        if salt.isEmpty { salt = randomSalt(); d.set(salt, forKey: Key.passwordSalt) }
        d.set(hash(plain, salt: salt), forKey: Key.passwordHash)
    }
    /// Verify a candidate. If no password is set, the built-in "curtain" is accepted
    /// so the Mac is never unrecoverable.
    static func verify(_ candidate: String) -> Bool {
        let stored = d.string(forKey: Key.passwordHash) ?? ""
        if stored.isEmpty { return candidate == "curtain" }
        return hash(candidate, salt: d.string(forKey: Key.passwordSalt) ?? "") == stored
    }
    static var hasPassword: Bool { !(d.string(forKey: Key.passwordHash) ?? "").isEmpty }

    private static func randomSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    private static func hash(_ s: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + s).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
