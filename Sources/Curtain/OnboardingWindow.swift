import AppKit
import SwiftUI

/// Purpose: First-run onboarding flow that walks a brand-new user from download
///          to a working setup with no documentation: a five-step SwiftUI window
///          (welcome, accessibility grant, optional disconnect helper, optional
///          password, finish).
/// Inputs: a SessionCoordinator (for the disconnect-helper install) at init.
/// Outputs: side effects only. On finish it sets Settings.hasOnboarded = true,
///          applies LoginItem.set(Settings.launchAtLogin), and closes the window.
/// Constraints: AppKit + SwiftUI are @MainActor. The Accessibility step polls
///              AXIsProcessTrusted() on a ~1s timer; that timer is invalidated
///              when the user leaves step 2 or the window closes, so it never
///              leaks. The window is reused if show() is called again and is not
///              released on close so the controller can re-present it.
/// SPORT: MASTER-ONBOARDING
@MainActor
final class OnboardingWindowController {

    private let coordinator: SessionCoordinator
    private var window: NSWindow?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Present the onboarding window, building it on first use and reusing it after.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(
            enableDisconnectHelper: { [coordinator] on in
                coordinator.enableDisconnectHelper(on)
            },
            finish: { [weak self] in
                self?.completeOnboarding()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Curtain"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 460, height: 460))
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeOnboarding() {
        Settings.hasOnboarded = true
        LoginItem.set(Settings.launchAtLogin)
        window?.close()
    }
}

// MARK: - View

/// The multi-step onboarding content. Holds the current step and the live
/// accessibility-trust flag; the parent controller supplies the two closures
/// that reach into the coordinator and finish the flow.
private struct OnboardingView: View {

    let enableDisconnectHelper: (Bool) -> Void
    let finish: () -> Void

    @State private var step: Step = .welcome
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var axTimer: Timer?

    @State private var disconnectOn = false
    @State private var password = ""
    @State private var passwordSaved = false

    private enum Step: Int { case welcome, accessibility, disconnect, password, finish }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
        .frame(width: 460, height: 460)
        .onDisappear { stopAXPoll() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: CurtainIcon.appIcon(size: 40))
                .resizable()
                .frame(width: 40, height: 40)
            Text("Curtain")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:       welcomeStep
        case .accessibility: accessibilityStep
        case .disconnect:    disconnectStep
        case .password:      passwordStep
        case .finish:        finishStep
        }
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Hide your screen while you work remotely")
                .font(.title3.weight(.semibold))
            Text("Curtain covers your screen and blocks the keyboard and mouse at your desk while you remote in. It locks or sleeps the Mac when the session goes idle or disconnects.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { step = .accessibility }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 2 — Accessibility (required)

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow Curtain to block desk input")
                .font(.title3.weight(.semibold))
            Text("Curtain needs Accessibility permission so it can capture the keyboard and mouse at your desk. Without it, your screen can be covered but input is not blocked.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(axTrusted ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(axTrusted ? "Permission granted" : "Permission not granted yet")
                    .font(.callout)
            }

            Button("Open Accessibility Settings") { openAXSettings() }

            Spacer()
            HStack {
                Button("Skip for now") {
                    stopAXPoll()
                    step = .disconnect
                }
                .help("Curtain will not be able to block keyboard and mouse input.")
                Spacer()
                Button("Continue") {
                    stopAXPoll()
                    step = .disconnect
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!axTrusted)
            }
        }
        .onAppear { startAXPoll() }
    }

    // MARK: Step 3 — Disconnect helper (optional, off)

    private var disconnectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disconnect the remote session (optional)")
                .font(.title3.weight(.semibold))
            Toggle(isOn: $disconnectOn) {
                Text("Also disconnect the remote session on idle or end")
            }
            Text("This needs a one-time admin approval to install a small helper. Most people do not need it. Curtain still locks or sleeps the Mac without it.")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") {
                    if disconnectOn { enableDisconnectHelper(true) }
                    step = .password
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 4 — Password (optional)

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set an unlock password (optional)")
                .font(.title3.weight(.semibold))
            Text("This password unlocks the screen at your desk. If you skip it, the default is \"curtain\" and you can change it later in Settings.")
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                Button("Set") {
                    Settings.setPassword(password)
                    passwordSaved = true
                }
                .disabled(password.isEmpty)
            }
            if passwordSaved {
                Text("Password set.")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Spacer()
            HStack {
                Button("Skip") { step = .finish }
                Spacer()
                Button("Continue") { step = .finish }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 5 — Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're all set")
                .font(.title3.weight(.semibold))
            Text("Curtain runs in the menu bar and starts at login. Open the menu bar icon any time to arm it or change settings.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: AX polling

    private func startAXPoll() {
        axTrusted = AXIsProcessTrusted()
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in axTrusted = AXIsProcessTrusted() }
        }
    }

    private func stopAXPoll() {
        axTimer?.invalidate()
        axTimer = nil
    }

    private func openAXSettings() {
        // macOS 13+ Privacy pane URL; the legacy ?Privacy_Accessibility query-string form
        // stopped reliably opening the Accessibility row on Ventura+ and is dropped here.
        let url = URL(string: "x-apple.systempreferences:com.apple.Privacy-Accessibility-Settings")!
        NSWorkspace.shared.open(url)
    }
}
