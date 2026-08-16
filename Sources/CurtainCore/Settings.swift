import Foundation

/// Purpose: Core configuration surface for every Curtain preference, backed by
///          UserDefaults so the SwiftUI settings view (@AppStorage) and the
///          headless coordinator read/write the exact same keys. Holds the Key
///          namespace, registerDefaults(), and the plain computed accessors.
///          One-time migration guards live in Settings+Migrations.swift;
///          password hashing and attempt-backoff logic live in
///          Settings+PasswordSecurity.swift — both are extensions on this
///          same `Settings` enum, so callers see one unified type.
/// Inputs: none (reads/writes the standard user defaults under the keys below).
/// Outputs: typed get/set accessors for every preference.
/// Constraints: every default is chosen so the user can never be locked out:
///              the fallback password "curtain" always works when no hash is
///              set, and the disconnect feature ships off. Settings is a plain
///              enum of static funcs over the thread-safe UserDefaults.standard,
///              so it is safe to call from any thread under Swift 6 concurrency.
///              `public` (type, `Key` namespace, and every accessor below)
///              because the thin `Curtain` executable's SwiftUI views bind to
///              these same UserDefaults keys via @AppStorage and call these
///              accessors directly across the CurtainCore module boundary.
/// SPORT: MASTER-SETTINGS
public enum Settings {

    /// Defaults key strings. The SwiftUI view binds to these same strings via @AppStorage.
    public enum Key {
        // General
        public static let armed = "armed"
        public static let launchAtLogin = "launchAtLogin"
        public static let showInMenuBar = "showInMenuBar"
        // Activation
        public static let onStartActivate = "onStart.activateCurtain"
        public static let connectGraceSeconds = "connect.graceSeconds"
        public static let notifyOnActivate = "notifyOnActivate"
        public static let playSoundOnActivate = "playSoundOnActivate"
        // Reveal trigger (how the desk user pops the password box)
        public static let revealTrigger = "reveal.trigger"  // "anyKey" | "keyCombo"
        public static let revealKeyCombo = "reveal.keyCombo"  // e.g. "cmd+shift+L"; empty when anyKey
        // Appearance
        // cover.style accepts: "solidColor" | "message" | "blur" | "logo" | "curtainLogo" | "aerial"
        // ("screensaver" is legacy and is treated as "logo".)
        public static let coverStyle = "cover.style"
        public static let coverColor = "cover.color"
        public static let coverMessage = "cover.message"
        public static let coverShowClock = "cover.showClock"
        // Idle
        public static let idleEnabled = "idle.enabled"
        public static let idleMinutes = "idle.minutes"
        public static let idleSource = "idle.source"
        /// Plain string constant (not a UserDefaults key) shared by
        /// registerDefaults() and idleSourceIsHID's fallback so the two
        /// sites cannot silently disagree on the product default.
        public static let idleSourceDefault = "sessionInput"
        public static let onIdleDisconnect = "onIdle.disconnect"
        public static let onIdleLock = "onIdle.lock"
        public static let onIdleScreenOff = "onIdle.screenOff"
        public static let onIdleDeactivate = "onIdle.deactivate"
        // End (disconnect)
        public static let onEndLock = "onEnd.lock"
        public static let onEndScreenOff = "onEnd.screenOff"
        public static let onEndDeactivate = "onEnd.deactivate"
        // Security
        public static let onPasswordDisconnect = "onPassword.disconnect"  // legacy bool, kept readable
        public static let onUnlockAction = "onUnlock.action"  // "keepSession" | "disconnect"
        // legacy one-time migration guards (bridge only, see Settings+Migrations.swift)
        public static let migratedOnUnlock = "migrated.onUnlock"
        public static let migratedCoverScope = "migrated.coverScope"
        /// Monotonic migration counter driving `runMigrations()`. Absent (reads as 0
        /// via `d.integer(forKey:)`) on a fresh install or any pre-schemaVersion
        /// existing install. See Settings+Migrations.swift.
        public static let schemaVersion = "schemaVersion"
        public static let passwordBoxTimeoutSeconds = "password.boxTimeoutSeconds"
        public static let requirePasswordToDeactivateFromMenu = "requirePasswordToDeactivateFromMenu"
        public static let accessibilityMissingBehavior = "accessibility.missingBehavior"
        // Disconnect feature
        public static let disconnectFeatureEnabled = "disconnect.featureEnabled"
        // Signing-identity fingerprint recorded at successful daemon/sudoers
        // registration time (T-P1-E02-02) — compared at next launch to detect an
        // ad-hoc-to-Developer-ID (or any Team ID) change and trigger a clean migration
        // instead of leaving a stale registration keyed to the old identity.
        public static let disconnectHelperSigningFingerprint = "DisconnectHelperSigningFingerprint"
        // Displays
        public static let displayLinkUUIDs = "displayLinkUUIDs"
        // legacy [Int], read-only fallback. Safe to remove (and drop
        // legacyDisplayLinkSerials/isLegacyDisplayLink below) once no real
        // installed client still has only the legacy serial-based record for
        // a DisplayLink (i.e. once displayLinkUUIDs has fully superseded it
        // for all users) — no dedicated migration guard exists for this one
        // because it degrades gracefully (read-only fallback, never written).
        public static let displayLinkSerials = "displayLinkSerials"
        public static let perDisplayCoverDisabled = "perDisplayCoverDisabled"
        // KVM-excluded displays (T-P1-E13-01): a display whose UUID is in this list
        // never receives a cover window at all — not merely a different sharingType.
        // See shouldCover(uuid:isNew:)'s doc comment in CurtainController.swift for
        // why this is a third category distinct from native .none and DisplayLink
        // .readOnly. Same storage shape as perDisplayCoverDisabled (a [String] of
        // display UUIDs), same get/set style, deliberately: this is a permanent,
        // identity-driven exclusion list, not a runtime-detected state.
        public static let kvmExcludedDisplayUUIDs = "kvmExcludedDisplayUUIDs"
        public static let coverScope = "cover.scope"
        public static let passwordBoxPlacement = "passwordBox.placement"
        public static let passwordBoxSpecificUUID = "passwordBox.specificUUID"
        public static let newDisplayPolicy = "newDisplay.policy"
        // Advanced
        public static let diagnosticsLoggingEnabled = "diagnostics.loggingEnabled"
        public static let hasOnboarded = "hasOnboarded"
        // Password (PBKDF2). algo/salt/iterations/hash are Keychain-backed as
        // of T-P1-E06-01 (see Settings+PasswordSecurity.swift's
        // PasswordMaterial); these string constants remain only as the
        // legacy UserDefaults key names read by the one-time
        // migratePasswordToKeychain() migration in Settings+Migrations.swift.
        public static let passwordAlgo = "password.algo"
        public static let passwordSalt = "password.salt"
        public static let passwordIterations = "password.iterations"
        public static let passwordHash = "password.hash"
        // Attempt-lockout backoff (T-P1-E06-03). Non-secret counters/timestamps only —
        // deliberately UserDefaults, not Keychain (see Settings+PasswordSecurity.swift).
        // Never added to PreferencesWindow.exportableKeys: this is runtime security
        // state, not a user preference to export/import.
        public static let lockoutFailureCount = "lockout.failureCount"
        public static let lockoutUntilTimestamp = "lockout.untilTimestamp"
        // Crash-report monitor (T-P1-E12-04): last-checked marker for
        // /Library/Logs/DiagnosticReports/ scanning. Bare key, no `migrated.*`
        // prefix — this is not a one-time migration guard, it's an ordinary
        // persisted checkpoint updated on every launch (closer in spirit to
        // `disconnectHelperSigningFingerprint` above than to the
        // `migratedOnUnlock`/`migratedCoverScope` guards).
        public static let crashMonitorLastCheckedTimestamp = "crashMonitor.lastCheckedTimestamp"
        // KVM Bridge host (T-P1-E12-04): the hostname/IP of the last
        // successfully deployed-to Pi, persisted so CrashReportMonitor knows
        // where to relay a crash summary independent of the setup wizard's
        // own transient SwiftUI @State. NOT a credential (no token, no key
        // path) — plain hostname/IP, same risk class as any other network
        // config value already in this file (e.g. displayLinkUUIDs).
        public static let kvmBridgeHost = "kvmBridge.host"
        // KVM Bridge shared-secret auth token (security follow-up): the
        // bearer token `KVMBridgeDeployer.sendBridgeAuthToken` generates and
        // relays to the Pi's `/etc/curtain-bridge/auth-token`, echoed back
        // here so `checkHealth`/`CrashReportMonitor` can present it on every
        // request to the Bridge's otherwise-unauthenticated (0.0.0.0-bound)
        // /health and /crash-report endpoints. Deliberately plain
        // UserDefaults, NOT Keychain: this is an operational token for an
        // internal Mac<->Bridge LAN channel, trivially revocable by
        // re-running the setup wizard (which generates and sends a fresh
        // one) -- a materially different risk class from the Telegram bot
        // token (which is NEVER persisted on the Mac at all, see
        // KVMBridgeDeployer's class doc comment) or the unlock password
        // (Keychain-backed, see Settings+PasswordSecurity.swift). Same
        // storage-risk tier as kvmDeviceVendorID/kvmExcludedDisplayUUIDs
        // above.
        public static let kvmBridgeAuthToken = "kvmBridge.authToken"
        // KVM device identity (T-P1-E13-02): the TinyPilot's registered USB HID
        // identity, captured once during E-11's setup-wizard pairing flow. This is
        // a storage CONTRACT — E-11's pairing UI is responsible for writing these
        // values; this file only defines the keys and the read-side accessors that
        // KVMInputFilter.swift consumes. vendorID/productID are required together
        // (both nil == "no KVM registered yet"); locationID is optional/advisory
        // (see KVMDeviceIdentity's doc comment in KVMInputFilter.swift for why).
        public static let kvmDeviceVendorID = "kvmDevice.vendorID"
        public static let kvmDeviceProductID = "kvmDevice.productID"
        public static let kvmDeviceLocationID = "kvmDevice.locationID"
        // KVM activity notification (T-P1-E13-03): purely optional situational
        // awareness ("the KVM operator is active right now"), independently
        // toggleable and off by default per this file's fail-safe-default
        // convention for optional features (see disconnectFeatureEnabled above).
        // Deliberately NOT read anywhere in CurtainController.shouldCover(...) or
        // KVMInputFilter's seize/pass-through decision — this key only gates
        // whether KVMActivityNotifier.notify() calls Notifier.post(...).
        // NOTE: as of T-P1-E13-03, KVMActivityNotifier is not yet instantiated or
        // attached anywhere in production code, because KVMInputFilter itself
        // (T-P1-E13-02) has no production owner yet either — no ticket has wired
        // KVMInputFilter.activate()/deactivate() into a real "entering/leaving the
        // KVM context" trigger. Flipping this Preferences toggle on today has no
        // observable effect until a later ticket wires both. See KVMActivityNotifier
        // .swift's doc comment for the same note.
        public static let kvmActivityNotificationEnabled = "kvmActivity.notificationEnabled"
        // Mac-side MCP server (T-P1-E14-01): opt-in, off-by-default local server
        // exposing exactly one read-only tool, `curtain_status`. Off by default per
        // this file's fail-safe-default convention for new attack surfaces (same
        // posture as disconnectFeatureEnabled/kvmActivityNotificationEnabled above).
        // T-P1-E14-03 builds the Settings UI toggle bound to this exact key; this
        // ticket (T-P1-E14-01) only adds the key + default registration and reads it
        // at server-start time. NEVER read/written by any mutating code path — this
        // key only gates whether MCPServer.start() is called.
        public static let mcpServerEnabled = "mcpServer.enabled"
        // KVM Settings section visibility (T-P1-E14-03): off by default. Unlike every
        // other PrefSection, .kvm is genuinely absent from the Preferences sidebar
        // (not merely defaulted-off-but-visible) unless this flag is true, since the
        // vast majority of Curtain users do not own KVM hardware and the section
        // would be pure clutter/surface-area for them. Flipped true by the discovery
        // path (PrefAdvancedTab's "Set Up KVM Bridge…" button) so the section becomes
        // reachable the moment a user shows interest in the hardware, without a
        // separate "please enable this section" step. This is the first
        // default-off-AND-hidden-until-opted-in PrefSection in the codebase — every
        // prior section is always visible in the sidebar with its *contents*
        // defaulted off, not the sidebar entry itself.
        public static let kvmSectionEnabled = "kvmSection.enabled"
    }

    /// Register sensible, safe defaults once at launch.
    public static func registerDefaults() {
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
            Key.idleSource: Key.idleSourceDefault,
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
            Key.kvmActivityNotificationEnabled: false,
            Key.mcpServerEnabled: false,
            Key.kvmSectionEnabled: false
        ])
        runMigrations()
    }

    /// Shared UserDefaults handle. Default (internal) access — not `private`
    /// or `fileprivate` — so the Settings+Migrations.swift and
    /// Settings+PasswordSecurity.swift extensions (separate files, same
    /// module) can reuse it without duplicating a second
    /// UserDefaults.standard reference. Swift's `fileprivate` does not cross
    /// file boundaries even for extensions on the same type, so `internal`
    /// is the correct minimum here.
    /// `var`, not `let` (T-P1-E05-03): a minimal test-only seam so
    /// CurtainCoreTests can point Settings at an isolated
    /// `UserDefaults(suiteName:)` instance instead of `.standard`, avoiding
    /// any pollution of real app state. Production code never reassigns
    /// this — it stays `.standard` for the app's entire lifetime.
    static var d = UserDefaults.standard

    // MARK: - General
    public static var armed: Bool {
        get { d.bool(forKey: Key.armed) }
        set { d.set(newValue, forKey: Key.armed) }
    }
    public static var launchAtLogin: Bool {
        get { d.bool(forKey: Key.launchAtLogin) }
        set { d.set(newValue, forKey: Key.launchAtLogin) }
    }
    public static var showInMenuBar: Bool {
        get { d.bool(forKey: Key.showInMenuBar) }
        set { d.set(newValue, forKey: Key.showInMenuBar) }
    }

    // MARK: - Reveal trigger
    public static var revealTrigger: String {
        get { d.string(forKey: Key.revealTrigger) ?? "anyKey" }
        set { d.set(newValue, forKey: Key.revealTrigger) }
    }
    public static var revealKeyCombo: String {
        get { d.string(forKey: Key.revealKeyCombo) ?? "" }
        set { d.set(newValue, forKey: Key.revealKeyCombo) }
    }
    /// True when any keypress should pop the password box; false only when a specific combo is required.
    public static var revealOnAnyKey: Bool { revealTrigger != "keyCombo" }

    // MARK: - Activation
    public static var onStartActivate: Bool { d.bool(forKey: Key.onStartActivate) }
    public static var connectGraceSeconds: Int { clamp(d.integer(forKey: Key.connectGraceSeconds), 0, 30) }
    public static var notifyOnActivate: Bool { d.bool(forKey: Key.notifyOnActivate) }
    public static var playSoundOnActivate: Bool { d.bool(forKey: Key.playSoundOnActivate) }

    // MARK: - Appearance
    public static var coverStyle: String { d.string(forKey: Key.coverStyle) ?? "logo" }
    public static var coverColorHex: String { d.string(forKey: Key.coverColor) ?? "#000000" }
    public static var coverMessage: String { d.string(forKey: Key.coverMessage) ?? "" }
    public static var coverShowClock: Bool { d.bool(forKey: Key.coverShowClock) }

    // MARK: - Idle
    public static var idleEnabled: Bool { d.bool(forKey: Key.idleEnabled) }
    public static var idleMinutes: Int { clamp(d.integer(forKey: Key.idleMinutes), 1, 240) }
    public static var idleSourceIsHID: Bool { (d.string(forKey: Key.idleSource) ?? Key.idleSourceDefault) == "hidIdle" }

    public static var onIdle: ActionSet {
        ActionSet(
            disconnect: d.bool(forKey: Key.onIdleDisconnect),
            lock: d.bool(forKey: Key.onIdleLock),
            screenOff: d.bool(forKey: Key.onIdleScreenOff),
            deactivateCurtain: d.bool(forKey: Key.onIdleDeactivate))
    }
    public static var onEnd: ActionSet {
        ActionSet(
            disconnect: false,  // already disconnected
            lock: d.bool(forKey: Key.onEndLock),
            screenOff: d.bool(forKey: Key.onEndScreenOff),
            deactivateCurtain: d.bool(forKey: Key.onEndDeactivate))
    }

    // MARK: - Security
    /// On curtain unlock: drop the remote session, or keep it running. Replaces the legacy onPasswordDisconnect bool.
    public static var unlockDisconnect: Bool { d.string(forKey: Key.onUnlockAction) == "disconnect" }
    public static var passwordBoxTimeoutSeconds: Int { clamp(d.integer(forKey: Key.passwordBoxTimeoutSeconds), 5, 60) }
    public static var requirePasswordToDeactivateFromMenu: Bool {
        d.bool(forKey: Key.requirePasswordToDeactivateFromMenu)
    }
    public static var accessibilityRefuseToArm: Bool {
        (d.string(forKey: Key.accessibilityMissingBehavior) ?? "warn") == "refuseToArm"
    }

    // MARK: - Disconnect feature
    public static var disconnectFeatureEnabled: Bool { d.bool(forKey: Key.disconnectFeatureEnabled) }
    /// Signing-identity fingerprint persisted at successful helper registration; nil/empty
    /// means no registration has ever succeeded (fresh install), so the migration check
    /// in DisconnectClient must never fire on an empty value.
    public static var disconnectHelperSigningFingerprint: String? {
        get { d.string(forKey: Key.disconnectHelperSigningFingerprint) }
        set { d.set(newValue, forKey: Key.disconnectHelperSigningFingerprint) }
    }

    // MARK: - Displays
    public static var displayLinkUUIDs: [String] {
        get { (d.array(forKey: Key.displayLinkUUIDs) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.displayLinkUUIDs) }
    }
    /// Legacy serials kept for read-only `isDisplayLink` fallback during migration.
    /// Values outside `UInt32`'s range (a corrupted or hand-edited defaults plist)
    /// are rejected with a logged warning rather than silently truncated by
    /// `truncatingIfNeeded`, which could otherwise wrap an out-of-range Int into a
    /// small, coincidentally-valid-looking serial.
    public static var legacyDisplayLinkSerials: [UInt32] {
        let raw = (d.array(forKey: Key.displayLinkSerials) as? [Int]) ?? []
        return raw.compactMap { value in
            guard let serial = UInt32(exactly: value) else {
                Log.error("Settings.legacyDisplayLinkSerials: dropping out-of-range value \(value) (must fit UInt32)")
                return nil
            }
            return serial
        }
    }
    public static var perDisplayCoverDisabled: [String] {
        get { (d.array(forKey: Key.perDisplayCoverDisabled) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.perDisplayCoverDisabled) }
    }
    /// Displays permanently excluded from ever receiving a cover window (T-P1-E13-01),
    /// e.g. a hardware KVM's dedicated headless HDMI output. Unlike sharingType-based
    /// categories, no cover window is constructed for these at all.
    public static var kvmExcludedDisplayUUIDs: [String] {
        get { (d.array(forKey: Key.kvmExcludedDisplayUUIDs) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.kvmExcludedDisplayUUIDs) }
    }
    public static var coverScope: String { d.string(forKey: Key.coverScope) ?? "all" }
    public static var passwordBoxPlacement: String { d.string(forKey: Key.passwordBoxPlacement) ?? "followActive" }
    public static var passwordBoxSpecificUUID: String { d.string(forKey: Key.passwordBoxSpecificUUID) ?? "" }
    public static var newDisplayPolicy: String { d.string(forKey: Key.newDisplayPolicy) ?? "cover" }

    /// One-time migration: if a display has no UUID record yet but its serial is
    /// in the legacy list, the caller can use this to treat it as a DisplayLink.
    public static func isLegacyDisplayLink(serial: UInt32) -> Bool {
        legacyDisplayLinkSerials.contains(serial)
    }

    // MARK: - Advanced
    public static var diagnosticsLoggingEnabled: Bool { d.bool(forKey: Key.diagnosticsLoggingEnabled) }
    public static var hasOnboarded: Bool {
        get { d.bool(forKey: Key.hasOnboarded) }
        set { d.set(newValue, forKey: Key.hasOnboarded) }
    }

    // MARK: - Crash-report monitor (T-P1-E12-04)
    /// Last time `CrashReportMonitor` finished scanning
    /// `/Library/Logs/DiagnosticReports/`, ISO 8601 UTC (matches
    /// `SessionMonitor`'s heartbeat timestamp format). `nil`/absent means
    /// "never scanned" — the monitor treats that as "scan everything found",
    /// same permissive-default posture as `disconnectHelperSigningFingerprint`.
    public static var crashMonitorLastCheckedTimestamp: String? {
        get { d.string(forKey: Key.crashMonitorLastCheckedTimestamp) }
        set { d.set(newValue, forKey: Key.crashMonitorLastCheckedTimestamp) }
    }

    /// Hostname/IP of the last successfully deployed-to KVM Bridge Pi, or nil
    /// if the setup wizard has never completed a successful deploy. Plain
    /// network config, not a credential.
    public static var kvmBridgeHost: String? {
        get { d.string(forKey: Key.kvmBridgeHost) }
        set { d.set(newValue, forKey: Key.kvmBridgeHost) }
    }

    /// Shared-secret bearer token for the Bridge's /health and
    /// /crash-report endpoints, or nil if the setup wizard has never
    /// generated and sent one yet (e.g. an install that predates this
    /// security fix, and hasn't been re-run through the wizard since).
    /// Plain UserDefaults storage -- see `Key.kvmBridgeAuthToken`'s doc
    /// comment for the risk-tiering reasoning.
    public static var kvmBridgeAuthToken: String? {
        get { d.string(forKey: Key.kvmBridgeAuthToken) }
        set { d.set(newValue, forKey: Key.kvmBridgeAuthToken) }
    }

    // MARK: - KVM device identity (T-P1-E13-02)
    /// Registered TinyPilot vendor ID, or nil if no KVM has been paired yet.
    /// `d.object(forKey:)` (not `d.integer(forKey:)`) so an absent key reads as nil
    /// rather than 0 — 0 is a value a real vendor ID could theoretically hold, and
    /// collapsing "unregistered" into a real-looking value would let
    /// KVMInputFilter's `registeredIdentity` treat "never paired" as "paired with
    /// vendor ID 0", which is exactly the false-positive-active state its
    /// `isEffectivelyActive` guard is designed to prevent.
    public static var kvmDeviceVendorID: Int? {
        get { (d.object(forKey: Key.kvmDeviceVendorID) as? NSNumber)?.intValue }
        set { d.set(newValue, forKey: Key.kvmDeviceVendorID) }
    }
    /// Registered TinyPilot product ID, or nil if no KVM has been paired yet. Same
    /// nil-vs-0 reasoning as `kvmDeviceVendorID` above.
    public static var kvmDeviceProductID: Int? {
        get { (d.object(forKey: Key.kvmDeviceProductID) as? NSNumber)?.intValue }
        set { d.set(newValue, forKey: Key.kvmDeviceProductID) }
    }
    /// Registered TinyPilot location ID, or nil if never paired OR if the pairing
    /// flow deliberately chose not to record one (advisory field — see
    /// KVMDeviceIdentity's doc comment in KVMInputFilter.swift).
    public static var kvmDeviceLocationID: Int? {
        get { (d.object(forKey: Key.kvmDeviceLocationID) as? NSNumber)?.intValue }
        set { d.set(newValue, forKey: Key.kvmDeviceLocationID) }
    }

    /// Whether the optional "KVM operator is actively using the KVM right now"
    /// notification (T-P1-E13-03) is enabled. Off by default (fail-safe default
    /// for an optional/nice-to-have feature, matching `disconnectFeatureEnabled`).
    /// Purely informational — has no relationship to `kvmExcludedDisplayUUIDs` or
    /// `shouldCover(uuid:isNew:)`.
    public static var kvmActivityNotificationEnabled: Bool {
        get { d.bool(forKey: Key.kvmActivityNotificationEnabled) }
        set { d.set(newValue, forKey: Key.kvmActivityNotificationEnabled) }
    }

    // MARK: - Mac-side MCP server (T-P1-E14-01)
    /// Whether Curtain's in-process, loopback-only MCP server (exposing exactly one
    /// read-only tool, `curtain_status`) should start. Off by default — a brand-new
    /// local listener is a new attack surface, so it must be explicitly opted into,
    /// matching `disconnectFeatureEnabled`'s and `kvmActivityNotificationEnabled`'s
    /// fail-safe-default posture above. T-P1-E14-03 builds the Settings UI toggle
    /// bound to this key; until then it can only be flipped via
    /// `defaults write io.acamarata.curtain mcpServer.enabled -bool true` or
    /// directly in tests via `Settings.mcpServerEnabled = true`.
    public static var mcpServerEnabled: Bool {
        get { d.bool(forKey: Key.mcpServerEnabled) }
        set { d.set(newValue, forKey: Key.mcpServerEnabled) }
    }

    // MARK: - KVM Settings section visibility (T-P1-E14-03)
    /// Whether the Preferences sidebar shows the `.kvm` section at all. Off by
    /// default; see `Key.kvmSectionEnabled`'s doc comment for why this section is
    /// hidden rather than merely defaulted-off like every other PrefSection.
    public static var kvmSectionEnabled: Bool {
        get { d.bool(forKey: Key.kvmSectionEnabled) }
        set { d.set(newValue, forKey: Key.kvmSectionEnabled) }
    }

    /// Clamp helper for the bounded integer accessors above. `fileprivate`
    /// (scoped to this file only) — the password/migration extension files
    /// have no need for it, so it stays out of their namespace.
    fileprivate static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
