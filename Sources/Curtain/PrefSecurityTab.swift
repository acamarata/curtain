import SwiftUI

/// Purpose: Security tab — unlock action, password-box timeout, require-password
///          toggle, Accessibility behavior, and password change form.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage bindings for security prefs, plus a @Binding for the live
///          hasPassword state so the parent can refresh it after a reset.
/// Outputs: writes to UserDefaults; calls Settings.setPassword on "Set" button press.
/// Constraints: @MainActor (SwiftUI). The fallback password "curtain" always works so
///          the user can never be locked out — the UI calls this out in the footer.
/// SPORT: MASTER-PREFS
struct PrefSecurityTab: View {
    // FIX-5: default literal aligned to registerDefaults ("keepSession" -> "disconnect")
    @AppStorage(Settings.Key.onUnlockAction) private var onUnlockAction = "disconnect"
    @AppStorage(Settings.Key.passwordBoxTimeoutSeconds) private var passwordBoxTimeout = 15
    @AppStorage(Settings.Key.requirePasswordToDeactivateFromMenu) private var requirePasswordToDeactivate = false
    @AppStorage(Settings.Key.accessibilityMissingBehavior) private var accessibilityMissing = "warn"

    @State private var newPassword = ""
    @Binding var hasPassword: Bool

    var body: some View {
        Form {
            Section {
                Picker("On Curtain Unlock", selection: $onUnlockAction) {
                    Text("Keep the remote session active").tag("keepSession")
                    Text("Disconnect the remote session").tag("disconnect")
                }
                Stepper("Password box timeout: \(passwordBoxTimeout)s", value: $passwordBoxTimeout, in: 5...60)
                Toggle("Require the password to deactivate from the menu", isOn: $requirePasswordToDeactivate)
            } header: {
                Text("Unlock")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if onUnlockAction == "disconnect" {
                        Text("Disconnecting on unlock needs the disconnect helper enabled (see the Disconnect tab). Under an ad-hoc local build, enabling it installs a small privileged helper with one admin prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if requirePasswordToDeactivate {
                        warn("The fallback password \"curtain\" always works, so you can never be locked out of your own Mac.")
                    }
                }
            }
            Section {
                Picker("If Accessibility is missing", selection: $accessibilityMissing) {
                    Text("Warn and arm anyway").tag("warn")
                    Text("Refuse to arm").tag("refuseToArm")
                }
            } header: {
                Text("Accessibility")
            } footer: {
                if accessibilityMissing == "refuseToArm" {
                    warn("Curtain will not arm without Accessibility. Grant it in System Settings, or the curtain never engages.")
                }
            }
            Section {
                HStack {
                    SecureField("New unlock password", text: $newPassword)
                    Button("Set") {
                        if !newPassword.isEmpty {
                            Settings.setPassword(newPassword)
                            newPassword = ""
                            hasPassword = Settings.hasPassword
                        }
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                Text(hasPassword ? "A password is set." : "No password set (default: \"curtain\").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func warn(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}
