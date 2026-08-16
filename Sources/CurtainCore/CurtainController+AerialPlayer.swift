import Cocoa
import AVFoundation

/// Purpose: Manages the single shared AVQueuePlayer/AVPlayerLooper used by every
///          aerial-style cover window, plus the filesystem search for a readable
///          aerial `.mov` asset to back it.
/// Inputs:  Settings.coverStyle (checked by the caller before building), the
///          on-disk wallpaper/idle-asset aerial video catalogs searched by
///          findAerialVideo().
/// Outputs: aerialPlayer/aerialLooper on CurtainController (consumed by
///          CoverContentView via sharedAerialPlayer()); falls back to the logo
///          cover style when no asset is found or the asset fails an async
///          playability check.
/// Constraints: @MainActor (extension of the main-actor-isolated CurtainController).
///              The async playability check is keyed to the specific player
///              instance it validated (`self.aerialPlayer === queue`) so a stale
///              verdict from a superseded topology rebuild never tears down the
///              replacement player.
/// SPORT: MASTER-CURTAIN
extension CurtainController {

    // MARK: - Shared aerial player

    /// Build the single AVQueuePlayer + AVPlayerLooper used by all aerial covers. The
    /// looper drives gapless, seamless repeat so individual cover views only need to
    /// attach a layer. If the asset fails the async playability check, all aerial
    /// layers are torn down and every cover re-renders at the logo style.
    func buildSharedAerialPlayer() {
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
    func teardownAerialAndSwitchToLogo() {
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
}
