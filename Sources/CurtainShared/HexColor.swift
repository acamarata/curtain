import Foundation

/// Purpose: convert between a "#rrggbb" hex string and normalized (0...1) RGB
///          components. Pure Foundation so it can be shared between the headless
///          cover renderer and the preferences ColorPicker bridge without AppKit.
public enum HexColor {
    /// Parse a "#rrggbb" (or "rrggbb") string into normalized RGB components.
    /// Returns nil for malformed input.
    public static func toRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return (r, g, b)
    }

    /// Render normalized RGB components (clamped to 0...1) as a "#rrggbb" string.
    public static func fromRGB(_ r: Double, _ g: Double, _ b: Double) -> String {
        let ri = Int(round(min(max(r, 0), 1) * 255))
        let gi = Int(round(min(max(g, 0), 1) * 255))
        let bi = Int(round(min(max(b, 0), 1) * 255))
        return String(format: "#%02x%02x%02x", ri, gi, bi)
    }
}
