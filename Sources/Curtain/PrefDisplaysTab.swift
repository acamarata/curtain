import SwiftUI
import AppKit

/// Purpose: Displays tab — per-display Cover/DisplayLink toggles, cover-scope picker,
///          password-box placement picker (with specific-display sub-picker), new-display
///          policy, and display-tool buttons.
///          Extracted from PreferencesView to keep every tab file under 500 lines.
/// Inputs:  @AppStorage bindings for all display-related prefs; injected closures for
///          the Identify and Mark-as-DisplayLink buttons; displayRefresh trigger from the
///          parent so the list re-reads after a toggle.
/// Outputs: writes to UserDefaults; calls identifyDisplays / markDisplayLink closures.
/// Constraints: @MainActor (SwiftUI). Cover scope uses two values only: "all" (fail-safe
///          default) and "perDisplay" (delegate to per-display Cover toggles). The legacy
///          "onlyMarked"/"allExceptMarked" values are migrated by Settings.registerDefaults.
/// SPORT: MASTER-PREFS
struct PrefDisplaysTab: View {
    // Scope: two-mode model — "all" is the fail-safe, "perDisplay" delegates to toggles.
    @AppStorage(Settings.Key.coverScope) private var coverScope = "all"
    @AppStorage(Settings.Key.passwordBoxPlacement) private var passwordBoxPlacement = "followActive"
    // Stores the UUID of the display chosen for the specific-display password box.
    @AppStorage(Settings.Key.passwordBoxSpecificUUID) private var passwordBoxSpecificUUID = ""
    @AppStorage(Settings.Key.newDisplayPolicy) private var newDisplayPolicy = "cover"

    /// Bumped by the parent to force the dynamic display list to re-read after a toggle.
    let displayRefresh: Int
    let identifyDisplays: () -> Void
    let markDisplayLink: () -> Void
    let onMarkDisplayLink: () -> Void   // called after markDisplayLink so parent can bump refresh

    var body: some View {
        Form {
            Section {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                    displayRow(index: idx, screen: screen)
                }
                .id(displayRefresh)
            } header: {
                Text("Connected displays")
            } footer: {
                Text("DisplayLink monitors can't be hidden invisibly; mark them so the curtain covers them too.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                // Cover-scope: two options — All displays (fail-safe) or Per-display toggles.
                Picker("Cover scope", selection: $coverScope) {
                    Text("All displays").tag("all")
                    Text("Per-display Cover toggles").tag("perDisplay")
                }
                Text("In per-display mode each display's Cover toggle decides; new displays follow the new-display policy below. All displays is the fail-safe default.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Password box placement", selection: $passwordBoxPlacement) {
                    Text("Primary display").tag("primary")
                    Text("Follow active display").tag("followActive")
                    Text("All displays").tag("all")
                    Text("A specific display").tag("specific")
                }

                // Shown only when "specific" is chosen — lets the user pin the password
                // box to one display by UUID. Shows a "(disconnected)" row if the stored
                // UUID is no longer connected, so the selection is never silently lost.
                if passwordBoxPlacement == "specific" {
                    specificDisplayPicker
                }

                Picker("When a new display connects", selection: $newDisplayPolicy) {
                    Text("Cover it").tag("cover")
                    Text("Leave it uncovered").tag("leaveUncovered")
                    Text("Treat it as DisplayLink").tag("treatAsDisplayLink")
                }
            } header: {
                Text("Behavior")
            }

            Section("Tools") {
                HStack {
                    Button("Identify Displays", action: identifyDisplays)
                    Button("Mark Externals as DisplayLink") {
                        markDisplayLink()
                        onMarkDisplayLink()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Per-display row

    private func displayRow(index: Int, screen: NSScreen) -> some View {
        let uuid = System.uuid(of: screen)
        let shortID = uuid.map { String($0.prefix(8)) } ?? "unknown"
        let res = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        let cover = Binding<Bool>(
            get: { uuid.map { !Settings.perDisplayCoverDisabled.contains($0) } ?? true },
            set: { newValue in
                guard let u = uuid else { return }
                var list = Settings.perDisplayCoverDisabled
                if newValue { list.removeAll { $0 == u } } else if !list.contains(u) { list.append(u) }
                Settings.perDisplayCoverDisabled = list
            }
        )
        let displayLink = Binding<Bool>(
            get: { uuid.map { Settings.displayLinkUUIDs.contains($0) } ?? false },
            set: { newValue in
                guard let u = uuid else { return }
                var list = Settings.displayLinkUUIDs
                if newValue { if !list.contains(u) { list.append(u) } } else { list.removeAll { $0 == u } }
                Settings.displayLinkUUIDs = list
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text("Display \(index) · \(res) · \(shortID)").font(.caption).bold()
            HStack {
                Toggle("Cover", isOn: cover)
                Toggle("DisplayLink", isOn: displayLink)
            }
        }
    }

    // MARK: - Specific-display picker for password box

    /// A picker over currently connected displays, using the display's full UUID as the
    /// tag value. If the stored UUID is no longer connected, an extra "(disconnected)"
    /// row preserves the selection so the user can see what was chosen.
    private var specificDisplayPicker: some View {
        let screens = NSScreen.screens
        let connectedUUIDs: [(uuid: String, label: String)] = screens.enumerated().compactMap { idx, s in
            guard let u = System.uuid(of: s) else { return nil }
            let res = "\(Int(s.frame.width))×\(Int(s.frame.height))"
            let short = String(u.prefix(8))
            return (uuid: u, label: "Display \(idx) · \(res) · \(short)")
        }
        let storedIsOrphan = !passwordBoxSpecificUUID.isEmpty
            && !connectedUUIDs.contains(where: { $0.uuid == passwordBoxSpecificUUID })

        return Picker("Specific display", selection: $passwordBoxSpecificUUID) {
            ForEach(connectedUUIDs, id: \.uuid) { item in
                Text(item.label).tag(item.uuid)
            }
            // Keep an orphaned UUID visible so the user knows what was stored and can
            // change it deliberately rather than having it silently reset to empty.
            if storedIsOrphan {
                Text("\(String(passwordBoxSpecificUUID.prefix(8)))… (disconnected)")
                    .tag(passwordBoxSpecificUUID)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
