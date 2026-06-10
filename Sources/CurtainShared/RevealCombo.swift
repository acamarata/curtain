import Foundation

/// Purpose: parse and match a reveal hotkey like "cmd+shift+l" against an incoming
///          physical key-down. Forgiving by design: caps-lock and fn are ignored and
///          only the four real modifiers (cmd/ctrl/option/shift) are compared, so a
///          stray device-dependent bit never blocks a legitimate match.
///
/// This is pure Foundation: modifier flags are matched against documented raw
/// CGEventFlags masks so CurtainShared needs no AppKit/CoreGraphics import.
public enum RevealCombo {
    // Documented CGEventFlags raw values (AppKit-free).
    private static let maskCommand: UInt64 = 0x100000
    private static let maskShift: UInt64 = 0x20000
    private static let maskControl: UInt64 = 0x40000
    private static let maskAlternate: UInt64 = 0x80000

    // Compare only the meaningful modifier bits; drop caps-lock, fn, and device bits.
    private static let meaningfulMask: UInt64 =
        maskCommand | maskControl | maskAlternate | maskShift

    /// Non-character keys we accept by name (keycode), since they carry no usable char.
    private static let namedKeycodes: [String: Int] = [
        "space": 49, "return": 36, "enter": 76, "tab": 48, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51,
    ]

    /// Returns true when the incoming key-down matches the configured combo.
    /// - Parameters:
    ///   - combo: a string like "cmd+shift+l" (separators: `+`, space, or `-`).
    ///   - keycode: the physical key code of the event.
    ///   - chars: the typed character(s), if any.
    ///   - flagsRawValue: the event's modifier flags as a CGEventFlags raw value.
    public static func matches(combo: String, keycode: Int, chars: String?, flagsRawValue: UInt64) -> Bool {
        let parts = combo.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }

        var required: UInt64 = 0
        var finalKey: String?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘":            required |= maskCommand
            case "ctrl", "control", "⌃":           required |= maskControl
            case "opt", "option", "alt", "⌥":      required |= maskAlternate
            case "shift", "⇧":                     required |= maskShift
            default:                                finalKey = p
            }
        }
        guard let key = finalKey else { return false }

        // Modifiers must match exactly within the meaningful set.
        guard (flagsRawValue & meaningfulMask) == (required & meaningfulMask) else { return false }

        // Match a non-character key by keycode, otherwise by the typed character.
        if let kc = namedKeycodes[key] { return kc == keycode }
        return chars?.lowercased() == key
    }
}
