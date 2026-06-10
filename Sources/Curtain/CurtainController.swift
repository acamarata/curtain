import Cocoa
import ScreenCaptureKit
import AVFoundation
import CurtainShared

/// Purpose: Owns all cover windows on the host's physical monitors, plus the shared
///          aerial AVQueuePlayer/AVPlayerLooper. One borderless, max-level, opaque
///          window per display is keyed by display UUID so topology changes are
///          reconciled by identity, not array index. Native displays use sharingType
///          .none (invisible to the remote operator); DisplayLink displays use
///          .readOnly. Windows are click-through (ignoresMouseEvents) and never key so
///          they never interfere with the remote cursor. Physical input is blocked by
///          InputFilter, not by this window. Cover scope, appearance, password-box
///          placement, and new-display policy are driven by Settings with a fail-safe
///          bias: when in doubt, cover the display.
/// Inputs:  physicalKey (from InputFilter), tick (1 Hz), setInputBlocked (from the
///          coordinator's Accessibility check).
/// Outputs: onUnlock on a correct password.
/// Constraints: AppKit is main-actor-isolated under Swift 6 so the whole class is
///              @MainActor. Every timer and observer is torn down in hide(); closures
///              use [weak self] to avoid retain cycles.
/// SPORT: MASTER-CURTAIN
@MainActor
final class CurtainController {

    /// One cover window bound to a physical display, tracked by its stable UUID.
    private struct Cover {
        let uuid: String
        let window: NSWindow
        var isPasswordHost: Bool
    }

    private var covers: [String: Cover] = [:]
    private var box: PasswordBox?
    private var clockTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var reconcileWork: DispatchWorkItem?
    private var inputBlocked = true

    // Shared aerial player — one instance for the whole curtain session so all cover
    // displays loop the same asset in lock-step without each paying the decode cost.
    // Each CoverContentView attaches its own AVPlayerLayer to this player. Nilled in
    // hide() after per-cover teardown, and kept alive in reconcile() while any aerial
    // cover remains.
    private var aerialPlayer: AVQueuePlayer?
    private var aerialLooper: AVPlayerLooper?

    var onUnlock: (() -> Void)?

    var isShown: Bool { !covers.isEmpty }

    // MARK: - Lifecycle

    func show() {
        guard covers.isEmpty else { return }
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
                covers[uuid] = makeCover(screen: screen, uuid: uuid)
            }
        }
        ensurePasswordBox()
        startClockIfNeeded()
        Log.event("cover shown: style=\(Settings.coverStyle) displays=\(covers.count)")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconcile() }
        }

        // Best-effort regression check that a .none cover is excluded from capture.
        CurtainController.verifyNoneCoverHidden { ok in
            if !ok { NSLog("Curtain: SCK self-test — a .none cover was visible in capture (regression)") }
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

        covers.values.forEach {
            ($0.window.contentView as? CoverContentView)?.teardownAerialLayer()
            $0.window.orderOut(nil)
        }
        covers.removeAll()

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
            let allow = Settings.revealOnAnyKey
                || RevealCombo.matches(combo: Settings.revealKeyCombo, keycode: keycode, chars: chars, flagsRawValue: flags)
            guard allow else { return }
        }
        b.key(keycode: keycode, chars: chars)
    }

    /// Called once per second to auto-hide the password box after inactivity.
    func tick() { box?.tick() }

    /// Coordinator reports whether desk input is actually being blocked. When
    /// false, every cover shows a warning banner; when true, banners clear.
    func setInputBlocked(_ blocked: Bool) {
        if !blocked { Log.event("input-not-blocked banner shown") }
        inputBlocked = blocked
        for cover in covers.values {
            (cover.window.contentView as? CoverContentView)?.setWarningVisible(!blocked)
        }
    }

    // MARK: - Shared aerial player

    /// Build the single AVQueuePlayer + AVPlayerLooper used by all aerial covers. The
    /// looper drives gapless, seamless repeat so individual cover views only need to
    /// attach a layer. If the asset fails the async playability check, all aerial
    /// layers are torn down and every cover re-renders at the logo style.
    private func buildSharedAerialPlayer() {
        guard let url = CurtainController.findAerialVideo() else {
            NSLog("Curtain: no aerial video found in any known path; using logo cover")
            return
        }

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        let looper = AVPlayerLooper(player: queue, templateItem: item)

        aerialPlayer = queue
        aerialLooper = looper
        queue.play()

        // Asynchronously verify the asset is actually decodable. If not, tear down
        // all aerial layers and fall back to logo so no cover ever shows a black frame.
        // The Task is keyed to the player it validated: a topology rebuild can replace
        // the shared player while this is in flight, and a stale verdict must never
        // tear down the replacement.
        let asset = item.asset
        Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, self.aerialPlayer === queue else { return }
            if !playable {
                NSLog("Curtain: aerial asset not playable (\(url.lastPathComponent)); switching to logo cover")
                self.teardownAerialAndSwitchToLogo()
            }
        }
    }

    /// Called when the async playability check fails. Removes aerial layers from every
    /// cover and rebuilds them at the logo style, then releases the shared player.
    private func teardownAerialAndSwitchToLogo() {
        for cover in covers.values {
            (cover.window.contentView as? CoverContentView)?.teardownAerialLayer()
            (cover.window.contentView as? CoverContentView)?.applyLogoFallback()
        }
        aerialLooper = nil
        aerialPlayer = nil
    }

    /// Provide the shared player to a cover view that is being built. Returns nil when
    /// no aerial player is active (style is not aerial, or asset failed to load).
    func sharedAerialPlayer() -> AVQueuePlayer? { aerialPlayer }

    // MARK: - Topology reconcile

    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reconcile() {
        guard !covers.isEmpty else { return }

        let beforeCount = covers.count
        var liveByUUID: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let uuid = uuidKey(for: screen) { liveByUUID[uuid] = screen }
        }

        // Drop covers for displays that vanished.
        for (uuid, cover) in covers where liveByUUID[uuid] == nil {
            (cover.window.contentView as? CoverContentView)?.teardownAerialLayer()
            cover.window.orderOut(nil)
            covers.removeValue(forKey: uuid)
        }

        // Release the shared aerial player if no aerial covers remain after drops.
        let anyAerialRemains = covers.values.contains {
            ($0.window.contentView as? CoverContentView)?.hasAerialLayer == true
        }
        if !anyAerialRemains {
            aerialLooper = nil
            aerialPlayer = nil
        }

        // Update survivors and add covers for newly-attached displays.
        for (uuid, screen) in liveByUUID {
            if covers[uuid] != nil {
                let window = covers[uuid]!.window
                window.setFrame(screen.frame, display: true)
                window.sharingType = System.isDisplayLink(screen) ? .readOnly : .none
            } else if shouldCover(uuid: uuid, isNew: true) {
                // Re-build the shared player if aerial style was active before and
                // we still have other aerial covers running.
                if Settings.coverStyle == "aerial" && aerialPlayer == nil {
                    buildSharedAerialPlayer()
                }
                covers[uuid] = makeCover(screen: screen, uuid: uuid, forceNewDisplay: true)
            }
        }

        ensurePasswordBox()
        startClockIfNeeded()
        Log.event("reconcile: displays now \(covers.count) (was \(beforeCount))")
        // Reapply any active warning banner to freshly-built covers.
        if !inputBlocked { setInputBlocked(false) }
    }

    // MARK: - Cover-scope decision

    /// Decide whether a given display should be covered, honoring scope, the
    /// per-display disable list, and (for mid-session arrivals) the new-display
    /// policy. Two modes: "all" (default, fail-safe) and "perDisplay" (honor the
    /// per-display Cover toggle — ON = covered, OFF = uncovered). Legacy values
    /// "onlyMarked"/"allExceptMarked" map to "perDisplay" semantics so the toggle
    /// means what it says. Unknown or missing scope values default to "all" because
    /// an exposed desk is the failure mode we must never reach.
    private func shouldCover(uuid: String, isNew: Bool) -> Bool {
        if isNew {
            switch Settings.newDisplayPolicy {
            case "leaveUncovered": return false
            case "treatAsDisplayLink": return true   // covered as .readOnly
            default: return true                       // "cover"
            }
        }
        let disabled = Settings.perDisplayCoverDisabled.contains(uuid)
        switch Settings.coverScope {
        case "perDisplay",
             "onlyMarked",
             "allExceptMarked":
            return !disabled   // ON = covered; per-display toggle drives this
        default:
            return true        // "all" — every display covered regardless of toggle
        }
    }

    // MARK: - Window construction

    private func makeCover(screen: NSScreen, uuid: String, forceNewDisplay: Bool = false) -> Cover {
        let w = CoverWindow(contentRect: screen.frame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true

        // A new display under "treatAsDisplayLink" is forced to .readOnly so we
        // never assume a fresh, unrecognized panel is hardware-private.
        let treatAsLink = forceNewDisplay && Settings.newDisplayPolicy == "treatAsDisplayLink"
        w.sharingType = (System.isDisplayLink(screen) || treatAsLink) ? .readOnly : .none

        let content = CoverContentView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       aerialPlayer: aerialPlayer)
        w.contentView = content
        w.orderFrontRegardless()
        return Cover(uuid: uuid, window: w, isPasswordHost: false)
    }

    // MARK: - Password box placement

    /// Guarantee exactly one reachable password box, placed per the configured
    /// policy. Recreates/moves the box if its host display vanished on reconcile.
    private func ensurePasswordBox() {
        guard !covers.isEmpty else { box = nil; return }

        let targetUUID = passwordHostUUID()
        // If the box already lives on the right host, keep it.
        if let host = covers.first(where: { $0.value.isPasswordHost }), host.key == targetUUID {
            return
        }
        // Clear the old host flag + remove the old box.
        if let oldKey = covers.first(where: { $0.value.isPasswordHost })?.key {
            covers[oldKey]?.isPasswordHost = false
        }
        box?.removeFromSuperview()
        box = nil

        guard let cover = covers[targetUUID],
              let content = cover.window.contentView as? CoverContentView else { return }

        let b = PasswordBox(frame: content.bounds)
        b.isHidden = true
        b.autoresizingMask = [.width, .height]
        b.onSuccess = { [weak self] in self?.onUnlock?() }
        content.addSubview(b)
        box = b
        covers[targetUUID]?.isPasswordHost = true
    }

    /// Resolve which display hosts the password box for the current placement
    /// mode, always falling back to a display that actually has a cover.
    private func passwordHostUUID() -> String {
        let fallback = primaryCoveredUUID() ?? covers.keys.first ?? ""
        switch Settings.passwordBoxPlacement {
        case "all":
            return fallback   // "all" still anchors one interactive box; banners cover the rest
        case "specific":
            let wanted = Settings.passwordBoxSpecificUUID
            return covers[wanted] != nil ? wanted : fallback
        case "primary":
            return primaryCoveredUUID() ?? fallback
        default: // "followActive"
            return activeCoveredUUID() ?? fallback
        }
    }

    private func primaryCoveredUUID() -> String? {
        if let main = NSScreen.screens.first, let uuid = uuidKey(for: main), covers[uuid] != nil {
            return uuid
        }
        return covers.keys.first
    }

    /// The display under the mouse, else the focused screen — whichever is covered.
    private func activeCoveredUUID() -> String? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let uuid = uuidKey(for: hit), covers[uuid] != nil {
            return uuid
        }
        if let main = NSScreen.main, let uuid = uuidKey(for: main), covers[uuid] != nil {
            return uuid
        }
        return primaryCoveredUUID()
    }

    // MARK: - Live clock

    private func startClockIfNeeded() {
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

    private func uuidKey(for screen: NSScreen) -> String? { System.uuid(of: screen) }

    // MARK: - Aerial asset search

    /// Locate a readable aerial `.mov`, first readable wins. Searches the current
    /// wallpaper aerials directory, then the 4K SDR idle-asset catalog, then a shallow
    /// scan of every Customer subdirectory. Returns nil when nothing readable exists.
    /// Emits an NSLog when all candidate directories are exhausted so the caller can
    /// decide to fall back to the logo style.
    static func findAerialVideo() -> URL? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // 1) Current wallpaper aerial videos.
        let wallpaperDir = "\(home)/Library/Application Support/com.apple.wallpaper/aerials/videos"
        if let url = firstMov(in: wallpaperDir, fm: fm) { return url }

        // 2) The standard 4K SDR 240fps idle-asset catalog.
        let sdrDir = "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"
        if let url = firstMov(in: sdrDir, fm: fm) { return url }

        // 3) Shallow scan of every Customer subdirectory for any readable .mov.
        let customerDir = "/Library/Application Support/com.apple.idleassetsd/Customer"
        if let subdirs = try? fm.contentsOfDirectory(atPath: customerDir) {
            for sub in subdirs.sorted() {
                if let url = firstMov(in: "\(customerDir)/\(sub)", fm: fm) { return url }
            }
        }

        // All candidate paths exhausted — caller uses logo fallback.
        NSLog("Curtain: no aerial video found in any known path; using logo cover")
        return nil
    }

    /// Return the first readable `.mov` directly inside a directory, sorted for a
    /// stable choice across launches. nil if the directory is missing or has none.
    private static func firstMov(in dir: String, fm: FileManager) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for name in entries.sorted() where name.hasSuffix(".mov") {
            let path = "\(dir)/\(name)"
            if fm.isReadableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: - SCK self-test

    /// Capture the main display via ScreenCaptureKit and confirm a `.none` cover
    /// is excluded from the shareable content. SCK omits `.none`-shared windows,
    /// so the heuristic is: if any of our windows are still reported on-screen in
    /// the shareable window list, that's a regression. Best-effort and off the
    /// main thread; falls back to a logged stub if SCK content is unavailable.
    static func verifyNoneCoverHidden(completion: @escaping @Sendable (Bool) -> Void) {
        if #available(macOS 12.3, *) {
            SCShareableContent.getWithCompletionHandler { content, error in
                guard let content, error == nil else {
                    NSLog("Curtain: SCK self-test not run (\(error?.localizedDescription ?? "no content"))")
                    completion(true)
                    return
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                // A correctly-hidden .none cover is absent from the shareable
                // window list. If any of our windows still show up, warn.
                let ourVisible = content.windows.contains {
                    $0.owningApplication?.processID == pid && $0.isOnScreen
                }
                completion(!ourVisible)
            }
        } else {
            NSLog("Curtain: SCK self-test not run (requires macOS 12.3+)")
            completion(true)
        }
    }
}

/// A window that never becomes key, so it can never steal focus from the remote
/// session. Input is blocked by InputFilter, not by this window grabbing events.
final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
