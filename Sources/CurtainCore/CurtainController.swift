import Cocoa
import AVFoundation
import CurtainShared

/// Purpose: Owns all cover windows on the host's physical monitors: window
///          creation/reconciliation by display UUID identity, sharingType
///          assignment, the password-box binding, and the live clock. The
///          shared aerial player is managed in CurtainController+AerialPlayer.swift;
///          topology hot-plug reconcile + the SCK self-test live in
///          CurtainController+DisplayReconciliation.swift. One borderless,
///          max-level, opaque window per display is keyed by display UUID so
///          topology changes are reconciled by identity, not array index.
///          Native displays use sharingType .none (invisible to the remote
///          operator); DisplayLink displays use .readOnly. Windows are
///          click-through and never key so they never interfere with the
///          remote cursor. Physical input is blocked by InputFilter, not by
///          this window. Cover scope/appearance/password-box placement/
///          new-display policy are driven by Settings with a fail-safe bias:
///          when in doubt, cover.
/// Inputs:  physicalKey (from InputFilter), tick (1 Hz), setInputBlocked (from the
///          coordinator's Accessibility check).
/// Outputs: onUnlock on a correct password.
/// Constraints: @MainActor (AppKit is main-actor-isolated under Swift 6). Every
///              timer/observer is torn down in hide(); closures use [weak self].
///              Properties shared with the aerial-player and display-reconciliation
///              extension files are `internal`, not `private` — access levels are
///              file-scoped and wouldn't be visible across the file boundary.
/// SPORT: MASTER-CURTAIN
@MainActor
final class CurtainController {

    /// One cover window bound to a physical display, tracked by its stable UUID.
    struct Cover {
        let uuid: String
        let window: NSWindow
        var isPasswordHost: Bool
    }

    var covers: [String: Cover] = [:]
    var box: PasswordBox?
    private var clockTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    var reconcileWork: DispatchWorkItem?
    var inputBlocked = true

    // Shared aerial player — one instance for the whole curtain session so all cover
    // displays loop the same asset in lock-step without each paying the decode cost.
    // Each CoverContentView attaches its own AVPlayerLayer to this player. Nilled in
    // hide() after per-cover teardown, and kept alive in reconcile() while any aerial
    // cover remains. Managed in CurtainController+AerialPlayer.swift.
    var aerialPlayer: AVQueuePlayer?
    var aerialLooper: AVPlayerLooper?

    var onUnlock: (() -> Void)?

    /// Native displays are darkened by gamma (HostBlackout), not by a cover window, so the
    /// remote Screen Sharing viewer keeps seeing the real desktop. uuid -> display ID.
    var blackedDisplays: [String: CGDirectDisplayID] = [:]
    let blackout = HostBlackout()
    /// The padlock screen: one opaque full-screen window per gamma-blanked display, shown only while
    /// the password box is up (someone touched the desk). The host display's window carries the box.
    var boxWindows: [String: CoverWindow] = [:]
    var boxHostUUID: String?
    private var wakeObservers: [NSObjectProtocol] = []

    var isShown: Bool { !covers.isEmpty || !blackedDisplays.isEmpty }

    /// Every display currently covered, by either mechanism.
    var coveredUUIDs: Set<String> { Set(covers.keys).union(blackedDisplays.keys) }

    // MARK: - Lifecycle

    func show() {
        guard !isShown else { return }
        System.preventDisplaySleep()

        // Build the shared aerial player once before creating cover windows so
        // installAerialLayer() can attach a layer synchronously in makeCover().
        let style = Settings.coverStyle
        if style == "aerial" {
            buildSharedAerialPlayer()
        }

        for screen in NSScreen.screens {
            guard let uuid = uuidKey(for: screen) else { continue }
            if shouldCover(uuid: uuid, isNew: false) {
                if usesWindowCover(screen: screen, isNew: false) {
                    covers[uuid] = makeCover(screen: screen, uuid: uuid)
                } else if let id = Self.displayID(of: screen) {
                    blackedDisplays[uuid] = id
                }
            }
        }
        blackout.setTargets(Set(blackedDisplays.values))
        ensurePasswordBox()
        startClockIfNeeded()
        Log.event(
            "cover shown: style=\(Settings.coverStyle) windowCovers=\(covers.count) blackedOut=\(blackedDisplays.count)"
        )

        // macOS resets gamma on wake; re-apply right away so the monitors never flash the desktop.
        let wake: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.blackout.refresh(force: true)
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.blackout.refresh(force: true)
            }
        }
        wakeObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: wake),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: wake)
        ]

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Immediately (a monitor that just came online must be blanked before the desktop
                // shows), then again after the debounce once the topology has settled.
                self?.reconcile()
                self?.scheduleReconcile()
            }
        }
    }

    func hide() {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        reconcileWork?.cancel()
        reconcileWork = nil
        clockTimer?.invalidate()
        clockTimer = nil

        for token in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wakeObservers = []

        covers.values.forEach {
            ($0.window.contentView as? CoverContentView)?.teardownAerialLayer()
            $0.window.orderOut(nil)
        }
        covers.removeAll()
        blackedDisplays.removeAll()
        blackout.restore()
        tearDownBoxWindow()

        // Release the shared player only after all layers have been removed so no
        // AVPlayerLayer outlives the player that backs it.
        aerialLooper = nil
        aerialPlayer = nil

        box = nil
        System.allowDisplaySleep()
    }

    /// Feed a physical key into the password box (from InputFilter). Gating: while the
    /// box is hidden, only reveal it on any key (when configured) or on the user's
    /// reveal combo. Once the box is visible, every key passes through so the user can
    /// type the password without re-hitting the combo for each character.
    func physicalKey(_ keycode: Int, _ chars: String?, _ flags: UInt64) {
        guard let b = box else { return }
        if b.isHidden {
            let allow =
                Settings.revealOnAnyKey
                || RevealCombo.matches(
                    combo: Settings.revealKeyCombo, keycode: keycode, chars: chars, flagsRawValue: flags)
            guard allow else { return }
        }
        b.key(keycode: keycode, chars: chars)
    }

    /// A physical click at the desk raises the password box when "any key" reveals it.
    func physicalClick() {
        guard Settings.revealOnAnyKey else { return }
        box?.raiseFromClick()
    }

    /// Called once per second to auto-hide the password box after inactivity.
    func tick() {
        box?.tick()
        // Cheap readback; only re-applies where macOS reset a display's gamma.
        if blackout.isActive { blackout.refresh() }
    }

    /// Coordinator reports whether desk input is actually being blocked. When
    /// false, every cover shows a warning banner; when true, banners clear.
    func setInputBlocked(_ blocked: Bool) {
        if !blocked { Log.event("input-not-blocked banner shown") }
        inputBlocked = blocked
        for cover in covers.values {
            (cover.window.contentView as? CoverContentView)?.setWarningVisible(!blocked)
        }
    }

    // MARK: - Cover mechanism

    /// DisplayLink displays only exist as capture (no physical output to darken), so they keep a
    /// `.readOnly` cover window; a display forced to the DisplayLink treatment likewise. Every
    /// other display is darkened by gamma so the remote operator is unaffected.
    func usesWindowCover(screen: NSScreen, isNew: Bool) -> Bool {
        if System.isDisplayLink(screen) { return true }
        return isNew && Settings.newDisplayPolicy == "treatAsDisplayLink"
    }

    nonisolated static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { uuidKey(for: $0) == uuid }
    }

    // MARK: - Cover-scope decision

    /// Decide whether a given display should be covered, honoring scope, the
    /// per-display disable list, the KVM-exclusion list, and (for mid-session
    /// arrivals) the new-display policy.
    ///
    /// Three display-treatment categories exist once a cover *is* built:
    /// native displays get `sharingType .none` (fully excluded from
    /// ScreenCaptureKit/Screen Sharing's capture pipeline, but the window still
    /// physically exists and occupies the framebuffer for anyone looking at the
    /// hardware); DisplayLink-adapter displays (or any display forced via
    /// `Settings.newDisplayPolicy == "treatAsDisplayLink"`) get `sharingType
    /// .readOnly` instead, since they only exist via capture in the first place.
    /// Both of those are ScreenCaptureKit/Screen-Sharing concepts — they change
    /// what a *remote* viewer sees, not what's on the physical port.
    ///
    /// KVM-excluded displays (T-P1-E13-01, `Settings.kvmExcludedDisplayUUIDs`)
    /// are a third, distinct category that sharingType cannot express: a
    /// hardware KVM (e.g. a TinyPilot) taps the literal HDMI signal off the
    /// physical port, upstream of any macOS capture API entirely, so
    /// sharingType is irrelevant to it — even a `.readOnly` cover window still
    /// exists on-screen and physically occupies that display's framebuffer,
    /// which is exactly what must not happen for a raw-HDMI tap. The only
    /// correct behavior is to never construct a cover window for that UUID at
    /// all. This check is therefore the first thing evaluated, unconditionally,
    /// before any coverScope/newDisplayPolicy branch, for both the `isNew` and
    /// survivor paths — and it is driven purely by display identity (UUID), not
    /// by any "is a KVM session active" runtime signal, which is deliberately
    /// not implemented anywhere in this codebase.
    ///
    /// Beyond the KVM gate, two modes govern the remaining, coverable displays:
    /// "all" (default, fail-safe) and "perDisplay" (honor the per-display Cover
    /// toggle — ON = covered, OFF = uncovered). Legacy values
    /// "onlyMarked"/"allExceptMarked" map to "perDisplay" semantics so the toggle
    /// means what it says. Unknown or missing scope values default to "all" because
    /// an exposed desk is the failure mode we must never reach.
    func shouldCover(uuid: String, isNew: Bool) -> Bool {
        if Settings.kvmExcludedDisplayUUIDs.contains(uuid) { return false }
        if isNew {
            switch Settings.newDisplayPolicy {
            case "leaveUncovered": return false
            case "treatAsDisplayLink": return true  // covered as .readOnly
            default: return true  // "cover"
            }
        }
        let disabled = Settings.perDisplayCoverDisabled.contains(uuid)
        switch Settings.coverScope {
        case "perDisplay",
            "onlyMarked",
            "allExceptMarked":
            return !disabled  // ON = covered; per-display toggle drives this
        default:
            return true  // "all" — every display covered regardless of toggle
        }
    }

    // MARK: - Window construction

    func makeCover(screen: NSScreen, uuid: String, forceNewDisplay: Bool = false) -> Cover {
        let w = CoverWindow(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true

        w.sharingType = CurtainController.sharingType(
            isDisplayLink: System.isDisplayLink(screen),
            forceNewDisplay: forceNewDisplay,
            newDisplayPolicy: Settings.newDisplayPolicy)

        let content = CoverContentView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            aerialPlayer: aerialPlayer)
        w.contentView = content
        w.orderFrontRegardless()
        return Cover(uuid: uuid, window: w, isPasswordHost: false)
    }

    // MARK: - Password box placement

    /// Guarantee exactly one reachable password box, placed per the configured
    /// policy. Recreates/moves the box if its host display vanished on reconcile.
    /// A host with a cover window carries the box inside it; a gamma-blanked host gets
    /// a full-screen opaque box window that is shown only while the box is up.
    func ensurePasswordBox() {
        guard isShown else {
            box = nil
            tearDownBoxWindow()
            boxHostUUID = nil
            return
        }

        let targetUUID = passwordHostUUID()
        // If the box already lives on the right host, keep it.
        if box != nil, boxHostUUID == targetUUID {
            syncPadlockWindows()
            return
        }
        // Clear the old host flag + remove the old box.
        if let oldKey = covers.first(where: { $0.value.isPasswordHost })?.key {
            covers[oldKey]?.isPasswordHost = false
        }
        box?.removeFromSuperview()
        box = nil
        tearDownBoxWindow()
        boxHostUUID = nil

        if let cover = covers[targetUUID], let content = cover.window.contentView as? CoverContentView {
            let b = makeBox(frame: content.bounds, host: cover.window as? CoverWindow)
            content.addSubview(b)
            box = b
            covers[targetUUID]?.isPasswordHost = true
            boxHostUUID = targetUUID
        } else if blackedDisplays[targetUUID] != nil, let hostScreen = screen(forUUID: targetUUID) {
            let w = makeBoxWindow(screen: hostScreen)
            let content = NSView(frame: NSRect(origin: .zero, size: hostScreen.frame.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            w.contentView = content
            let b = makeBox(frame: content.bounds, host: w)
            b.onVisibilityChange = { [weak self] visible in self?.boxVisibilityChanged(visible: visible) }
            content.addSubview(b)
            boxWindows[targetUUID] = w
            box = b
            boxHostUUID = targetUUID
            syncPadlockWindows()
        }
    }

    /// Every other gamma-blanked display gets a padlock-only window, so the padlock screen is on
    /// all monitors at once. Called when the box is built and after display changes.
    func syncPadlockWindows() {
        guard box != nil, let host = boxHostUUID else { return }
        for uuid in blackedDisplays.keys where uuid != host && boxWindows[uuid] == nil {
            guard let screen = screen(forUUID: uuid) else { continue }
            let w = makeBoxWindow(screen: screen)
            w.contentView = PadlockView(frame: NSRect(origin: .zero, size: screen.frame.size))
            boxWindows[uuid] = w
        }
        for uuid in boxWindows.keys where blackedDisplays[uuid] == nil {
            boxWindows[uuid]?.orderOut(nil)
            boxWindows.removeValue(forKey: uuid)
        }
    }

    private func makeBox(frame: NSRect, host: CoverWindow?) -> PasswordBox {
        let b = PasswordBox(frame: frame)
        b.isHidden = true
        b.autoresizingMask = [.width, .height]
        b.onSuccess = { [weak self] in self?.onUnlock?() }
        // Accessibility exception (T-P1-E07-01): PasswordBox needs its own host
        // window to grant/revoke key status around the accessible NSSecureTextField
        // path — see CoverWindow.allowsKeyForAccessibility and PasswordBox's header.
        b.hostWindow = host
        return b
    }

    private func makeBoxWindow(screen: NSScreen) -> CoverWindow {
        let w = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        return w
    }

    func tearDownBoxWindow() {
        blackout.resumeAll()
        for w in boxWindows.values { w.orderOut(nil) }
        boxWindows = [:]
    }

    /// The padlock screen is a full-screen opaque window on every gamma-blanked display. Order matters
    /// so the desktop never flashes: when showing, the opaque windows go up BEFORE the displays are made
    /// visible; when hiding, the displays are blanked again BEFORE the windows come down. The remote
    /// viewer sees these black windows for as long as they are up (a deliberate "someone is at the
    /// desk" signal, a few seconds).
    private func boxVisibilityChanged(visible: Bool) {
        if visible {
            syncPadlockWindows()
            for w in boxWindows.values { w.orderFrontRegardless() }
            blackout.pause(Set(blackedDisplays.filter { boxWindows[$0.key] != nil }.map { $0.value }))
        } else {
            blackout.resumeAll()
            for w in boxWindows.values { w.orderOut(nil) }
        }
    }

    /// Resolve which display hosts the password box for the current placement
    /// mode, always falling back to a display that actually has a cover.
    private func passwordHostUUID() -> String {
        let fallback = primaryCoveredUUID() ?? coveredUUIDs.sorted().first ?? ""
        switch Settings.passwordBoxPlacement {
        case "all":
            return fallback  // "all" still anchors one interactive box; banners cover the rest
        case "specific":
            let wanted = Settings.passwordBoxSpecificUUID
            return coveredUUIDs.contains(wanted) ? wanted : fallback
        case "primary":
            return primaryCoveredUUID() ?? fallback
        default:  // "followActive"
            return activeCoveredUUID() ?? fallback
        }
    }

    private func primaryCoveredUUID() -> String? {
        if let main = NSScreen.screens.first, let uuid = uuidKey(for: main), coveredUUIDs.contains(uuid) { return uuid }
        return coveredUUIDs.sorted().first
    }

    /// The display under the mouse, else the focused screen — whichever is covered.
    private func activeCoveredUUID() -> String? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
            let uuid = uuidKey(for: hit), coveredUUIDs.contains(uuid)
        {
            return uuid
        }
        if let main = NSScreen.main, let uuid = uuidKey(for: main), coveredUUIDs.contains(uuid) {
            return uuid
        }
        return primaryCoveredUUID()
    }

    // MARK: - Live clock

    func startClockIfNeeded() {
        let want = Settings.coverShowClock
        if !want {
            clockTimer?.invalidate(); clockTimer = nil
            covers.values.forEach { ($0.window.contentView as? CoverContentView)?.updateClock(nil) }
            return
        }
        guard clockTimer == nil else { tickClock(); return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
        tickClock()
    }

    private func tickClock() {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d   h:mm a"
        let stamp = f.string(from: Date())
        covers.values.forEach { ($0.window.contentView as? CoverContentView)?.updateClock(stamp) }
    }

    // MARK: - UUID helper

    func uuidKey(for screen: NSScreen) -> String? { System.uuid(of: screen) }

    // MARK: - Pure decision helpers (extracted for unit testing — T-P1-E05-05)

    /// Decide a cover window's `NSWindow.SharingType` from plain booleans/strings,
    /// with no `NSScreen`/`Settings` dependency, so the decision itself is unit
    /// testable without a live display. Pulled out of `makeCover()`, which is the
    /// only call site that ever sets `forceNewDisplay`/consults `newDisplayPolicy`
    /// (the reconcile() survivor-update path always passes the defaults, matching
    /// its pre-extraction behavior of `isDisplayLink ? .readOnly : .none` with no
    /// policy check). A DisplayLink display is always `.readOnly` (it only exists
    /// via capture, so `.none` would hide it from the remote view entirely); a
    /// brand-new, unrecognized display is also forced `.readOnly` when the user's
    /// new-display policy says to treat it as one, so an unfamiliar panel is never
    /// assumed to be a private native display by default.
    nonisolated static func sharingType(
        isDisplayLink: Bool,
        forceNewDisplay: Bool = false,
        newDisplayPolicy: String = ""
    ) -> NSWindow.SharingType {
        let treatAsLink = forceNewDisplay && newDisplayPolicy == "treatAsDisplayLink"
        return (isDisplayLink || treatAsLink) ? .readOnly : .none
    }
}

/// A window that never becomes key, so it can never steal focus from the remote
/// session. Input is blocked by InputFilter, not by this window grabbing events.
///
/// Accessibility exception (T-P1-E07-01): `allowsKeyForAccessibility`, when set true,
/// lets this one window become key/main and receive mouse events. It is flipped on
/// ONLY for the single password-host window, ONLY while VoiceOver or Switch Control
/// is running (see PasswordBox.AccessibleField), and ONLY for as long as the
/// accessible secure-text-field path is attached. This is the narrow, explicit trust-
/// boundary widening documented in PasswordBox.swift's header comment: a real
/// NSSecureTextField in the normal responder chain necessarily accepts keystrokes/
/// clicks from anything that can reach it while shown, not just physical hardware.
final class CoverWindow: NSWindow {
    var allowsKeyForAccessibility = false
    override var canBecomeKey: Bool { allowsKeyForAccessibility }
    override var canBecomeMain: Bool { allowsKeyForAccessibility }
}
