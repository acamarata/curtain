import SwiftUI
import AppKit
import CurtainCore

/// Purpose: KVM tab — the single landing spot for Curtain's opt-in TinyPilot KVM
///          Bridge feature set: the E-11 setup-wizard entry point, an honest
///          status readout of E-12's Telegram-login-after-reboot flow, a shortcut
///          into E-13's per-display KVM cover exclusion, and the T-P1-E14-01
///          Mac-side MCP server enable toggle. This is the FIRST PrefSection in
///          the codebase that is itself hidden from the sidebar by default (see
///          `Settings.Key.kvmSectionEnabled`'s doc comment in Settings.swift for
///          the filtering mechanism and why no prior precedent exists for it) —
///          every other tab defaults its *contents* off while staying visible;
///          this whole section is absent until a user opts into KVM hardware.
/// Inputs:  openKVMBridgeSetup closure (launches KVMBridgeSetupWindowController);
///          @AppStorage bindings for the MCP-enable and KVM-session-cover flags.
/// Outputs: writes to UserDefaults via @AppStorage; invokes openKVMBridgeSetup.
/// Constraints: @MainActor (SwiftUI). Form/Section/.formStyle(.grouped) to match
///          every other tab file exactly (see PrefAdvancedTab.swift).
///
///          HONESTY AUDIT (per this ticket's guide, reconciling each control
///          against what E-11/E-12/E-13 actually built):
///          - Setup wizard button: REAL. Calls the actual
///            KVMBridgeSetupWindowController.show() (via the injected closure),
///            same call PrefAdvancedTab's "Set Up KVM Bridge…" button already
///            makes.
///          - "Login after Reboot via TG" row: STATUS-ONLY, not a Toggle. E-12
///            (Login-after-Reboot via Telegram) is entirely Bridge/Pi-side: the
///            bot token is captured in the wizard's Telegram step and piped over
///            SSH straight to the Pi's own config file
///            (KVMBridgeDeployer.sendTelegramToken, see its doc comment — "never
///            persists the Telegram token anywhere on the Mac"). There is no
///            Mac-side Settings key that reflects or controls whether Telegram
///            login is active, because the feature's actual enable/disable state
///            genuinely lives only on the Bridge. Binding a Toggle to a
///            Settings key here would control nothing real, so this row is
///            deliberately a status readout (configured or not, inferred from
///            `Settings.kvmBridgeHost` — set once a deploy's health check
///            succeeds) plus a link back into the wizard's Telegram step, never
///            a fake switch.
///          - "Curtain for KVM Sessions" row: E-13 never defined a single master
///            on/off Settings flag beyond its per-display exclusion list
///            (`Settings.kvmExcludedDisplayUUIDs`), and this ticket's scope
///            explicitly excludes rebuilding E-13's logic or inventing a second
///            flag that could drift out of sync with the real per-display state.
///            So the "toggle" here is a plain `@State` disclosure switch (never
///            persisted) that reveals an inline per-display designation list —
///            the SAME real `Settings.kvmExcludedDisplayUUIDs` binding
///            PrefDisplaysTab already uses, added here purely for discoverability
///            per this ticket's scope, not a duplicate or competing source of
///            truth. PrefDisplaysTab's own per-display toggle is untouched.
///          - MCP server enable Toggle: REAL. Bound directly to
///            `Settings.Key.mcpServerEnabled` (T-P1-E14-01) — flipping it only
///            starts/stops that ticket's existing read-only, loopback-only
///            server; no new tool, parameter, or bypass is introduced here.
/// SPORT: MASTER-APPS (Curtain.app KVM Settings section — hidden-by-default
///        PrefSection.kvm, gated by Settings.kvmSectionEnabled)
struct PrefKVMTab: View {
    @AppStorage(Settings.Key.mcpServerEnabled) private var mcpServerEnabled = false

    /// Purely a disclosure switch for the inline per-display list below —
    /// deliberately NOT persisted to Settings (see the type doc comment's
    /// honesty audit): there is no master "KVM sessions" flag to bind to, and
    /// inventing one here that doesn't gate any real behavior would be exactly
    /// the fake-toggle trap this ticket's non-goals warn against.
    @State private var showPerDisplayDesignation = false

    /// Bumped after every per-display toggle edit below so the list re-reads
    /// `Settings.kvmExcludedDisplayUUIDs` fresh, mirroring PrefDisplaysTab's
    /// own `displayRefresh` pattern.
    @State private var displayRefresh = 0

    let openKVMBridgeSetup: () -> Void

    /// Read fresh (not cached in @State) each time the view body evaluates —
    /// this is a status readout of wizard-set state, not a user preference, so
    /// there is no need for it to survive independently of the underlying value.
    private var bridgeConfiguredHost: String? { Settings.kvmBridgeHost }

    var body: some View {
        Form {
            Section {
                Text("For TinyPilot KVM hardware only. Irrelevant unless you own a TinyPilot Pi wired to this Mac's video-out.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("KVM Bridge") {
                Button("Set Up KVM Bridge…", action: openKVMBridgeSetup)
                    .help("Deploys the KVM Bridge package to a TinyPilot Pi over SSH and, optionally, configures Telegram login-after-reboot.")
                if let host = bridgeConfiguredHost {
                    Label("Deployed to \(host)", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Not yet deployed", systemImage: "circle.dashed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if bridgeConfiguredHost != nil {
                    Label("Configured via the KVM Bridge setup wizard", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Not yet configured", systemImage: "circle.dashed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Open Telegram Setup…", action: openKVMBridgeSetup)
            } header: {
                Text("Login after Reboot via Telegram")
            } footer: {
                Text("The Telegram bot token lives only on the Bridge Pi, never on this Mac, so this Mac has no on/off switch for it — set it up or change it from the setup wizard's Telegram step.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Curtain for KVM Sessions", isOn: $showPerDisplayDesignation)
                    .help("Shows the per-display list below — the same designation also available on the Displays tab.")
                if showPerDisplayDesignation {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                        kvmDisplayRow(index: idx, screen: screen)
                    }
                    .id(displayRefresh)
                }
            } header: {
                Text("Curtain for KVM Sessions")
            } footer: {
                Text("Designates which displays skip the cover entirely (e.g. a KVM's dedicated headless output) — same setting as the Displays tab's \u{201C}KVM display — never cover\u{201D} toggle.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable local status server (MCP)", isOn: $mcpServerEnabled)
                    .help("Starts a loopback-only server exposing a single read-only status check, for use only when this Mac is unreachable by any other software means.")
            } header: {
                Text("Automation")
            } footer: {
                Text("Read-only. Off by default. Cannot change any Curtain setting, including this one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A single display's KVM-exclusion row, bound to the exact same
    /// `Settings.kvmExcludedDisplayUUIDs` list PrefDisplaysTab's `displayRow`
    /// binds to (T-P1-E13-01) — a second real control over the same source of
    /// truth, added here for discoverability, not a competing/duplicate flag.
    private func kvmDisplayRow(index: Int, screen: NSScreen) -> some View {
        let uuid = System.uuid(of: screen)
        let shortID = uuid.map { String($0.prefix(8)) } ?? "unknown"
        let res = "\(Int(screen.frame.width))\u{00D7}\(Int(screen.frame.height))"
        let kvmExcluded = Binding<Bool>(
            get: { uuid.map { Settings.kvmExcludedDisplayUUIDs.contains($0) } ?? false },
            set: { newValue in
                guard let u = uuid else { return }
                var list = Settings.kvmExcludedDisplayUUIDs
                if newValue { if !list.contains(u) { list.append(u) } } else { list.removeAll { $0 == u } }
                Settings.kvmExcludedDisplayUUIDs = list
                displayRefresh += 1
            }
        )
        return Toggle("Display \(index) · \(res) · \(shortID) — never cover", isOn: kvmExcluded)
            .font(.caption)
    }
}
