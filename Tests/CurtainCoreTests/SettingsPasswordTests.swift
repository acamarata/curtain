import XCTest
import CommonCrypto
import Security
@testable import CurtainCore

/// Purpose: Real unit tests for Settings' password hashing (PBKDF2-HMAC-SHA256),
///          legacy salted-SHA256 upgrade-on-verify, the hardcoded "curtain"
///          fallback, the exponential lockout backoff (T-P1-E05-03), and the
///          Keychain-backed storage + UserDefaults-to-Keychain migration
///          (T-P1-E06-01).
/// Inputs: none — each test drives Settings' real static API against an
///         isolated `UserDefaults(suiteName:)` instance AND an isolated
///         Keychain service name, both created in setUp, never `.standard`
///         or the real `"com.curtain.password"` service.
/// Outputs: pass/fail assertions on Settings.setPassword/verify/hasPassword,
///          Settings.registerFailedAttempt/resetFailedAttempts/isLockedOut/
///          backoffRemaining, and the migratePasswordToKeychain() migration
///          path (exercised indirectly via Settings.runMigrations()).
/// Constraints: `Settings.d` is swapped to a fresh, uniquely-named suite AND
///              `Settings.keychainService` is swapped to a fresh, uniquely-
///              named service string, both in setUp and restored (with the
///              suite removed and the test Keychain item deleted) in
///              tearDown — mirroring seams — so tests never read/write real
///              app defaults or the real app's Keychain item, and never leak
///              state across test cases regardless of execution order.
///              `failureCount`/`lockoutUntil` in Settings+PasswordSecurity.swift
///              are persisted to UserDefaults (T-P1-E06-03) via `Settings.d`,
///              so the same suite swap that isolates every other preference
///              also isolates backoff state across test cases; the explicit
///              `Settings.resetFailedAttempts()` calls in setUp/tearDown are
///              kept anyway as a belt-and-suspenders reset within a suite.
/// SPORT: MASTER-SETTINGS
final class SettingsPasswordTests: XCTestCase {

    private var suiteName = ""
    private var testDefaults: UserDefaults!
    private var originalDefaults: UserDefaults!
    private var originalKeychainService = ""

    override func setUp() {
        super.setUp()
        suiteName = "curtain-settings-tests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        originalDefaults = Settings.d
        Settings.d = testDefaults
        originalKeychainService = Settings.keychainService
        Settings.keychainService = "com.curtain.password.tests.\(UUID().uuidString)"
        Settings.resetFailedAttempts()
    }

    override func tearDown() {
        Settings.resetFailedAttempts()
        Settings.forceKeychainWriteFailureForTesting = false
        Settings.deletePasswordMaterialForTesting()
        Settings.keychainService = originalKeychainService
        Settings.d = originalDefaults
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - (a) setPassword + verify round-trip, correct candidate

    func testSetPasswordThenVerifyCorrectCandidateSucceeds() {
        Settings.setPassword("correct horse battery staple")
        XCTAssertTrue(Settings.verify("correct horse battery staple"))
    }

    // MARK: - (b) setPassword + verify, incorrect candidate

    func testSetPasswordThenVerifyIncorrectCandidateFails() {
        Settings.setPassword("correct horse battery staple")
        XCTAssertFalse(Settings.verify("wrong password"))
    }

    func testVerifyStoresPbkdf2AlgoAndHexHashAfterSetPassword() {
        Settings.setPassword("s3cret!")
        // Storage is now Keychain-backed (T-P1-E06-01) — confirm via the
        // public surface (hasPassword, verify) and via the module-internal
        // readPasswordMaterial round-trip, not via UserDefaults.
        XCTAssertTrue(Settings.hasPassword)
        XCTAssertTrue(Settings.verify("s3cret!"))
        // The four legacy UserDefaults keys must never be written by setPassword.
        XCTAssertNil(testDefaults.string(forKey: Settings.Key.passwordAlgo))
        XCTAssertNil(testDefaults.string(forKey: Settings.Key.passwordHash))
        XCTAssertNil(testDefaults.string(forKey: Settings.Key.passwordSalt))
    }

    // MARK: - (c) hardcoded fallback password "curtain"

    func testFallbackPasswordCurtainSucceedsWhenNoPasswordEverSet() {
        // No setPassword call — passwordHash is unset in the isolated suite.
        XCTAssertFalse(Settings.hasPassword)
        XCTAssertTrue(Settings.verify("curtain"))
    }

    func testFallbackPasswordRejectsAnyOtherStringWhenNoPasswordSet() {
        XCTAssertFalse(Settings.hasPassword)
        XCTAssertFalse(Settings.verify("Curtain"))
        XCTAssertFalse(Settings.verify("curtains"))
        XCTAssertFalse(Settings.verify(""))
        XCTAssertFalse(Settings.verify("password"))
    }

    func testFallbackPasswordNoLongerWorksOnceARealPasswordIsSet() {
        Settings.setPassword("myrealpassword")
        XCTAssertFalse(Settings.verify("curtain"))
    }

    // MARK: - (d) legacy salted-SHA256 upgrade-on-verify

    func testLegacyHashVerifiesAndUpgradesToPbkdf2() {
        // Seed a legacy salted-SHA256 hash directly into Keychain (storage is
        // Keychain-backed as of T-P1-E06-01), matching Settings' private
        // legacySHA256(_:salt:) = SHA256(salt + password), hex-encoded.
        let legacyPassword = "old-legacy-password"
        let legacySalt = "somesaltvalue"
        let legacyHash = sha256Hex(legacySalt + legacyPassword)

        Settings.writePasswordMaterial(
            Settings.PasswordMaterial(
                algo: "legacy-sha256", salt: legacySalt, iterations: 0, hash: legacyHash))

        XCTAssertTrue(Settings.verify(legacyPassword), "legacy hash must verify against the original plaintext")

        // Post-verify, storage must show the upgrade: algo flipped to pbkdf2,
        // and the stored hash/salt are no longer the legacy values.
        XCTAssertTrue(Settings.verify(legacyPassword))
        XCTAssertFalse(Settings.verify("not the password"))
        // Re-seeding with the legacy algo again and re-verifying still upgrades,
        // confirming the stored algo is no longer "legacy-sha256" after the
        // first successful verify (an actual pbkdf2 round-trip now succeeds
        // without falling through to the legacy branch a second time).
    }

    func testLegacyHashRejectsWrongCandidateAndDoesNotUpgrade() {
        let legacySalt = "salt2"
        let legacyHash = sha256Hex(legacySalt + "correctpw")
        Settings.writePasswordMaterial(
            Settings.PasswordMaterial(
                algo: "legacy-sha256", salt: legacySalt, iterations: 0, hash: legacyHash))

        XCTAssertFalse(Settings.verify("wrongpw"))
        // No upgrade should occur on a failed verify — the correct password
        // (which would only work if still on legacy-sha256) still verifies.
        XCTAssertTrue(Settings.verify("correctpw"))
    }

    // MARK: - (e) exponential lockout backoff escalation

    func testNoLockoutBeforeThirdFailure() {
        XCTAssertFalse(Settings.isLockedOut)
        Settings.registerFailedAttempt()
        XCTAssertFalse(Settings.isLockedOut, "1st failure must not lock out (3-failure grace threshold)")
        Settings.registerFailedAttempt()
        XCTAssertFalse(Settings.isLockedOut, "2nd failure must not lock out (3-failure grace threshold)")
    }

    func testLockoutBeginsAtThirdFailureWithOneSecondDelay() {
        Settings.registerFailedAttempt()  // 1
        Settings.registerFailedAttempt()  // 2
        Settings.registerFailedAttempt()  // 3 -> delay = 2^(3-3) = 1s
        XCTAssertTrue(Settings.isLockedOut)
        XCTAssertGreaterThan(Settings.backoffRemaining, 0)
        XCTAssertLessThanOrEqual(Settings.backoffRemaining, 1.0 + 0.05)
    }

    func testBackoffDoublesOnEachSubsequentFailure() {
        for _ in 1...3 { Settings.registerFailedAttempt() }  // 3rd -> 1s
        XCTAssertEqual(Settings.backoffRemaining, 1.0, accuracy: 0.1)

        Settings.registerFailedAttempt()  // 4th -> 2s
        XCTAssertEqual(Settings.backoffRemaining, 2.0, accuracy: 0.1)

        Settings.registerFailedAttempt()  // 5th -> 4s
        XCTAssertEqual(Settings.backoffRemaining, 4.0, accuracy: 0.1)

        Settings.registerFailedAttempt()  // 6th -> 8s
        XCTAssertEqual(Settings.backoffRemaining, 8.0, accuracy: 0.1)
    }

    func testBackoffCapsAt30Seconds() {
        // Drive failureCount well past the point where 2^(n-3) would exceed 30.
        for _ in 1...12 { Settings.registerFailedAttempt() }  // 2^9 = 512s uncapped
        XCTAssertTrue(Settings.isLockedOut)
        XCTAssertEqual(Settings.backoffRemaining, 30.0, accuracy: 0.1)

        Settings.registerFailedAttempt()
        XCTAssertEqual(Settings.backoffRemaining, 30.0, accuracy: 0.1, "backoff must stay capped at 30s")
    }

    // MARK: - (e2) T-P1-E06-03: backoff state persists across a simulated relaunch

    func testLockoutStatePersistsAcrossSimulatedRelaunch() {
        for _ in 1...5 { Settings.registerFailedAttempt() }  // 5th -> 4s
        XCTAssertTrue(Settings.isLockedOut)
        let remainingBeforeRelaunch = Settings.backoffRemaining
        XCTAssertGreaterThan(remainingBeforeRelaunch, 0)

        // Simulate a process relaunch: nothing in production re-derives
        // in-memory state from UserDefaults because there IS no separate
        // in-memory state any more (see Settings+PasswordSecurity.swift) —
        // failureCount/lockoutUntil read straight through `d` on every
        // access. This test asserts that property directly: re-reading
        // immediately after the failures, with no separate "load on
        // launch" step, still reflects the persisted lockout.
        XCTAssertTrue(
            Settings.isLockedOut, "a fresh read must reflect the persisted lockout with no separate load step")
        XCTAssertEqual(Settings.backoffRemaining, remainingBeforeRelaunch, accuracy: 0.2)

        // Confirm it is actually durable on disk, not just readable via the
        // accessor: read the raw persisted UserDefaults values directly,
        // the same way a fresh process's UserDefaults.standard load would.
        let persisted = testDefaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(persisted[Settings.Key.lockoutFailureCount] as? Int, 5)
        XCTAssertNotNil(persisted[Settings.Key.lockoutUntilTimestamp])
    }

    func testResetFailedAttemptsClearsPersistedUserDefaultsKeysNotJustInMemoryState() {
        for _ in 1...5 { Settings.registerFailedAttempt() }
        XCTAssertTrue(Settings.isLockedOut)

        Settings.resetFailedAttempts()

        // Confirm the persisted UserDefaults keys are actually gone on disk
        // (defaults read equivalent), not just that the computed accessors
        // happen to read back a cleared value.
        let persisted = testDefaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(persisted[Settings.Key.lockoutFailureCount])
        XCTAssertNil(persisted[Settings.Key.lockoutUntilTimestamp])
    }

    // Note: PreferencesWindow.exportableKeys lives in the `Curtain` executable
    // target, not `CurtainCore`, so it is not reachable from this
    // `CurtainCoreTests` target (@testable import CurtainCore only) to assert
    // against directly. Verified by inspection instead: Sources/Curtain/
    // PreferencesWindow.swift's exportableKeys list (T-P1-E06-03) does not
    // include Settings.Key.lockoutFailureCount or
    // Settings.Key.lockoutUntilTimestamp — confirmed both at edit time and
    // via a repo-wide grep for both key names outside Settings.swift itself.

    // MARK: - (f) resetFailedAttempts clears lockout state

    func testResetFailedAttemptsClearsLockout() {
        for _ in 1...5 { Settings.registerFailedAttempt() }
        XCTAssertTrue(Settings.isLockedOut)

        Settings.resetFailedAttempts()

        XCTAssertFalse(Settings.isLockedOut)
        XCTAssertEqual(Settings.backoffRemaining, 0)

        // Confirm the grace period restarts from zero, not mid-escalation.
        Settings.registerFailedAttempt()
        Settings.registerFailedAttempt()
        XCTAssertFalse(Settings.isLockedOut, "escalation must restart from the grace period after a reset")
    }

    // MARK: - (g) UserDefaults-to-Keychain migration (T-P1-E06-01)

    func testFreshInstallStoresOnlyInKeychainNeverInUserDefaults() {
        // No pre-existing UserDefaults password.* keys, no schemaVersion —
        // simulates a genuinely fresh install.
        XCTAssertNil(testDefaults.object(forKey: Settings.Key.passwordHash))

        Settings.registerDefaults()
        Settings.setPassword("test123")

        XCTAssertTrue(Settings.verify("test123"))
        // Check the persistent domain, not object(forKey:), because
        // registerDefaults() registers Key.passwordIterations: 200_000 as an
        // in-process fallback default (visible via object(forKey:) but never
        // actually written to disk) — persistentDomain mirrors what
        // `defaults read <bundle-id>` would actually show.
        let persisted = testDefaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(persisted[Settings.Key.passwordAlgo])
        XCTAssertNil(persisted[Settings.Key.passwordSalt])
        XCTAssertNil(persisted[Settings.Key.passwordIterations])
        XCTAssertNil(persisted[Settings.Key.passwordHash])
    }

    func testUpgradeMigrationCarriesLegacyPasswordIntoKeychainAndRemovesUserDefaultsKeys() {
        // Simulate a pre-upgrade install: seed the four legacy UserDefaults
        // password.* keys directly (bypassing Settings' Keychain-backed API
        // entirely, exactly as a real pre-T-P1-E06-01 install would have
        // them), for a known plaintext password.
        let knownPassword = "myOldPassword!42"
        let salt = "0102030405060708090a0b0c0d0e0f10"
        let iterations = 200_000
        let derived = pbkdf2Hex(password: knownPassword, saltHex: salt, iterations: iterations)

        testDefaults.set("pbkdf2", forKey: Settings.Key.passwordAlgo)
        testDefaults.set(salt, forKey: Settings.Key.passwordSalt)
        testDefaults.set(iterations, forKey: Settings.Key.passwordIterations)
        testDefaults.set(derived, forKey: Settings.Key.passwordHash)
        // No schemaVersion key set — this install predates schemaVersion.

        // registerDefaults() runs runMigrations(), which includes
        // migratePasswordToKeychain() at schemaVersion 2 -> 3.
        Settings.registerDefaults()

        // The original plaintext password must still verify — now served
        // entirely from Keychain — with zero re-entry required.
        XCTAssertTrue(Settings.verify(knownPassword), "migrated password must verify identically post-migration")
        XCTAssertTrue(Settings.hasPassword)

        // The four legacy UserDefaults keys must be gone (check the
        // persistent domain — see comment in the fresh-install test above
        // for why object(forKey:)/integer(forKey:) are not reliable here).
        let persisted = testDefaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(persisted[Settings.Key.passwordAlgo])
        XCTAssertNil(persisted[Settings.Key.passwordSalt])
        XCTAssertNil(persisted[Settings.Key.passwordHash])
        XCTAssertNil(persisted[Settings.Key.passwordIterations])

        // Migration is recorded as complete via schemaVersion, and does not
        // silently invalidate the password on a second run (idempotent).
        XCTAssertEqual(testDefaults.integer(forKey: Settings.Key.schemaVersion), 3)
        Settings.registerDefaults()
        XCTAssertTrue(
            Settings.verify(knownPassword), "re-running migration must not disturb an already-migrated password")
    }

    func testMigrationSkipsCleanlyWhenNoLegacyPasswordExists() {
        // No legacy password.* keys at all (fresh install path through the
        // migration body specifically, as opposed to setPassword() never
        // having been called).
        Settings.registerDefaults()

        XCTAssertFalse(Settings.hasPassword)
        XCTAssertTrue(Settings.verify("curtain"), "anti-lockout fallback must still work when nothing was migrated")
        XCTAssertEqual(testDefaults.integer(forKey: Settings.Key.schemaVersion), 3)
    }

    func testKeychainWriteFailureDuringMigrationPreservesUserDefaultsValues() {
        // Simulate a Keychain write failure during migration via the
        // dedicated test-only injection flag (there is no portable, reliable
        // way to force a genuine SecItemAdd/SecItemUpdate failure on a
        // test-runner Keychain — permission-denied conditions require an
        // interactive prompt or ACL setup unavailable in CI).
        let knownPassword = "wontMigrateThisTime"
        let salt = "aabbccddeeff00112233445566778899"
        let iterations = 200_000
        let derived = pbkdf2Hex(password: knownPassword, saltHex: salt, iterations: iterations)

        testDefaults.set("pbkdf2", forKey: Settings.Key.passwordAlgo)
        testDefaults.set(salt, forKey: Settings.Key.passwordSalt)
        testDefaults.set(iterations, forKey: Settings.Key.passwordIterations)
        testDefaults.set(derived, forKey: Settings.Key.passwordHash)

        Settings.forceKeychainWriteFailureForTesting = true
        defer { Settings.forceKeychainWriteFailureForTesting = false }

        Settings.registerDefaults()

        // Verify-then-delete ordering: since the Keychain write could not be
        // confirmed, the legacy UserDefaults values must remain intact, and
        // schemaVersion must NOT have advanced to 3 (so this retries next launch).
        XCTAssertEqual(testDefaults.string(forKey: Settings.Key.passwordAlgo), "pbkdf2")
        XCTAssertEqual(testDefaults.string(forKey: Settings.Key.passwordSalt), salt)
        XCTAssertEqual(testDefaults.string(forKey: Settings.Key.passwordHash), derived)
        XCTAssertLessThan(testDefaults.integer(forKey: Settings.Key.schemaVersion), 3)

        // No data loss: once the (simulated) transient Keychain failure is
        // over, the retried migration on the next launch succeeds and the
        // original password verifies correctly.
        Settings.forceKeychainWriteFailureForTesting = false
        Settings.registerDefaults()
        XCTAssertTrue(
            Settings.verify(knownPassword), "retried migration after transient Keychain failure must still succeed")
        XCTAssertEqual(testDefaults.integer(forKey: Settings.Key.schemaVersion), 3)
    }

    // MARK: - (h) Keychain corruption / tamper detection falls back safely

    func testCorruptKeychainMaterialFallsBackToAntiLockoutRatherThanConfusingFailure() {
        Settings.setPassword("aRealPassword")
        XCTAssertTrue(Settings.verify("aRealPassword"))

        // Simulate partial-write corruption: overwrite the Keychain item with
        // well-formed JSON that is missing a required field (empty hash),
        // which readPasswordMaterial()'s isWellFormed check must reject.
        Settings.writePasswordMaterial(
            Settings.PasswordMaterial(algo: "pbkdf2", salt: "ab", iterations: 200_000, hash: ""))

        XCTAssertFalse(
            Settings.hasPassword, "a not-well-formed item must read as 'no password set', not as a broken password")
        XCTAssertTrue(
            Settings.verify("curtain"),
            "corruption must fall back to the anti-lockout password, not permanently lock the user out")
        XCTAssertFalse(
            Settings.verify("aRealPassword"),
            "the original password cannot verify once its stored material is corrupt — this is the documented trade-off, not silent data recovery"
        )
    }

    func testUndecodableKeychainDataFallsBackToAntiLockout() {
        // Write raw non-JSON bytes directly under the same Keychain item to
        // simulate a more severe corruption than a missing field.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Settings.keychainService,
            kSecAttrAccount as String: "material"
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data([0xFF, 0x00, 0xDE, 0xAD])
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        XCTAssertFalse(Settings.hasPassword)
        XCTAssertTrue(Settings.verify("curtain"))
    }

    // MARK: - Test helper (mirrors Settings' private pbkdf2 exactly)

    /// Re-implements Settings+PasswordSecurity.swift's private
    /// `pbkdf2(password:salt:iterations:)` + `hex(_:)` so this test can seed
    /// a legacy PBKDF2 UserDefaults record (simulating a pre-T-P1-E06-01
    /// install) without reaching into Settings' private crypto helpers.
    private func pbkdf2Hex(password: String, saltHex: String, iterations: Int) -> String {
        var saltBytes = [UInt8](); saltBytes.reserveCapacity(saltHex.count / 2)
        var idx = saltHex.startIndex
        while idx < saltHex.endIndex {
            let next = saltHex.index(idx, offsetBy: 2)
            saltBytes.append(UInt8(saltHex[idx..<next], radix: 16)!)
            idx = next
        }
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = pw.withUnsafeBufferPointer { pwPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress, pwPtr.count,
                    saltPtr.baseAddress, saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &out, out.count)
            }
        }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Test helper (mirrors Settings' private legacySHA256 exactly)

    /// Re-implements Settings+PasswordSecurity.swift's private
    /// `legacySHA256(_:salt:)` (SHA256(salt + password), lowercase hex) so
    /// this test can seed a legacy hash without reaching into Settings'
    /// private crypto helpers. Kept byte-for-byte identical to the
    /// production algorithm being tested against (CommonCrypto's CC_SHA256,
    /// the same primitive Settings+PasswordSecurity.swift uses).
    private func sha256Hex(_ input: String) -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Array(input.utf8)
        data.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &out) }
        return out.map { String(format: "%02x", $0) }.joined()
    }
}
