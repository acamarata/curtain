import SwiftUI

/// Purpose: Idle & End tab — idle-timeout block and on-disconnect block.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage bindings for idle and end prefs.
/// Outputs: writes to UserDefaults; no side-effectful closures needed.
/// Constraints: @MainActor (SwiftUI). Idle source labels updated to be self-explanatory
///          about what "session input" vs "HID" means for the remote operator.
/// SPORT: MASTER-PREFS
struct PrefIdleEndTab: View {
    @AppStorage(Settings.Key.idleEnabled) private var idleEnabled = true
    @AppStorage(Settings.Key.idleMinutes) private var idleMinutes = 30
    // FIX-5: default literal aligned to registerDefaults (was "hidIdle", now "sessionInput")
    @AppStorage(Settings.Key.idleSource) private var idleSource = "sessionInput"
    @AppStorage(Settings.Key.onIdleDisconnect) private var idleDisconnect = true
    @AppStorage(Settings.Key.onIdleLock) private var idleLock = true
    @AppStorage(Settings.Key.onIdleScreenOff) private var idleScreenOff = true
    @AppStorage(Settings.Key.onIdleDeactivate) private var idleDeactivate = true
    @AppStorage(Settings.Key.onEndLock) private var endLock = true
    @AppStorage(Settings.Key.onEndScreenOff) private var endScreenOff = true
    @AppStorage(Settings.Key.onEndDeactivate) private var endDeactivate = true

    var body: some View {
        Form {
            Section {
                Toggle("Act after the session is idle", isOn: $idleEnabled)
                if idleEnabled {
                    Stepper("After \(idleMinutes) minutes of inactivity:", value: $idleMinutes, in: 1...240)
                    Picker("Inactivity is measured by", selection: $idleSource) {
                        // Tag values are unchanged; only the human-readable labels are updated
                        // to make it obvious that "session input" tracks the remote operator.
                        Text("Remote session activity (recommended)").tag("sessionInput")
                        Text("This Mac's physical input only").tag("hidIdle")
                    }
                    Toggle("Disconnect the remote session", isOn: $idleDisconnect)
                    Toggle("Lock the Mac", isOn: $idleLock)
                    Toggle("Turn off the displays", isOn: $idleScreenOff)
                    Toggle("Deactivate the curtain", isOn: $idleDeactivate)
                }
            } header: {
                Text("On idle")
            } footer: {
                if idleEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        if idleMinutes <= 2 && idleDisconnect {
                            warn("A very short idle timeout with disconnect-on-idle can cut a session during a brief pause.")
                        }
                        if !idleDeactivate && idleScreenOff {
                            warn("Screens go dark on idle but the curtain stays up. The desk shows nothing until you deactivate.")
                        }
                    }
                }
            }
            Section {
                Toggle("Lock the Mac", isOn: $endLock)
                Toggle("Turn off the displays", isOn: $endScreenOff)
                Toggle("Deactivate the curtain", isOn: $endDeactivate)
            } header: {
                Text("When the remote session disconnects")
            } footer: {
                if !endDeactivate && !endLock {
                    warn("On disconnect the Mac is neither locked nor uncovered. It is left covered but unlocked (\"dead but unlocked\").")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Small inline warning row: orange triangle + caption. Used in section footers
    /// to flag dangerous setting combinations without alarming the layout.
    private func warn(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}
