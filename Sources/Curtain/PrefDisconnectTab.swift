import SwiftUI

/// Purpose: Disconnect tab — privileged-helper toggle and explanatory caption.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage binding for the feature-enabled flag; injected closure that
///          tells the coordinator to register/unregister the SMAppService daemon.
/// Outputs: writes to UserDefaults; calls enableDisconnectHelper when the toggle changes.
/// Constraints: @MainActor (SwiftUI). The helper is off by default; enabling it triggers
///          a one-time admin authorization prompt via SMAppService.
/// SPORT: MASTER-PREFS
struct PrefDisconnectTab: View {
    @AppStorage(Settings.Key.disconnectFeatureEnabled) private var disconnectFeatureEnabled = false
    let enableDisconnectHelper: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Enable disconnect-remote-on-end (needs a one-time admin approval)", isOn: $disconnectFeatureEnabled)
                    .onChange(of: disconnectFeatureEnabled) { enableDisconnectHelper($0) }
            } header: {
                Text("Disconnect helper")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When off, a requested disconnect is logged and skipped rather than calling the privileged helper.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The disconnect action used by unlock, idle, and on-end only fires when this helper is enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
