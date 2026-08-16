import Foundation

/// Purpose: The pure, UI-free validation core for Settings Import. Given a
///          preference key and a decoded value, decides whether that value is a
///          legal import for that key (correct type, in-range, allowed enum
///          member). Extracted out of `PreferencesWindow`'s private SwiftUI
///          struct — following the same reason `reconcileDiff`/`sharingType`
///          were pulled here in T-P1-E05-05 — so the validation tables and rule
///          logic are reachable from the test target and cannot be reached only
///          via a throwaway harness.
/// Inputs:  a Settings.Key string + the `Any` value decoded from an import file
///          (Bool/Int/Double/String/[String], per AnyCodable's shapes).
/// Outputs: `validate(key:value:)` returns nil on success or a human-readable
///          rejection reason; `isCovered(_:)` reports whether a key has a rule;
///          `allExportableKeysCovered(_:)` lets callers/tests assert 1:1
///          coverage against `exportableKeys` with no gaps or overlaps.
/// Constraints: pure — no AppKit, no UserDefaults, no NSScreen. Safe on any
///          thread/actor. The tables here are the single source of truth the
///          UI layer consults; the confirmation-gate (NSScreen-bound) stays in
///          PreferencesWindow because it needs live display state.
/// SPORT: MASTER-PREFS
public enum SettingsImportValidation {

    /// Accepted string-enum values per key, cross-referenced against
    /// Settings.swift's documented values and every Picker in the Appearance /
    /// Idle&End / Security / Displays tabs. Legacy-only values (coverStyle
    /// "screensaver", coverScope "onlyMarked"/"allExceptMarked") are
    /// intentionally excluded so an import cannot reintroduce a value no current
    /// UI control offers — mirroring migrateCoverScope()'s one-way collapse.
    public static let enumValues: [String: Set<String>] = [
        Settings.Key.coverStyle: ["solidColor", "message", "blur", "logo", "curtainLogo", "aerial"],
        Settings.Key.revealTrigger: ["anyKey", "keyCombo"],
        Settings.Key.onUnlockAction: ["keepSession", "disconnect"],
        Settings.Key.idleSource: ["sessionInput", "hidIdle"],
        Settings.Key.accessibilityMissingBehavior: ["warn", "refuseToArm"],
        Settings.Key.coverScope: ["all", "perDisplay"],
        Settings.Key.passwordBoxPlacement: ["primary", "followActive", "all", "specific"],
        Settings.Key.newDisplayPolicy: ["cover", "leaveUncovered", "treatAsDisplayLink"]
    ]

    /// Range-bound integer keys, matching Settings.swift's clamp() call sites.
    public static let rangeValues: [String: ClosedRange<Int>] = [
        Settings.Key.connectGraceSeconds: 0...30,
        Settings.Key.idleMinutes: 1...240,
        Settings.Key.passwordBoxTimeoutSeconds: 5...60
    ]

    /// Keys expected to decode as a plain Bool.
    public static let boolKeys: Set<String> = [
        Settings.Key.armed, Settings.Key.launchAtLogin, Settings.Key.showInMenuBar,
        Settings.Key.onStartActivate, Settings.Key.notifyOnActivate, Settings.Key.playSoundOnActivate,
        Settings.Key.coverShowClock, Settings.Key.idleEnabled,
        Settings.Key.onIdleDisconnect, Settings.Key.onIdleLock, Settings.Key.onIdleScreenOff,
        Settings.Key.onIdleDeactivate,
        Settings.Key.onEndLock, Settings.Key.onEndScreenOff, Settings.Key.onEndDeactivate,
        Settings.Key.requirePasswordToDeactivateFromMenu, Settings.Key.disconnectFeatureEnabled,
        Settings.Key.diagnosticsLoggingEnabled
    ]

    /// Keys expected to decode as a plain String with no enum restriction.
    public static let freeStringKeys: Set<String> = [
        Settings.Key.coverColor, Settings.Key.coverMessage, Settings.Key.revealKeyCombo,
        Settings.Key.passwordBoxSpecificUUID
    ]

    /// Keys expected to decode as [String].
    public static let stringArrayKeys: Set<String> = [
        Settings.Key.displayLinkUUIDs, Settings.Key.perDisplayCoverDisabled
    ]

    /// Validates a single (key, value) pair against the type/enum/range rule for
    /// that key. Returns nil on success, or a human-readable failure reason.
    /// Every exportableKeys entry has an explicit rule; an unruled key fails
    /// closed rather than passing an unvalidated value through.
    public static func validate(key: String, value: Any) -> String? {
        if let allowed = enumValues[key] {
            guard let s = value as? String else { return "expected a text value, got \(typeName(value))" }
            guard allowed.contains(s) else {
                return
                    "\"\(s)\" is not a recognized value (expected one of: \(allowed.sorted().joined(separator: ", ")))"
            }
            return nil
        }
        if let range = rangeValues[key] {
            guard let i = value as? Int else { return "expected a whole number, got \(typeName(value))" }
            guard range.contains(i) else {
                return "\(i) is out of range (expected \(range.lowerBound)-\(range.upperBound))"
            }
            return nil
        }
        if boolKeys.contains(key) {
            guard value is Bool else { return "expected true/false, got \(typeName(value))" }
            return nil
        }
        if stringArrayKeys.contains(key) {
            guard let arr = value as? [String] else { return "expected a list of text values, got \(typeName(value))" }
            // AnyCodable's decode falls back to "" for anything unrecognized,
            // which would masquerade as a valid empty string inside the array.
            if arr.contains("") { return "contains an unrecognized element" }
            return nil
        }
        if freeStringKeys.contains(key) {
            // Free-text keys accept any String (an empty string is a legitimately
            // empty field) and reject only a genuine type mismatch.
            guard value is String else { return "expected a text value, got \(typeName(value))" }
            return nil
        }
        return "no validation rule defined for this key (rejecting to fail closed)"
    }

    /// True iff `key` maps to exactly one validation bucket.
    public static func isCovered(_ key: String) -> Bool {
        (enumValues[key] != nil) || (rangeValues[key] != nil)
            || boolKeys.contains(key) || freeStringKeys.contains(key) || stringArrayKeys.contains(key)
    }

    /// Asserts 1:1 coverage of `keys` by the validation tables: returns
    /// (uncovered, overlapping) — both empty means every key has exactly one rule.
    public static func coverageGaps(for keys: [String]) -> (uncovered: [String], overlapping: [String]) {
        var uncovered: [String] = []
        var overlapping: [String] = []
        for key in keys {
            var hits = 0
            if enumValues[key] != nil { hits += 1 }
            if rangeValues[key] != nil { hits += 1 }
            if boolKeys.contains(key) { hits += 1 }
            if freeStringKeys.contains(key) { hits += 1 }
            if stringArrayKeys.contains(key) { hits += 1 }
            if hits == 0 { uncovered.append(key) }
            if hits > 1 { overlapping.append(key) }
        }
        return (uncovered, overlapping)
    }

    private static func typeName(_ value: Any) -> String {
        switch value {
        case is Bool: return "a true/false value"
        case is Int: return "a whole number"
        case is Double: return "a decimal number"
        case is String: return "text"
        case is [String]: return "a list"
        default: return "an unrecognized value"
        }
    }
}
