import Cocoa

/// Purpose: Reconciles cover topology against live NSScreen state on hot-plug (debounced):
///          window covers (DisplayLink displays) and gamma-blanked native displays alike.
/// Inputs:  NSApplication.didChangeScreenParametersNotification (observed by
///          CurtainController, which calls scheduleReconcile()), live
///          NSScreen.screens at reconcile time.
/// Outputs: Adds/drops covers by display UUID identity; re-applies the gamma blackout
///          (macOS resets gamma on reconfiguration); re-anchors the password box and clock.
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
        guard isShown else { return }

        let beforeCount = covers.count + blackedDisplays.count
        var liveByUUID: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let uuid = uuidKey(for: screen) { liveByUUID[uuid] = screen }
        }

        // UUID-identity diff (not index-based): which covered UUIDs are no longer
        // live, and which live UUIDs aren't covered yet. See reconcileDiff's doc
        // comment for why this must be identity-, not position-, based. "Covered" means
        // either a cover window (DisplayLink) or a gamma-blanked native display.
        let diff = CurtainController.reconcileDiff(
            coveredUUIDs: coveredUUIDs,
            liveUUIDs: Set(liveByUUID.keys))

        // Drop covers for displays that vanished.
        for uuid in diff.toDrop {
            dropCover(uuid)
        }

        // Update survivors (covered both before and after) and add covers for the
        // newly-attached displays reconcileDiff identified.
        for (uuid, screen) in liveByUUID {
            let isCovered = covers[uuid] != nil || blackedDisplays[uuid] != nil
            if isCovered {
                // A survivor whose UUID has since been added to the KVM-exclusion
                // list (e.g. the user toggled it on live, mid-session, while a
                // cover was already showing) must be torn down, not merely have
                // its sharingType adjusted — reuse the exact same teardown path
                // used above for vanished displays so no aerial player or window
                // reference is leaked.
                if Settings.kvmExcludedDisplayUUIDs.contains(uuid) {
                    dropCover(uuid)
                    continue
                }
                if let cover = covers[uuid] {
                    let window = cover.window
                    window.setFrame(screen.frame, display: true)
                    window.sharingType = CurtainController.sharingType(isDisplayLink: System.isDisplayLink(screen))
                } else if let id = Self.displayID(of: screen) {
                    blackedDisplays[uuid] = id  // display IDs can change across a reconfiguration
                }
            } else if diff.toAdd.contains(uuid), shouldCover(uuid: uuid, isNew: true) {
                if usesWindowCover(screen: screen, isNew: true) {
                    // Re-build the shared player if aerial style was active before and
                    // we still have other aerial covers running.
                    if Settings.coverStyle == "aerial" && aerialPlayer == nil {
                        buildSharedAerialPlayer()
                    }
                    covers[uuid] = makeCover(screen: screen, uuid: uuid, forceNewDisplay: true)
                } else if let id = Self.displayID(of: screen) {
                    blackedDisplays[uuid] = id
                }
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

        // macOS resets gamma on a display reconfiguration, so re-apply it for the settled set.
        blackout.setTargets(Set(blackedDisplays.values))
        blackout.refresh(force: true)

        ensurePasswordBox()
        startClockIfNeeded()
        Log.event("reconcile: displays now \(covers.count + blackedDisplays.count) (was \(beforeCount))")
        // Reapply any active warning banner to freshly-built covers.
        if !inputBlocked { setInputBlocked(false) }
    }

    /// Remove one display's cover, whichever mechanism holds it.
    private func dropCover(_ uuid: String) {
        if let cover = covers[uuid] {
            (cover.window.contentView as? CoverContentView)?.teardownAerialLayer()
            cover.window.orderOut(nil)
            covers.removeValue(forKey: uuid)
        }
        blackedDisplays.removeValue(forKey: uuid)
        if boxHostUUID == uuid {
            box?.removeFromSuperview()
            box = nil
            tearDownBoxWindow()
            boxHostUUID = nil
        } else if let w = boxWindows.removeValue(forKey: uuid) {
            w.orderOut(nil)
        }
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
}
