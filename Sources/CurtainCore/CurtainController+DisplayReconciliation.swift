import Cocoa
import ScreenCaptureKit

/// Purpose: Reconciles cover-window topology against live NSScreen state on
///          hot-plug (debounced), and runs the ScreenCaptureKit self-test that
///          validates the sharingType=.none guarantee those covers depend on.
/// Inputs:  NSApplication.didChangeScreenParametersNotification (observed by
///          CurtainController, which calls scheduleReconcile()), live
///          NSScreen.screens at reconcile time.
/// Outputs: Adds/drops Cover entries on CurtainController.covers by display UUID
///          identity; re-anchors the password box and clock; verifyNoneCoverHidden
///          reports (via completion) whether any `.none`-shared cover window is
///          still visible to ScreenCaptureKit (a regression if so).
/// Constraints: @MainActor (extension of the main-actor-isolated CurtainController).
///              reconcile() is debounced 0.3s via scheduleReconcile() so rapid
///              successive screen-parameter notifications during a hot-plug
///              collapse into a single rebuild.
/// SPORT: MASTER-CURTAIN
extension CurtainController {

    // MARK: - Topology reconcile

    func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func reconcile() {
        guard !covers.isEmpty else { return }

        let beforeCount = covers.count
        var liveByUUID: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let uuid = uuidKey(for: screen) { liveByUUID[uuid] = screen }
        }

        // UUID-identity diff (not index-based): which covered UUIDs are no longer
        // live, and which live UUIDs aren't covered yet. See reconcileDiff's doc
        // comment for why this must be identity-, not position-, based.
        let diff = CurtainController.reconcileDiff(
            coveredUUIDs: Set(covers.keys),
            liveUUIDs: Set(liveByUUID.keys))

        // Drop covers for displays that vanished.
        for uuid in diff.toDrop {
            guard let cover = covers[uuid] else { continue }
            (cover.window.contentView as? CoverContentView)?.teardownAerialLayer()
            cover.window.orderOut(nil)
            covers.removeValue(forKey: uuid)
        }

        // Update survivors (covered both before and after) and add covers for the
        // newly-attached displays reconcileDiff identified.
        for (uuid, screen) in liveByUUID {
            if let cover = covers[uuid] {
                // A survivor whose UUID has since been added to the KVM-exclusion
                // list (e.g. the user toggled it on live, mid-session, while a
                // cover was already showing) must be torn down, not merely have
                // its sharingType adjusted — reuse the exact same teardown path
                // used above for vanished displays so no aerial player or window
                // reference is leaked.
                if Settings.kvmExcludedDisplayUUIDs.contains(uuid) {
                    (cover.window.contentView as? CoverContentView)?.teardownAerialLayer()
                    cover.window.orderOut(nil)
                    covers.removeValue(forKey: uuid)
                    continue
                }
                let window = cover.window
                window.setFrame(screen.frame, display: true)
                window.sharingType = CurtainController.sharingType(isDisplayLink: System.isDisplayLink(screen))
            } else if diff.toAdd.contains(uuid), shouldCover(uuid: uuid, isNew: true) {
                // Re-build the shared player if aerial style was active before and
                // we still have other aerial covers running.
                if Settings.coverStyle == "aerial" && aerialPlayer == nil {
                    buildSharedAerialPlayer()
                }
                covers[uuid] = makeCover(screen: screen, uuid: uuid, forceNewDisplay: true)
            }
        }

        // Release the shared aerial player if no aerial covers remain after both
        // the vanished-display drops above and the KVM-exclusion teardowns and
        // additions in the survivor loop just above — checked last so it sees
        // the fully-settled cover set for this reconcile pass.
        let anyAerialRemains = covers.values.contains {
            ($0.window.contentView as? CoverContentView)?.hasAerialLayer == true
        }
        if !anyAerialRemains {
            aerialLooper = nil
            aerialPlayer = nil
        }

        ensurePasswordBox()
        startClockIfNeeded()
        Log.event("reconcile: displays now \(covers.count) (was \(beforeCount))")
        // Reapply any active warning banner to freshly-built covers.
        if !inputBlocked { setInputBlocked(false) }
    }

    // MARK: - Pure diff helper (extracted for unit testing — T-P1-E05-05)

    /// Pure UUID-identity diff between the currently-covered set and the live set.
    /// Pulled out of `reconcile()` so the identity-based (not index/array-position
    /// based) matching logic is unit testable without a real `NSScreen`. A display
    /// that is in both sets (by UUID) is a survivor and appears in neither output
    /// set — it is neither dropped nor (re)added, regardless of any reordering in
    /// `NSScreen.screens`' enumeration order between reconcile passes.
    nonisolated static func reconcileDiff(coveredUUIDs: Set<String>, liveUUIDs: Set<String>) -> (
        toDrop: Set<String>, toAdd: Set<String>
    ) {
        (coveredUUIDs.subtracting(liveUUIDs), liveUUIDs.subtracting(coveredUUIDs))
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
