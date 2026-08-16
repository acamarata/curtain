import Foundation

/// Purpose: Ordered, versioned migrations for Settings, run once from
///          Settings.registerDefaults() at launch to carry forward user
///          intent when a preference's storage format changes.
/// Inputs: none (reads/writes the shared UserDefaults.standard via
///         Settings.d).
/// Outputs: mutates the affected UserDefaults keys and persists
///          Key.schemaVersion so each migration body runs at most once, in
///          ascending version order.
/// Constraints: extension on the `Settings` enum (no new type) so callers
///              keep referencing a single `Settings` namespace. Each
///              migration body must be idempotent and safe to call on every
///              launch in principle — `runMigrations()`'s schemaVersion gate,
///              not caller discipline, is what actually enforces "runs once."
///              Design choice (T-P1-E06-04): schemaVersion is the primary,
///              forward-looking ordering mechanism. The legacy per-migration
///              `migrated.onUnlock` / `migrated.coverScope` booleans are kept
///              (not removed) purely as a one-time upgrade bridge — an
///              install from before this ticket has both booleans already
///              `true` but no schemaVersion key yet, so `runMigrations()`
///              detects that case and sets schemaVersion = 2 directly
///              instead of re-running bodies against already-migrated data.
///              A brand-new install never has the legacy booleans set, so it
///              always takes the normal `schemaVersion < N` path. Downgrade
///              protection (refusing to launch on a schemaVersion higher
///              than CURRENT_SCHEMA_VERSION) is explicitly out of scope for
///              this ticket — noted here as a follow-on, not silently
///              dropped.
/// SPORT: MASTER-SETTINGS
extension Settings {

    /// Bump this by exactly 1 whenever a new migration body is added below,
    /// and add one matching `if current < N { ... }` block in
    /// `runMigrations()`. Never skip a number or reorder existing blocks —
    /// the version each block checks against is a permanent historical
    /// marker, not just a counter.
    private static let CURRENT_SCHEMA_VERSION = 3

    /// Entry point called once from `registerDefaults()`. Walks
    /// `schemaVersion` up to `CURRENT_SCHEMA_VERSION` in order, running only
    /// the migration bodies a given install hasn't seen yet, then persists
    /// the result. Fresh installs and installs already fully migrated under
    /// the old boolean-guard mechanism both land on `CURRENT_SCHEMA_VERSION`
    /// without any migration body re-executing against current data.
    static func runMigrations() {
        var current = d.integer(forKey: Key.schemaVersion)  // 0 if the key has never been set

        // One-time upgrade bridge: an install from before schemaVersion existed has
        // no Key.schemaVersion value, but may already have run both legacy
        // migrations under the old independent-boolean mechanism. Detect that and
        // jump straight to schemaVersion 2 (NOT CURRENT_SCHEMA_VERSION — see below)
        // rather than re-running either body.
        //
        // Deliberately jumps to 2, not CURRENT_SCHEMA_VERSION: the password-Keychain
        // migration (schemaVersion 2 -> 3, T-P1-E06-01) is NOT part of this bridge's
        // legacy-boolean contract and can itself fail and need a retry (see below).
        // If this jumped straight to CURRENT_SCHEMA_VERSION, a prior launch that ran
        // migrateOnUnlockAction()/migrateCoverScope() successfully but then hit a
        // Keychain write failure during migratePasswordToKeychain() (leaving
        // schemaVersion unset) would have that retry silently skipped on the next
        // launch, since both legacy booleans would already read true. Landing on 2
        // guarantees the `current < 3` check below always re-attempts the password
        // migration until it actually succeeds.
        if current == 0
            && d.bool(forKey: Key.migratedOnUnlock)
            && d.bool(forKey: Key.migratedCoverScope)
        {
            current = 2
        }

        if current < 1 {
            migrateOnUnlockAction()
        }
        if current < 2 {
            migrateCoverScope()
        }
        if current < 3 {
            // Unlike the two bridge migrations above, this one is NOT
            // unconditionally marked done here — migratePasswordToKeychain()
            // only advances past this step once the Keychain write is
            // confirmed (verify-then-delete), so a failed write leaves
            // schemaVersion unset/at-2 and this retries on the next launch
            // instead of silently skipping the migration forever.
            guard migratePasswordToKeychain() else { return }
        }

        d.set(CURRENT_SCHEMA_VERSION, forKey: Key.schemaVersion)
    }

    /// Migration body (schemaVersion 0 -> 1): the old boolean `onPassword.disconnect`
    /// is replaced by the explicit `onUnlock.action` choice. If the user had disconnect
    /// turned on and never set the new key, carry that intent forward. Logic unchanged
    /// from the pre-schemaVersion boolean-guarded version — only the caller
    /// (`runMigrations()`'s `current < 1` check) changed. Still sets the legacy
    /// `migrated.onUnlock` flag too, so a downgrade to a pre-schemaVersion build of the
    /// app (which only reads that boolean) still sees this migration as applied.
    private static func migrateOnUnlockAction() {
        let legacyOn =
            d.object(forKey: Key.onPasswordDisconnect) != nil
            && d.bool(forKey: Key.onPasswordDisconnect)
        let newSet = d.object(forKey: Key.onUnlockAction) != nil
        if legacyOn && !newSet {
            d.set("disconnect", forKey: Key.onUnlockAction)
        }
        d.set(true, forKey: Key.migratedOnUnlock)
    }

    /// Migration body (schemaVersion 1 -> 2): the old "onlyMarked" / "allExceptMarked"
    /// cover-scope values are collapsed into "perDisplay", which uses the per-display
    /// Cover toggle as the authority. Logic unchanged from the pre-schemaVersion
    /// boolean-guarded version — only the caller (`runMigrations()`'s `current < 2`
    /// check) changed. Still sets the legacy `migrated.coverScope` flag too, for the
    /// same downgrade-compatibility reason as above.
    private static func migrateCoverScope() {
        let legacy = d.string(forKey: Key.coverScope) ?? ""
        if legacy == "onlyMarked" || legacy == "allExceptMarked" {
            d.set("perDisplay", forKey: Key.coverScope)
        }
        d.set(true, forKey: Key.migratedCoverScope)
    }

    /// Migration body (schemaVersion 2 -> 3, T-P1-E06-01): the four PBKDF2
    /// password fields (algo/salt/iterations/hash) used to live in plain
    /// UserDefaults — a world-readable plist under the owning user account,
    /// letting any local process or a copied backup read the hash/salt/
    /// iteration-count directly and brute-force it offline, bypassing the
    /// app's own lockout/backoff entirely (Settings.registerFailedAttempt)
    /// completely. This carries that material into the Keychain (see
    /// Settings+PasswordSecurity.swift's PasswordMaterial /
    /// writePasswordMaterial), transparently, on first launch post-upgrade.
    ///
    /// Verify-then-delete ordering (hard requirement): the legacy
    /// UserDefaults keys are removed, and the schemaVersion gate above only
    /// advances past this step, ONLY after writePasswordMaterial(...) has
    /// returned true — i.e. only after the Keychain write is confirmed. If
    /// the Keychain write fails (denied access, etc.), this returns false,
    /// `runMigrations()` returns early without persisting
    /// CURRENT_SCHEMA_VERSION, and the UserDefaults values are left
    /// completely untouched so the migration safely retries on the next
    /// launch instead of silently losing the user's password.
    ///
    /// Returns true when it is safe for `runMigrations()` to advance past
    /// schemaVersion 3 (either nothing needed migrating, or the migration
    /// completed and was confirmed); false only when a real password existed
    /// and the Keychain write could not be confirmed.
    private static func migratePasswordToKeychain() -> Bool {
        let legacyHash = d.string(forKey: Key.passwordHash) ?? ""
        guard !legacyHash.isEmpty else {
            // Fresh install, or already on the "curtain" fallback — nothing
            // to carry forward.
            return true
        }

        let legacyAlgo = d.string(forKey: Key.passwordAlgo) ?? ""
        let legacySalt = d.string(forKey: Key.passwordSalt) ?? ""
        let legacyIterations = d.integer(forKey: Key.passwordIterations)
        let material = PasswordMaterial(
            algo: legacyAlgo,
            salt: legacySalt,
            iterations: legacyIterations,
            hash: legacyHash)

        guard writePasswordMaterial(material) else {
            Log.error("Settings: password Keychain migration write failed — will retry next launch")
            return false
        }

        // Keychain write confirmed successful — now safe to remove the
        // legacy UserDefaults copies.
        d.removeObject(forKey: Key.passwordAlgo)
        d.removeObject(forKey: Key.passwordSalt)
        d.removeObject(forKey: Key.passwordIterations)
        d.removeObject(forKey: Key.passwordHash)
        return true
    }
}
