import SwiftUI

/// Purpose: General tab — master switch, login-item, menu-bar toggle, activation
///          timing, and manual test actions. Extracted from PreferencesView to keep
///          every tab file under 500 lines.
/// Inputs:  @AppStorage bindings shared with the headless coordinator, plus injected
///          action closures for side-effectful buttons.
/// Outputs: writes to UserDefaults; calls LoginItem.set and onMenuBarToggle.
/// Constraints: @MainActor (SwiftUI); changes are live because AppStorage shares the
///          same UserDefaults domain as the coordinator.
/// SPORT: MASTER-PREFS
struct PrefGeneralTab: View {
    @AppStorage(Settings.Key.armed) private var armed = true
    @AppStorage(Settings.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Settings.Key.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Settings.Key.onStartActivate) private var onStartActivate = true
    @AppStorage(Settings.Key.connectGraceSeconds) private var connectGraceSeconds = 2
    @AppStorage(Settings.Key.notifyOnActivate) private var notifyOnActivate = true
    @AppStorage(Settings.Key.playSoundOnActivate) private var playSoundOnActivate = false

    let activateNow: () -> Void
    let testNow: () -> Void
    let onMenuBarToggle: (Bool) -> Void

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Armed (master switch)", isOn: $armed)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set($0) }
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                    .onChange(of: showInMenuBar) { onMenuBarToggle($0) }
            }
            Section("Activation") {
                Toggle("Activate curtain when a remote session begins", isOn: $onStartActivate)
                Stepper("Connect grace: \(connectGraceSeconds)s", value: $connectGraceSeconds, in: 0...30)
                Toggle("Log a note when the curtain activates", isOn: $notifyOnActivate)
                Toggle("Play a sound when the curtain activates", isOn: $playSoundOnActivate)
            }
            Section {
                HStack {
                    Button("Activate Now", action: activateNow)
                    Button("Test (10s)", action: testNow)
                }
            } header: {
                Text("Manual")
            } footer: {
                Text("Test runs a 10 second curtain so you can check appearance and reveal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
