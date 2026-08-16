import SwiftUI
import CurtainCore

/// Purpose: Security tab — unlock action, password-box timeout, require-password
///          toggle, Accessibility behavior, optional KVM-activity notification
///          toggle (T-P1-E13-03), and password change form.
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
    @AppStorage(Settings.Key.kvmActivityNotificationEnabled) private var kvmActivityNotificationEnabled = false

    @State private var newPassword = ""
    @State private var saveFailed = false
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
                        Text(
                            "Disconnecting on unlock needs the disconnect helper enabled (see the Disconnect tab). Under an ad-hoc local build, enabling it installs a small privileged helper with one admin prompt."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if requirePasswordToDeactivate {
                        warn(
                            "The fallback password \"curtain\" always works, so you can never be locked out of your own Mac."
                        )
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
                    warn(
                        "Curtain will not arm without Accessibility. Grant it in System Settings, or the curtain never engages."
                    )
                }
            }
            Section {
                Toggle("Notify when the KVM is actively in use", isOn: $kvmActivityNotificationEnabled)
            } header: {
                Text("KVM")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Optional and informational only — has no effect on which displays are covered. Off by default."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    warn("Not yet active: KVM device pairing and detection are still being built.")
                }
            }
            Section {
                HStack {
                    SecureField("New unlock password", text: $newPassword)
                    Button("Set") {
                        if !newPassword.isEmpty {
                            // Surface a Keychain write failure instead of clearing
                            // the field and reporting success: a silent failure would
                            // leave the previous (possibly "curtain") password in place
                            // while the user believes they changed it.
                            if Settings.setPassword(newPassword) {
                                saveFailed = false
                                newPassword = ""
                                hasPassword = Settings.hasPassword
                            } else {
                                saveFailed = true
                            }
                        }
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                if saveFailed {
                    warn("Could not save the password to the Keychain. It was NOT changed — try again.")
                } else {
                    Text(hasPassword ? "A password is set." : "No password set (default: \"curtain\").")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
