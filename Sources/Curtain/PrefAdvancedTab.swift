import SwiftUI

/// Purpose: Advanced tab — diagnostics toggle, re-open onboarding, settings export /
///          import / reset, and version footer.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage for diagnostics; injected closures for the three settings-file
///          actions and the onboarding re-open; a Binding for hasPassword so Reset can
///          refresh it without coupling to the parent's @State directly.
/// Outputs: writes to UserDefaults (via the closures); no direct coordinator calls.
/// Constraints: @MainActor (SwiftUI). Reset/Export/Import are defined in the parent
///          PreferencesView and passed in as closures so the exportableKeys list stays
///          in one place.
/// SPORT: MASTER-PREFS
struct PrefAdvancedTab: View {
    @AppStorage(Settings.Key.diagnosticsLoggingEnabled) private var diagnosticsLogging = false

    let openOnboarding: () -> Void
    let exportSettings: () -> Void
    let importSettings: () -> Void
    let resetToDefaults: () -> Void

    var body: some View {
        Form {
            Section("Diagnostics") {
                Toggle("Enable diagnostics logging", isOn: $diagnosticsLogging)
            }
            Section("Setup") {
                Button("Open Setup…", action: openOnboarding)
            }
            Section("Settings file") {
                HStack {
                    Button("Export…", action: exportSettings)
                    Button("Import…", action: importSettings)
                }
                Button("Reset to Defaults", role: .destructive, action: resetToDefaults)
            }
            Section {
                HStack(spacing: 10) {
                    Image(nsImage: CurtainIcon.appIcon(size: 28))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Curtain \(appVersion)").font(.callout).bold()
                        Text("Privacy for macOS Screen Sharing")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
