import CoreGraphics
import Foundation

/// Purpose: Darken the HOST computer's physical monitors without touching what a remote
///          Screen Sharing viewer sees. A display's gamma table is applied at the output
///          stage, after the framebuffer that screen capture reads, so setting it to all
///          zeros blanks the monitor while a capture of the same display is unchanged.
///          This replaces the old cover windows on native displays: `sharingType = .none`
///          is no longer honored by ScreenCaptureKit on macOS 15+ (a `.none` window is still
///          listed on screen to a capture client), so the remote operator saw the cover.
///          Measured on macOS 27: capture luminance 42.6 normal, 42.9 with gamma black.
/// Inputs: the set of display IDs to blank, plus optional pause/resume of one display (the
///          desk password box needs its display visible).
/// Outputs: gamma changes through `GammaControlling` (the system implementation by default).
/// Constraints: gamma changes belong to the process: macOS restores them when Curtain exits
///          or crashes, so a dead Curtain can never leave the monitors black. macOS also
///          resets gamma on display reconfiguration and wake, so `refresh` re-applies it
///          (called from a 1 Hz tick and on those notifications). Restoring a single display
///          is not possible; `restoreAll` resets every display and the rest are re-applied.
/// SPORT: MASTER-CURTAIN
protocol GammaControlling {
    func setBlack(_ display: CGDirectDisplayID)
    func isBlack(_ display: CGDirectDisplayID) -> Bool
    func restoreAll()
}

struct SystemGamma: GammaControlling {
    private static let zeros = [CGGammaValue](repeating: 0, count: 256)

    func setBlack(_ display: CGDirectDisplayID) {
        CGSetDisplayTransferByTable(display, 256, Self.zeros, Self.zeros, Self.zeros)
    }

    func isBlack(_ display: CGDirectDisplayID) -> Bool {
        var r = [CGGammaValue](repeating: 1, count: 256)
        var g = r
        var b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, 256, &r, &g, &b, &count) == .success, count > 0 else { return false }
        let last = Int(count) - 1
        return r[last] <= 0.001 && g[last] <= 0.001 && b[last] <= 0.001
    }

    func restoreAll() { CGDisplayRestoreColorSyncSettings() }
}

@MainActor
final class HostBlackout {
    private let gamma: GammaControlling
    private(set) var targets: Set<CGDirectDisplayID> = []
    private var paused: Set<CGDirectDisplayID> = []

    init(gamma: GammaControlling = SystemGamma()) { self.gamma = gamma }

    var isActive: Bool { !targets.isEmpty }

    /// Replace the set of displays to blank. Displays that left the set are restored.
    func setTargets(_ ids: Set<CGDirectDisplayID>) {
        let removed = !targets.subtracting(ids).isEmpty
        targets = ids
        paused.formIntersection(ids)
        if removed { gamma.restoreAll() }
        refresh(force: removed)
    }

    /// Re-apply the blackout wherever macOS reset it. `force` applies it unconditionally.
    func refresh(force: Bool = false) {
        for id in targets where !paused.contains(id) {
            if force || !gamma.isBlack(id) { gamma.setBlack(id) }
        }
    }

    /// Make one display visible again (the password box is showing on it).
    func pause(_ id: CGDirectDisplayID) {
        guard targets.contains(id), !paused.contains(id) else { return }
        paused.insert(id)
        gamma.restoreAll()
        refresh(force: true)
    }

    /// Make several displays visible at once (the padlock screen is up on all of them).
    func pause(_ ids: Set<CGDirectDisplayID>) {
        let wanted = ids.intersection(targets)
        guard !wanted.isEmpty, wanted != paused else { return }
        paused = wanted
        gamma.restoreAll()
        refresh(force: true)
    }

    /// Black the display out again.
    func resume(_ id: CGDirectDisplayID) {
        guard paused.remove(id) != nil else { return }
        refresh(force: true)
    }

    /// Black every paused display out again.
    func resumeAll() {
        guard !paused.isEmpty else { return }
        paused = []
        refresh(force: true)
    }

    /// Give every display back.
    func restore() {
        targets = []
        paused = []
        gamma.restoreAll()
    }
}
