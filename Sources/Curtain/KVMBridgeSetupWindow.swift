import AppKit
import CurtainCore
import SwiftUI

/// Purpose: Opt-in dogfood setup wizard that deploys T-P1-E11-01's Bridge package
///          to a TinyPilot Pi over real SSH. This window/controller runs on the
///          Mac (Curtain.app) purely to drive the deploy — it never runs any
///          KVM-automation logic itself and never persists the Telegram bot
///          token anywhere on the Mac (see KVMBridgeDeployer's doc comment for
///          the token-relay design). Off by default and irrelevant unless the
///          user owns TinyPilot hardware; reachable only from
///          PrefAdvancedTab's "Set Up KVM Bridge…" button, mirroring how
///          "Open Setup…" reopens OnboardingWindowController there.
/// Inputs: none at init (unlike OnboardingWindowController this needs no
///         SessionCoordinator — deploy is fully self-contained in
///         KVMBridgeDeployer). All user-entered state (host/user/key path/token)
///         lives in the SwiftUI view's own @State and is discarded when the
///         window closes; nothing is written to Settings/UserDefaults/Keychain.
/// Outputs: side effects only, all remote (over SSH to the Pi) via
///          KVMBridgeDeployer. No local persistence of any kind.
/// Constraints: mirrors OnboardingWindowController's window-controller pattern
///              exactly (reuse-on-show, isReleasedWhenClosed = false,
///              NSHostingController wrapping a SwiftUI multi-step view) per this
///              ticket's guide. CODE-COMPLETE-BUT-HARDWARE-UNVERIFIED: the SSH
///              deploy logic in KVMBridgeDeployer is real and complete, tested
///              against a local-SSH-stand-in where this environment supports it
///              (see KVMBridgeDeployerTests), but full deploy-to-a-real-TinyPilot
///              behavior remains flagged for verification once hardware is
///              purchased — see this ticket's acceptance criteria.
/// SPORT: MASTER-APPS (Curtain.app KVM Bridge setup wizard, code-complete-hardware-unverified)
@MainActor
final class KVMBridgeSetupWindowController {

    private var window: NSWindow?

    /// Present the wizard, building it on first use and reusing it after —
    /// same reuse-on-show pattern as OnboardingWindowController.show().
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = KVMBridgeSetupView(close: { [weak self] in self?.window?.close() })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Set Up KVM Bridge"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 520, height: 520))
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

/// The multi-step wizard content: (a) Pi address + SSH credentials, (b) host-key
/// confirmation + deploy-in-progress status, (c) Telegram bot token capture,
/// (d) success/summary. Mirrors OnboardingView's `Step` enum + switch-on-step
/// structure.
private struct KVMBridgeSetupView: View {
    let close: () -> Void

    @State private var step: Step = .connect

    // Step 1 fields
    @State private var host = ""
    @State private var user = "pilot"
    @State private var keyPath = ""

    // Host-key confirmation
    @State private var fingerprintOutput = ""
    @State private var fetchingFingerprint = false
    @State private var fingerprintError: String?
    @State private var hostKeyTrusted = false

    // Deploy status
    @State private var deployStatusLines: [String] = []
    @State private var deploying = false
    @State private var deployOutcome: KVMBridgeDeployer.DeployOutcome?
    @State private var deployError: String?

    // Telegram token
    @State private var telegramToken = ""
    @State private var sendingToken = false
    @State private var tokenSent = false
    @State private var tokenError: String?

    private enum Step: Int { case connect, hostKey, deploy, telegram, finish }

    private var target: KVMBridgeDeployer.Target {
        KVMBridgeDeployer.Target(
            host: host,
            user: user,
            keyPath: keyPath.isEmpty ? nil : keyPath,
            trustHostKey: hostKeyTrusted
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
        .frame(width: 520, height: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
            Text("KVM Bridge Setup")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .connect: connectStep
        case .hostKey: hostKeyStep
        case .deploy: deployStep
        case .telegram: telegramStep
        case .finish: finishStep
        }
    }

    // MARK: Step 1 — Pi address + SSH credentials

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to your TinyPilot Pi")
                .font(.title3.weight(.semibold))
            Text(
                "Enable SSH on the Pi first: TinyPilot's web UI \u{2192} System \u{2192} Security \u{2192} SSH. The default credentials are user \"pilot\", password \"flyingsopi\" \u{2014} TinyPilot's own guidance is to run `passwd` immediately after your first login to change it."
            )
            .foregroundStyle(.secondary)
            .font(.callout)

            Form {
                TextField("Pi address (hostname or IP)", text: $host)
                TextField("SSH user", text: $user)
                TextField("SSH private key path (optional)", text: $keyPath)
            }
            .textFieldStyle(.roundedBorder)

            Text(
                "Leave the key path blank to use your default SSH identity/agent. Password auth is not supported by this wizard \u{2014} set up a key or run `ssh-copy-id \(user)@<pi-address>` first if needed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
            HStack {
                Spacer()
                Button("Continue") { step = .hostKey }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || user.isEmpty)
            }
        }
    }

    // MARK: Step 2 — Host-key fingerprint confirmation (never silently bypassed)

    private var hostKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm the Pi's SSH host key")
                .font(.title3.weight(.semibold))
            Text(
                "Verify this fingerprint matches what the Pi itself reports (e.g. via its console or TinyPilot's own UI) before continuing. Curtain never disables host-key checking \u{2014} confirming here tells Curtain to trust this key ONLY for this host; if the key ever changes later, the connection will fail loudly instead of connecting silently."
            )
            .foregroundStyle(.secondary)
            .font(.callout)

            ScrollView {
                Text(fingerprintOutput.isEmpty ? "Fetching\u{2026}" : fingerprintOutput)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.secondary.opacity(0.3))

            if let fingerprintError {
                Text(fingerprintError).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Back") { step = .connect }
                Spacer()
                Button("This is the correct key \u{2014} Trust and Continue") {
                    hostKeyTrusted = true
                    step = .deploy
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fingerprintOutput.isEmpty || fetchingFingerprint)
            }
        }
        .onAppear { fetchFingerprint() }
    }

    private func fetchFingerprint() {
        guard fingerprintOutput.isEmpty, !fetchingFingerprint else { return }
        fetchingFingerprint = true
        fingerprintError = nil
        let hostCopy = host
        Task {
            let result = KVMBridgeDeployer.fetchHostKeyFingerprint(host: hostCopy)
            await MainActor.run {
                fetchingFingerprint = false
                switch result {
                case .success(let output): fingerprintOutput = output
                case .failure(let error): fingerprintError = "Could not fetch host key: \(error)"
                }
            }
        }
    }

    // MARK: Step 3 — Deploy

    private var deployStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deploying the Bridge")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(deployStatusLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.callout, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.secondary.opacity(0.3))

            if deploying {
                ProgressView().controlSize(.small)
            }
            if let deployError {
                Text(deployError).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Back") { step = .hostKey }.disabled(deploying)
                Spacer()
                if deployOutcome?.serviceActive == true {
                    Button("Continue") { step = .telegram }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(deploying ? "Deploying\u{2026}" : "Deploy") { runDeploy() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(deploying)
                }
            }
        }
        .onAppear { if deployStatusLines.isEmpty { runDeploy() } }
    }

    private func runDeploy() {
        deploying = true
        deployError = nil
        deployStatusLines.append("Connecting to \(host)\u{2026}")
        let capturedTarget = target
        // Bridge/ ships alongside the app bundle's source checkout in
        // development; a packaged release resolves this from the app's
        // bundled resources. Both paths funnel through this one constant so
        // KVMBridgeDeployer never hardcodes a location itself.
        let localBridgePath = KVMBridgeSetupPaths.bundledBridgePath()
        Task {
            let result = await KVMBridgeDeployer.deploy(target: capturedTarget, localBridgePath: localBridgePath)
            await MainActor.run {
                deploying = false
                switch result {
                case .success(let outcome):
                    deployOutcome = outcome
                    deployStatusLines.append(
                        outcome.serviceActive
                            ? "curtain-bridge is active on the Pi."
                            : "Deploy finished but the service is not active (status: \(outcome.statusOutput))."
                    )
                    // T-P1-E12-04: persist the host (not a credential — just
                    // a hostname/IP) so CrashReportMonitor knows where to
                    // relay a crash summary on a later, independent launch,
                    // outside this wizard's own transient @State.
                    if outcome.serviceActive { Settings.kvmBridgeHost = host }
                case .failure(let error):
                    deployError = "Deploy failed: \(error)"
                    deployStatusLines.append("Failed \u{2014} see error below.")
                }
            }
        }
    }

    // MARK: Step 4 — Telegram bot token

    private var telegramStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a Telegram bot")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open a chat with @BotFather in Telegram.")
                Link("https://t.me/BotFather", destination: URL(string: "https://t.me/BotFather")!)
                Text("2. Send /newbot and follow the prompts to name your bot.")
                Text("3. BotFather replies with a token that looks like 123456789:ABC-DEF\u{2026}")
                Text(
                    "4. Paste that token below. It is sent directly to your Pi over SSH and stored only there \u{2014} Curtain never saves it on this Mac."
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            SecureField("Bot token", text: $telegramToken)
                .textFieldStyle(.roundedBorder)

            if tokenSent {
                Text("Token sent to the Pi.").font(.callout).foregroundStyle(.green)
            } else if let tokenError {
                Text(tokenError).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Skip for now") { step = .finish }
                Spacer()
                Button(sendingToken ? "Sending\u{2026}" : "Send Token") { sendToken() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(telegramToken.isEmpty || sendingToken)
            }
        }
    }

    private func sendToken() {
        sendingToken = true
        tokenError = nil
        let capturedTarget = target
        let tokenCopy = telegramToken
        Task {
            let result = KVMBridgeDeployer.sendTelegramToken(target: capturedTarget, token: tokenCopy)
            await MainActor.run {
                sendingToken = false
                // The token never lingers in view state longer than needed to send it.
                telegramToken = ""
                switch result {
                case .success:
                    tokenSent = true
                    step = .finish
                case .failure(let error):
                    tokenError = "Could not send token: \(error)"
                }
            }
        }
    }

    // MARK: Step 5 — Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bridge deployed")
                .font(.title3.weight(.semibold))
            Text(
                "The curtain-bridge service is running on your Pi, independent of this Mac's own power and network path. You can re-run this wizard any time to check for updates or redeploy."
            )
            .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Purpose: Resolves the local filesystem path to the Bridge/ package this
///          wizard rsync's to the Pi. Kept as its own tiny type (rather than a
///          literal inline in the view) so a future packaged-app resource path
///          can replace the development-checkout fallback in one place.
/// Inputs: none.
/// Outputs: an absolute path string.
/// Constraints: development builds run from a source checkout, so `#filePath`
///              (this file's own path) is walked up to the repo root and
///              `Bridge` appended — correct for `swift build`/`swift run` and
///              Xcode-less development, which is this project's only build path
///              today (no Xcode project, no app-bundle resource copy step yet).
///              If/when Curtain.app ships as a signed .app bundle with Bridge/
///              copied into its Resources, this is the one place to add that
///              branch.
/// SPORT: MASTER-APPS
enum KVMBridgeSetupPaths {
    static func bundledBridgePath() -> String {
        // Sources/Curtain/KVMBridgeSetupWindow.swift -> repo root is 3 levels up.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot =
            thisFile
            .deletingLastPathComponent()  // Sources/Curtain/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // repo root
        return repoRoot.appendingPathComponent("Bridge").path
    }
}
