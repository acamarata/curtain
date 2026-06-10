import SwiftUI
import AppKit
import CurtainShared

/// Purpose: Appearance tab — cover style, color, message, clock, and reveal trigger.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage bindings for cover and reveal prefs.
/// Outputs: writes to UserDefaults; no side-effectful closures needed.
/// Constraints: @MainActor (SwiftUI). Color is persisted as "#rrggbb" hex (shared with
///          the headless cover renderer) so a small Color<->hex bridge is included here.
/// SPORT: MASTER-PREFS
struct PrefAppearanceTab: View {
    // FIX-5: default literal aligned to registerDefaults (was "solidColor", now "logo")
    @AppStorage(Settings.Key.coverStyle) private var coverStyle = "logo"
    @AppStorage(Settings.Key.coverColor) private var coverColorHex = "#000000"
    @AppStorage(Settings.Key.coverMessage) private var coverMessage = ""
    @AppStorage(Settings.Key.coverShowClock) private var coverShowClock = false
    @AppStorage(Settings.Key.revealTrigger) private var revealTrigger = "anyKey"
    @AppStorage(Settings.Key.revealKeyCombo) private var revealKeyCombo = ""

    var body: some View {
        Form {
            Section("Cover") {
                Picker("Cover style", selection: $coverStyle) {
                    Text("Solid color").tag("solidColor")
                    Text("Message").tag("message")
                    Text("Blur").tag("blur")
                    Text("Lock logo").tag("logo")
                    Text("Curtain logo").tag("curtainLogo")
                    Text("Aerial video").tag("aerial")
                }
                if coverStyle == "aerial" {
                    Text("Plays a system aerial video on the covered screens (muted, looping). A keypress still brings up the password. Falls back to the logo if no aerial video is installed. Uses more power than a static cover.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ColorPicker("Cover color", selection: colorBinding, supportsOpacity: false)
                if coverStyle == "message" {
                    TextField("Cover message", text: $coverMessage)
                }
                Toggle("Show a clock on the cover", isOn: $coverShowClock)
            }
            Section {
                Picker("Reveal trigger", selection: $revealTrigger) {
                    Text("Any key").tag("anyKey")
                    Text("Key combo").tag("keyCombo")
                }
                if revealTrigger == "keyCombo" {
                    TextField("Reveal key combo", text: $revealKeyCombo)
                }
            } header: {
                Text("Reveal")
            } footer: {
                if revealTrigger == "keyCombo" {
                    Text("Format: modifiers plus a key, joined by \"+\". For example \"cmd+shift+l\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Color <-> hex bridge

    /// Bridge the stored "#rrggbb" hex string to a SwiftUI Color for the ColorPicker.
    private var colorBinding: Binding<Color> {
        Binding<Color>(
            get: { Self.color(fromHex: coverColorHex) },
            set: { coverColorHex = Self.hex(from: $0) }
        )
    }

    private static func color(fromHex hex: String) -> Color {
        guard let rgb = HexColor.toRGB(hex) else { return .black }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return HexColor.fromRGB(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}
