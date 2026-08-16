import Foundation
import CommonCrypto
import Security

/// Purpose: Password hashing/verification and attempt-backoff state for
///          Settings — the security-sensitive cluster split out of the core
///          config file so each resulting file stays under the 300-line cap.
/// Inputs: candidate passwords from PasswordBox; reads/writes the password
///         material (algo/salt/iterations/hash) via the Keychain helpers
///         below (T-P1-E06-01 — previously plain UserDefaults, see
///         Settings+Migrations.swift's migratePasswordToKeychain() for the
///         one-time upgrade path).
/// Outputs: setPassword/verify/hasPassword for the password round-trip;
///          registerFailedAttempt/resetFailedAttempts/isLockedOut/
///          backoffRemaining for the in-memory lockout backoff.
/// Constraints: passwords are stored as a PBKDF2-HMAC-SHA256 derived key,
///              never plaintext. The fallback password "curtain" is accepted
///              when no hash is set, so the Mac is never unrecoverable. A
///              legacy salted-SHA256 hash verifies once and is transparently
///              upgraded to PBKDF2 on success. Backoff state (failureCount,
///              lockoutUntil) is persisted to UserDefaults (T-P1-E06-03), not
///              Keychain — it is non-secret counters/timestamps, so a process
///              relaunch (crash, kill -9, logout/login) correctly resumes the
///              in-effect backoff level instead of resetting it for free.
/// SPORT: MASTER-SETTINGS
extension Settings {

    // MARK: - Password (PBKDF2-HMAC-SHA256), stored in Keychain

    /// Derive and store a new password. Generates a fresh 16-byte salt each time.
    /// Returns `true` only when the Keychain write is confirmed successful, so a
    /// user-initiated password change can surface a failure rather than silently
    /// leaving the previous (possibly the public "curtain" default) password in
    /// place while the UI reports success. `@discardableResult` because the
    /// legacy-upgrade call site in `verify()` intentionally ignores it (a failed
    /// transparent re-derive simply leaves the still-valid legacy material in
    /// place and re-upgrades on the next successful verify).
    @discardableResult
    public static func setPassword(_ plain: String) -> Bool {
        let salt = randomBytes(16)
        let iterations = currentIterations()
        let derived = pbkdf2(password: plain, salt: salt, iterations: iterations)
        return writePasswordMaterial(
            PasswordMaterial(
                algo: "pbkdf2",
                salt: hex(salt),
                iterations: iterations,
                hash: hex(derived)))
    }

    /// Verify a candidate. When no password is set (or the stored material is
    /// corrupt/partial), the built-in "curtain" is accepted so the Mac is never
    /// unrecoverable. A legacy salted-SHA256 hash is verified once and, on
    /// success, transparently upgraded to PBKDF2.
    static func verify(_ candidate: String) -> Bool {
        guard let material = readPasswordMaterial() else { return candidate == "curtain" }

        if material.algo == "pbkdf2" {
            guard let saltBytes = bytes(fromHex: material.salt) else { return false }
            let iterations = max(100_000, material.iterations)
            let derived = pbkdf2(password: candidate, salt: saltBytes, iterations: iterations)
            return constantTimeEquals(hex(derived), material.hash)
        }

        // Legacy salted-SHA256: verify against the old scheme, then upgrade on success.
        if constantTimeEquals(legacySHA256(candidate, salt: material.salt), material.hash) {
            setPassword(candidate)
            return true
        }
        return false
    }

    public static var hasPassword: Bool { readPasswordMaterial() != nil }

    private static func currentIterations() -> Int {
        max(100_000, readPasswordMaterial()?.iterations ?? 0)
    }

    // MARK: - Attempt backoff (T-P1-E06-03: persisted to UserDefaults, not
    // Keychain — this is non-secret counters/timestamps, not password
    // material, so it stays alongside the rest of Settings' plain
    // preferences. Read/write straight through `d` on every access (no
    // separate in-memory cache), matching the computed-property style used
    // elsewhere in Settings.swift (e.g. `armed`, `launchAtLogin`) — this is
    // also what makes "resume on relaunch" fall out for free: a fresh
    // process has no stale in-memory state to reset, since there never was
    // any in-memory state to begin with.
    //
    // Clock-rollback limitation (accepted, not mitigated): backoffRemaining
    // is computed as `lockoutUntil.timeIntervalSinceNow`, so an attacker
    // with physical access who also winds the system clock backward can
    // make an active lockout read as expired early. This is accepted as a
    // known limitation rather than mitigated: the backoff is defense-in-
    // depth on top of the PBKDF2 hash (T-P1-E06-01), not the primary
    // control, and detecting clock rollback robustly (e.g. persisting a
    // monotonic "last observed now" and treating backward jumps as
    // suspicious) is meaningfully more complexity than this ticket's scope
    // warrants for a secondary control.

    private static var failureCount: Int {
        get { d.integer(forKey: Key.lockoutFailureCount) }
        set { d.set(newValue, forKey: Key.lockoutFailureCount) }
    }

    /// nil when no lockout key has ever been persisted (fresh install, or
    /// cleared by resetFailedAttempts()).
    private static var lockoutUntil: Date? {
        get {
            guard let stored = d.object(forKey: Key.lockoutUntilTimestamp) as? Double else { return nil }
            return Date(timeIntervalSince1970: stored)
        }
        set {
            guard let newValue else {
                d.removeObject(forKey: Key.lockoutUntilTimestamp)
                return
            }
            d.set(newValue.timeIntervalSince1970, forKey: Key.lockoutUntilTimestamp)
        }
    }

    static func registerFailedAttempt() {
        failureCount += 1
        // Exponential: 1s, 2s, 4s, ... capped at 30s, starting after 3 misses.
        guard failureCount >= 3 else { return }
        let delay = min(30.0, pow(2.0, Double(failureCount - 3)))
        lockoutUntil = Date().addingTimeInterval(delay)
    }

    static func resetFailedAttempts() {
        d.removeObject(forKey: Key.lockoutFailureCount)
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

    // MARK: - Keychain-backed password material (T-P1-E06-01)

    /// The four password fields (previously four separate UserDefaults keys),
    /// stored together as one JSON blob under a single Keychain item so a
    /// single SecItemAdd/SecItemUpdate call is all-or-nothing — there is no
    /// window where algo/salt/hash could be individually partially written.
    /// `Codable` so the JSON encode/decode round-trip is exact and typed.
    struct PasswordMaterial: Codable, Equatable {
        var algo: String
        var salt: String
        var iterations: Int
        var hash: String

        /// True when every field required by this item's algo is present and
        /// non-empty/well-formed. Used as the read-time corruption/tamper
        /// check: a well-formed item either has everything its algo needs or
        /// verify() falls back to the hardcoded anti-lockout path rather than
        /// failing confusingly. `iterations` is only required (> 0) for
        /// "pbkdf2" — the legacy "legacy-sha256" algo (still upgraded
        /// on successful verify, see Settings.verify()) never had an
        /// iteration count, so requiring one there would make every
        /// not-yet-upgraded legacy record read as corrupt.
        var isWellFormed: Bool {
            guard !algo.isEmpty, !salt.isEmpty, !hash.isEmpty else { return false }
            if algo == "pbkdf2" { return iterations > 0 }
            return true
        }
    }

    /// Fixed Keychain service name for the password item. `internal` (not
    /// `private`) and `var` (not `let`) — Tests/CurtainCoreTests swaps this
    /// to a per-test-run unique suffix in setUp, mirroring the `Settings.d`
    /// UserDefaults-suite seam, so tests never touch the real app's Keychain
    /// item and never leak state across test cases regardless of order.
    static var keychainService = "com.curtain.password"

    /// Test-only failure injection: when true, writePasswordMaterial(...)
    /// short-circuits to `false` without touching the Keychain at all. There
    /// is no reliable, portable way to force a real SecItemAdd/SecItemUpdate
    /// failure on a test-runner Keychain (permission-denied conditions
    /// require an interactive prompt or ACL setup unavailable in CI), so
    /// this flag is how SettingsPasswordTests exercises the migration's
    /// verify-then-delete-on-failure ordering deterministically. Always
    /// `false` in production; tests reset it in tearDown.
    static var forceKeychainWriteFailureForTesting = false

    /// Single Keychain account name — one item holds the whole JSON blob.
    private static let keychainAccount = "material"

    /// Read the password material from Keychain. Returns nil when no item
    /// exists (fresh install / never set) or when the stored item fails the
    /// well-formedness check (partial-write corruption) — both cases fall
    /// back to the "curtain" anti-lockout path in verify()/hasPassword,
    /// logging a diagnostic in the corruption case so it is distinguishable
    /// from a genuine fresh install if a user reports being locked out.
    private static func readPasswordMaterial() -> PasswordMaterial? {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.error("Settings: Keychain read failed for password material, status \(status)")
            }
            return nil
        }
        guard let material = try? JSONDecoder().decode(PasswordMaterial.self, from: data) else {
            Log.error("Settings: Keychain password item present but failed to decode — treating as corrupt")
            return nil
        }
        guard material.isWellFormed else {
            Log.error("Settings: Keychain password item present but not well-formed — treating as corrupt")
            return nil
        }
        return material
    }

    /// Write the password material to Keychain as a single JSON blob,
    /// updating in place if an item already exists. Returns true only when
    /// the write is confirmed successful (errSecSuccess), so callers
    /// (setPassword, and Settings+Migrations.swift's migratePasswordToKeychain())
    /// can implement verify-then-delete ordering against UserDefaults without
    /// ever deleting on a failed write. `internal` (not `private`) so the
    /// migration, in a separate file of the same module, can reuse it rather
    /// than duplicating the Keychain-write logic.
    @discardableResult
    static func writePasswordMaterial(_ material: PasswordMaterial) -> Bool {
        if forceKeychainWriteFailureForTesting { return false }
        guard let data = try? JSONEncoder().encode(material) else { return false }
        let base = keychainBaseQuery()

        // Try update first; if nothing to update, add a new item.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            Log.error("Settings: Keychain update failed for password material, status \(updateStatus)")
            return false
        }

        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.error("Settings: Keychain add failed for password material, status \(addStatus)")
            return false
        }
        return true
    }

    /// Delete the Keychain password item. Used only by tests to reset state
    /// between runs; production code never needs to delete this item outright
    /// (setPassword always overwrites, never removes).
    static func deletePasswordMaterialForTesting() {
        SecItemDelete(keychainBaseQuery() as CFDictionary)
    }

    private static func keychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }
}
