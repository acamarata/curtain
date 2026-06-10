import Foundation
import CommonCrypto

/// Purpose: Single source of truth for every Curtain preference, backed by
///          UserDefaults so the SwiftUI settings view (@AppStorage) and the
///          headless coordinator read/write the exact same keys.
/// Inputs: none (reads/writes the standard user defaults under the keys below).
/// Outputs: typed get/set accessors, password helpers, lockout backoff state.
/// Constraints: passwords are stored as a PBKDF2-HMAC-SHA256 derived key, never
///              plaintext. Every default is chosen so the user can never be locked
///              out: the fallback password "curtain" always works when no hash is
///              set, and the disconnect feature ships off. Settings is a plain
///              enum of static funcs over the thread-safe UserDefaults.standard,
///              so it is safe to call from any thread under Swift 6 concurrency.
/// SPORT: MASTER-SETTINGS
enum Settings {

    /// Defaults key strings. The SwiftUI view binds to these same strings via @AppStorage.
    enum Key {
        // General
        static let armed                = "armed"
        static let launchAtLogin        = "launchAtLogin"
        static let showInMenuBar        = "showInMenuBar"
        // Activation
        static let onStartActivate      = "onStart.activateCurtain"
        static let connectGraceSeconds  = "connect.graceSeconds"
        static let notifyOnActivate     = "notifyOnActivate"
        static let playSoundOnActivate  = "playSoundOnActivate"
        // Reveal trigger (how the desk user pops the password box)
        static let revealTrigger        = "reveal.trigger"   // "anyKey" | "keyCombo"
        static let revealKeyCombo       = "reveal.keyCombo"  // e.g. "cmd+shift+L"; empty when anyKey
        // Appearance
        // cover.style accepts: "solidColor" | "message" | "blur" | "logo" | "curtainLogo" | "aerial"
        // ("screensaver" is legacy and is treated as "logo".)
        static let coverStyle           = "cover.style"
        static let coverColor           = "cover.color"
        static let coverMessage         = "cover.message"
        static let coverShowClock       = "cover.showClock"
        // Idle
        static let idleEnabled          = "idle.enabled"
        static let idleMinutes          = "idle.minutes"
        static let idleSource           = "idle.source"
        static let onIdleDisconnect     = "onIdle.disconnect"
        static let onIdleLock           = "onIdle.lock"
        static let onIdleScreenOff      = "onIdle.screenOff"
        static let onIdleDeactivate     = "onIdle.deactivate"
        // End (disconnect)
        static let onEndLock            = "onEnd.lock"
        static let onEndScreenOff       = "onEnd.screenOff"
        static let onEndDeactivate      = "onEnd.deactivate"
        // Security
        static let onPasswordDisconnect = "onPassword.disconnect"   // legacy bool, kept readable
        static let onUnlockAction       = "onUnlock.action"         // "keepSession" | "disconnect"
        static let migratedOnUnlock     = "migrated.onUnlock"       // one-time migration guard
        static let migratedCoverScope   = "migrated.coverScope"     // one-time migration guard
        static let passwordBoxTimeoutSeconds        = "password.boxTimeoutSeconds"
        static let requirePasswordToDeactivateFromMenu = "requirePasswordToDeactivateFromMenu"
        static let accessibilityMissingBehavior     = "accessibility.missingBehavior"
        // Disconnect feature
        static let disconnectFeatureEnabled = "disconnect.featureEnabled"
        // Displays
        static let displayLinkUUIDs     = "displayLinkUUIDs"
        static let displayLinkSerials   = "displayLinkSerials"   // legacy [Int], read-only fallback
        static let perDisplayCoverDisabled = "perDisplayCoverDisabled"
        static let coverScope           = "cover.scope"
        static let passwordBoxPlacement = "passwordBox.placement"
        static let passwordBoxSpecificUUID = "passwordBox.specificUUID"
        static let newDisplayPolicy     = "newDisplay.policy"
        // Advanced
        static let diagnosticsLoggingEnabled = "diagnostics.loggingEnabled"
        static let hasOnboarded         = "hasOnboarded"
        // Password (PBKDF2)
        static let passwordAlgo         = "password.algo"
        static let passwordSalt         = "password.salt"
        static let passwordIterations   = "password.iterations"
        static let passwordHash         = "password.hash"
    }

    /// Register sensible, safe defaults once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.armed: true,
            Key.launchAtLogin: true,
            Key.showInMenuBar: true,
            Key.revealTrigger: "anyKey",
            Key.revealKeyCombo: "",
            Key.onUnlockAction: "disconnect",
            Key.onStartActivate: true,
            Key.connectGraceSeconds: 2,
            Key.notifyOnActivate: true,
            Key.playSoundOnActivate: false,
            Key.coverStyle: "logo",
            Key.coverColor: "#000000",
            Key.coverMessage: "",
            Key.coverShowClock: false,
            Key.idleEnabled: true,
            Key.idleMinutes: 30,
            Key.idleSource: "sessionInput",
            Key.onIdleDisconnect: true,
            Key.onIdleLock: true,
            Key.onIdleScreenOff: true,
            Key.onIdleDeactivate: true,
            Key.onEndLock: true,
            Key.onEndScreenOff: true,
            Key.onEndDeactivate: true,
            Key.onPasswordDisconnect: true,
            Key.passwordBoxTimeoutSeconds: 15,
            Key.requirePasswordToDeactivateFromMenu: false,
            Key.accessibilityMissingBehavior: "warn",
            Key.disconnectFeatureEnabled: false,
            Key.coverScope: "all",
            Key.passwordBoxPlacement: "followActive",
            Key.passwordBoxSpecificUUID: "",
            Key.newDisplayPolicy: "cover",
            Key.diagnosticsLoggingEnabled: false,
            Key.hasOnboarded: false,
            Key.passwordIterations: 200_000,
        ])
        migrateOnUnlockAction()
        migrateCoverScope()
    }

    /// One-time migration: the old boolean `onPassword.disconnect` is replaced by the
    /// explicit `onUnlock.action` choice. If the user had disconnect turned on and never
    /// set the new key, carry that intent forward. Guarded so it runs at most once.
    private static func migrateOnUnlockAction() {
        guard !d.bool(forKey: Key.migratedOnUnlock) else { return }
        let legacyOn = d.object(forKey: Key.onPasswordDisconnect) != nil
            && d.bool(forKey: Key.onPasswordDisconnect)
        let newSet = d.object(forKey: Key.onUnlockAction) != nil
        if legacyOn && !newSet {
            d.set("disconnect", forKey: Key.onUnlockAction)
        }
        d.set(true, forKey: Key.migratedOnUnlock)
    }

    /// One-time migration: the old "onlyMarked" / "allExceptMarked" cover-scope values are
    /// collapsed into "perDisplay", which uses the per-display Cover toggle as the authority.
    /// Guarded so it runs at most once.
    private static func migrateCoverScope() {
        guard !d.bool(forKey: Key.migratedCoverScope) else { return }
        let legacy = d.string(forKey: Key.coverScope) ?? ""
        if legacy == "onlyMarked" || legacy == "allExceptMarked" {
            d.set("perDisplay", forKey: Key.coverScope)
        }
        d.set(true, forKey: Key.migratedCoverScope)
    }

    private static let d = UserDefaults.standard

    // MARK: - General
    static var armed: Bool { get { d.bool(forKey: Key.armed) } set { d.set(newValue, forKey: Key.armed) } }
    static var launchAtLogin: Bool { get { d.bool(forKey: Key.launchAtLogin) } set { d.set(newValue, forKey: Key.launchAtLogin) } }
    static var showInMenuBar: Bool { get { d.bool(forKey: Key.showInMenuBar) } set { d.set(newValue, forKey: Key.showInMenuBar) } }

    // MARK: - Reveal trigger
    static var revealTrigger: String { get { d.string(forKey: Key.revealTrigger) ?? "anyKey" } set { d.set(newValue, forKey: Key.revealTrigger) } }
    static var revealKeyCombo: String { get { d.string(forKey: Key.revealKeyCombo) ?? "" } set { d.set(newValue, forKey: Key.revealKeyCombo) } }
    /// True when any keypress should pop the password box; false only when a specific combo is required.
    static var revealOnAnyKey: Bool { revealTrigger != "keyCombo" }

    // MARK: - Activation
    static var onStartActivate: Bool { d.bool(forKey: Key.onStartActivate) }
    static var connectGraceSeconds: Int { clamp(d.integer(forKey: Key.connectGraceSeconds), 0, 30) }
    static var notifyOnActivate: Bool { d.bool(forKey: Key.notifyOnActivate) }
    static var playSoundOnActivate: Bool { d.bool(forKey: Key.playSoundOnActivate) }

    // MARK: - Appearance
    static var coverStyle: String { d.string(forKey: Key.coverStyle) ?? "logo" }
    static var coverColorHex: String { d.string(forKey: Key.coverColor) ?? "#000000" }
    static var coverMessage: String { d.string(forKey: Key.coverMessage) ?? "" }
    static var coverShowClock: Bool { d.bool(forKey: Key.coverShowClock) }

    // MARK: - Idle
    static var idleEnabled: Bool { d.bool(forKey: Key.idleEnabled) }
    static var idleMinutes: Int { clamp(d.integer(forKey: Key.idleMinutes), 1, 240) }
    static var idleSourceIsHID: Bool { (d.string(forKey: Key.idleSource) ?? "hidIdle") == "hidIdle" }

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

    // MARK: - Security
    static var onPasswordDisconnect: Bool { d.bool(forKey: Key.onPasswordDisconnect) }
    /// On curtain unlock: drop the remote session, or keep it running. Replaces onPasswordDisconnect.
    static var unlockDisconnect: Bool { d.string(forKey: Key.onUnlockAction) == "disconnect" }
    static var passwordBoxTimeoutSeconds: Int { clamp(d.integer(forKey: Key.passwordBoxTimeoutSeconds), 5, 60) }
    static var requirePasswordToDeactivateFromMenu: Bool { d.bool(forKey: Key.requirePasswordToDeactivateFromMenu) }
    static var accessibilityRefuseToArm: Bool { (d.string(forKey: Key.accessibilityMissingBehavior) ?? "warn") == "refuseToArm" }

    // MARK: - Disconnect feature
    static var disconnectFeatureEnabled: Bool { d.bool(forKey: Key.disconnectFeatureEnabled) }

    // MARK: - Displays
    static var displayLinkUUIDs: [String] {
        get { (d.array(forKey: Key.displayLinkUUIDs) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.displayLinkUUIDs) }
    }
    /// Legacy serials kept for read-only `isDisplayLink` fallback during migration.
    static var legacyDisplayLinkSerials: [UInt32] {
        (d.array(forKey: Key.displayLinkSerials) as? [Int])?.map { UInt32(truncatingIfNeeded: $0) } ?? []
    }
    static var perDisplayCoverDisabled: [String] {
        get { (d.array(forKey: Key.perDisplayCoverDisabled) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.perDisplayCoverDisabled) }
    }
    static var coverScope: String { d.string(forKey: Key.coverScope) ?? "all" }
    static var passwordBoxPlacement: String { d.string(forKey: Key.passwordBoxPlacement) ?? "followActive" }
    static var passwordBoxSpecificUUID: String { d.string(forKey: Key.passwordBoxSpecificUUID) ?? "" }
    static var newDisplayPolicy: String { d.string(forKey: Key.newDisplayPolicy) ?? "cover" }

    /// One-time migration: if a display has no UUID record yet but its serial is
    /// in the legacy list, the caller can use this to treat it as a DisplayLink.
    static func isLegacyDisplayLink(serial: UInt32) -> Bool {
        legacyDisplayLinkSerials.contains(serial)
    }

    // MARK: - Advanced
    static var diagnosticsLoggingEnabled: Bool { d.bool(forKey: Key.diagnosticsLoggingEnabled) }
    static var hasOnboarded: Bool { get { d.bool(forKey: Key.hasOnboarded) } set { d.set(newValue, forKey: Key.hasOnboarded) } }

    // MARK: - Password (PBKDF2-HMAC-SHA256)

    /// Derive and store a new password. Generates a fresh 16-byte salt each time.
    static func setPassword(_ plain: String) {
        let salt = randomBytes(16)
        let iterations = currentIterations()
        let derived = pbkdf2(password: plain, salt: salt, iterations: iterations)
        d.set("pbkdf2", forKey: Key.passwordAlgo)
        d.set(hex(salt), forKey: Key.passwordSalt)
        d.set(iterations, forKey: Key.passwordIterations)
        d.set(hex(derived), forKey: Key.passwordHash)
    }

    /// Verify a candidate. When no password is set, the built-in "curtain" is
    /// accepted so the Mac is never unrecoverable. A legacy salted-SHA256 hash is
    /// verified once and, on success, transparently upgraded to PBKDF2.
    static func verify(_ candidate: String) -> Bool {
        let storedHash = d.string(forKey: Key.passwordHash) ?? ""
        if storedHash.isEmpty { return candidate == "curtain" }

        let algo = d.string(forKey: Key.passwordAlgo) ?? ""
        if algo == "pbkdf2" {
            guard let saltBytes = bytes(fromHex: d.string(forKey: Key.passwordSalt) ?? "") else { return false }
            let iterations = currentIterations()
            let derived = pbkdf2(password: candidate, salt: saltBytes, iterations: iterations)
            return constantTimeEquals(hex(derived), storedHash)
        }

        // Legacy salted-SHA256: verify against the old scheme, then upgrade on success.
        let legacySalt = d.string(forKey: Key.passwordSalt) ?? ""
        if constantTimeEquals(legacySHA256(candidate, salt: legacySalt), storedHash) {
            setPassword(candidate)
            return true
        }
        return false
    }

    static var hasPassword: Bool { !(d.string(forKey: Key.passwordHash) ?? "").isEmpty }

    private static func currentIterations() -> Int {
        max(100_000, d.integer(forKey: Key.passwordIterations))
    }

    // MARK: - Attempt backoff (in-memory, self-contained)

    nonisolated(unsafe) private static var failureCount = 0
    nonisolated(unsafe) private static var lockoutUntil: Date?

    static func registerFailedAttempt() {
        failureCount += 1
        // Exponential: 1s, 2s, 4s, ... capped at 30s, starting after 3 misses.
        guard failureCount >= 3 else { return }
        let delay = min(30.0, pow(2.0, Double(failureCount - 3)))
        lockoutUntil = Date().addingTimeInterval(delay)
    }

    static func resetFailedAttempts() {
        failureCount = 0
        lockoutUntil = nil
    }

    static var isLockedOut: Bool { backoffRemaining > 0 }

    static var backoffRemaining: TimeInterval {
        guard let until = lockoutUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    // MARK: - Crypto helpers

    private static func pbkdf2(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = pw.withUnsafeBufferPointer { pwPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress, pwPtr.count,
                    saltPtr.baseAddress, saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &out, out.count)
            }
        }
        return out
    }

    private static func legacySHA256(_ s: String, salt: String) -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Array((salt + s).utf8)
        data.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &out) }
        return hex(out)
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Length-aware constant-time string compare to avoid timing leaks on the hash.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let av = Array(a.utf8), bv = Array(b.utf8)
        var diff = av.count ^ bv.count
        let n = max(av.count, bv.count)
        for i in 0..<n {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
