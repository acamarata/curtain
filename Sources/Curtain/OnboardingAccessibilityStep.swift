import CurtainCore
import SwiftUI

/// Purpose: The wizard's Accessibility step. One button asks macOS for the permission
///          (system prompt, which also lists Curtain in Settings) and opens the exact
///          Settings list; the step explains what the list is called on this macOS; and if
///          the switch is on but the grant still is not live, a reset button clears the
///          stale entry and asks again.
/// Inputs: the live trust flag (polled by the parent) and skip/continue callbacks.
/// Outputs: side effects only (system prompt, Settings, tccutil reset).
/// SPORT: MASTER-ONBOARDING
struct OnboardingAccessibilityStep: View {
    let trusted: Bool
    let skip: () -> Void
    let proceed: () -> Void

    @State private var asked = false
    @State private var showReset = false
    @State private var resetFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Curtain to block desk input")
                .font(.title3.weight(.semibold))
            Text(
                "Curtain needs Accessibility permission so it can capture the keyboard and mouse at your desk. Without it, your screen can be covered but input is not blocked."
            )
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle().fill(trusted ? Color.green : Color.red).frame(width: 10, height: 10)
                Text(trusted ? "Permission granted. Continuing…" : "Permission not granted yet").font(.callout)
            }

            if !trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Click Grant Access. macOS asks, then Settings opens on the right list.",
                        systemImage: "1.circle")
                    Label(
                        "Switch Curtain on. The list is called \(AccessibilityPermission.paneNameHint).",
                        systemImage: "2.circle")
                    Label("Come back here. This step continues on its own.", systemImage: "3.circle")
                }
                .font(.callout)

                HStack {
                    Button("Grant Access…") {
                        asked = true
                        AccessibilityPermission.requestAndOpenSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showReset = true }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Open Settings Only") { AccessibilityPermission.openSettings() }
                }

                if showReset {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "Curtain's switch is on but this still says not granted? macOS can keep a stale entry after an update."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Button("Reset and ask again") {
                            resetFailed = !AccessibilityPermission.resetStaleGrant()
                            AccessibilityPermission.requestAndOpenSettings()
                        }
                        if resetFailed {
                            Text(
                                "The reset did not complete. Remove Curtain from the list with the minus button, then click Grant Access."
                            )
                            .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()
            HStack {
                Button("Skip for now", action: skip)
                    .help("Curtain will not be able to block keyboard and mouse input.")
                Spacer()
                Button("Continue", action: proceed)
                    .disabled(!trusted)
            }
        }
    }
}
