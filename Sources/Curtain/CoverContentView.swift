import Cocoa
import AVFoundation

/// Purpose: The cover backdrop for one display. Renders per Settings.coverStyle
///          (solidColor / message / blur / logo / curtainLogo / aerial), optionally
///          a live clock, and an Accessibility warning banner when desk input is not
///          blocked. The "aerial" style attaches a layer to the shared AVQueuePlayer
///          provided by CurtainController; a solid opaque base is always installed
///          first so a failed or black video never exposes the desktop beneath.
/// Inputs:  aerialPlayer (optional, from CurtainController), updateClock/
///          setWarningVisible from the controller tick.
/// Outputs: none (pure display).
/// Constraints: @MainActor (AppKit). Layer state torn down in teardownAerialLayer()
///              before the window is discarded; deinit captures locals so the
///              off-main landing is safe.
/// SPORT: MASTER-CURTAIN
@MainActor
final class CoverContentView: NSView {
    private var blurView: NSVisualEffectView?
    private var brandIcon: NSImageView?
    private let glyph = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let warning = NSTextField(labelWithString: "")
    // Aerial-video backdrop state. CoverContentView owns only its own AVPlayerLayer;
    // the AVQueuePlayer and AVPlayerLooper are shared and owned by CurtainController.
    // Only playerLayer is retained here; torn down in teardownAerialLayer().
    private var playerLayer: AVPlayerLayer?

    /// Whether this view currently has an aerial player layer attached. Used by
    /// CurtainController to track how many aerial covers remain after a reconcile.
    var hasAerialLayer: Bool { playerLayer != nil }

    /// Designated initialiser. Pass a non-nil aerialPlayer when the current cover
    /// style is "aerial"; nil for all other styles.
    init(frame frameRect: NSRect, aerialPlayer: AVQueuePlayer?) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        build(aerialPlayer: aerialPlayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // deinit can land off the main actor; capture the view's own AVPlayerLayer
        // and remove it on main. The shared AVQueuePlayer/AVPlayerLooper are owned
        // and torn down by CurtainController, never here.
        let layer = playerLayer
        Task { @MainActor in
            layer?.removeFromSuperlayer()
        }
    }

    /// Stop and remove the aerial video layer (called before a window is dropped or
    /// rebuilt). Idempotent. Releases the AVPlayerLayer; the shared player/looper
    /// are owned by CurtainController and released there after all layers are gone.
    func teardownAerialLayer() {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    /// Re-render this view at the logo style when the async playability check
    /// determines the aerial asset cannot be decoded. Tears down any existing aerial
    /// layer first so the slot is clean, then applies a static logo appearance.
    func applyLogoFallback() {
        teardownAerialLayer()
        glyph.stringValue = "🔒"
        messageLabel.stringValue = "Remote Session Active"
        Log.event("aerial unavailable for cover, switched to logo")
    }

    private func build(aerialPlayer: AVQueuePlayer?) {
        let style = Settings.coverStyle
        let base = color(fromHex: Settings.coverColorHex) ?? NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
        layer?.backgroundColor = base.cgColor

        // The aerial video renders behind every other cover element. If no shared
        // player was provided (asset not found / style not aerial) the view falls
        // through to the branded logo cover. An opaque base color is always set
        // first so a failed or black video never exposes the desktop.
        // Legacy "screensaver" configs are mapped to the safe static logo cover.
        var effectiveStyle = style
        if style == "screensaver" {
            effectiveStyle = "logo"
        } else if style == "aerial" {
            if let player = aerialPlayer {
                installAerialLayer(player: player)
                Log.event("aerial layer attached")
                effectiveStyle = "solidColor"   // video is the backdrop; suppress glyph/message
            } else {
                Log.event("aerial unavailable, using logo")
                effectiveStyle = "logo"
            }
        }
        let renderStyle = effectiveStyle

        if renderStyle == "blur" {
            let v = NSVisualEffectView(frame: bounds)
            v.autoresizingMask = [.width, .height]
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            v.appearance = NSAppearance(named: .darkAqua)
            addSubview(v)
            blurView = v
        }

        // Logo glyph + tagline (logo style, and a sensible default for others).
        glyph.frame = NSRect(x: 0, y: bounds.midY + 12, width: bounds.width, height: 72)
        configureLabel(glyph, size: 56, weight: .thin, color: NSColor(white: 0.30, alpha: 1))
        glyph.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(glyph)

        messageLabel.frame = NSRect(x: 0, y: bounds.midY - 40, width: bounds.width, height: 36)
        configureLabel(messageLabel, size: 20, weight: .regular, color: NSColor(white: 0.50, alpha: 1))
        messageLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(messageLabel)

        switch renderStyle {
        case "message":
            glyph.stringValue = ""
            messageLabel.stringValue = Settings.coverMessage.isEmpty ? "Remote Session Active" : Settings.coverMessage
            messageLabel.font = .systemFont(ofSize: 28, weight: .light)
        case "solidColor":
            glyph.stringValue = ""
            messageLabel.stringValue = ""
        case "curtainLogo":
            // Branded look: the app's own curtains artwork drawn large and centered,
            // over a dark backdrop, with a quiet subtitle below it.
            glyph.stringValue = ""
            layer?.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor
            let side = min(bounds.width, bounds.height) * 0.3
            let iv = NSImageView(frame: NSRect(x: (bounds.width - side) / 2,
                                               y: bounds.midY - side / 2 + 24,
                                               width: side, height: side))
            iv.image = CurtainIcon.appIcon(size: side)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(iv)
            brandIcon = iv
            messageLabel.stringValue = "Locked — press your key to unlock"
        default: // "logo", "blur"
            glyph.stringValue = "🔒"
            messageLabel.stringValue = "Remote Session Active"
        }

        // Live clock (centered, below the tagline). Hidden until updateClock runs.
        clockLabel.frame = NSRect(x: 0, y: bounds.midY - 96, width: bounds.width, height: 30)
        configureLabel(clockLabel, size: 18, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
        clockLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        clockLabel.isHidden = true
        addSubview(clockLabel)

        // Accessibility warning banner (top, hidden until setWarningVisible(true)).
        warning.frame = NSRect(x: 0, y: bounds.height - 64, width: bounds.width, height: 26)
        configureLabel(warning, size: 14, weight: .semibold, color: NSColor(red: 1, green: 0.78, blue: 0.35, alpha: 1))
        warning.stringValue = "Desk input not blocked — grant Accessibility in System Settings"
        warning.autoresizingMask = [.width, .minYMargin]
        warning.isHidden = true
        addSubview(warning)
    }

    private func configureLabel(_ t: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        t.alignment = .center
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.backgroundColor = .clear
        t.isBezeled = false
        t.isEditable = false
    }

    func updateClock(_ stamp: String?) {
        guard let stamp else { clockLabel.isHidden = true; return }
        clockLabel.stringValue = stamp
        clockLabel.isHidden = false
    }

    func setWarningVisible(_ visible: Bool) { warning.isHidden = !visible }

    private func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // MARK: - Aerial layer attachment

    /// Attach an AVPlayerLayer to the shared aerial player. The layer is inserted as
    /// the backmost sublayer so every label, clock, banner, and password box sit above
    /// it. The opaque base color (set in build()) ensures a black or loading frame
    /// never exposes the desktop — the solid background is always visible under the
    /// video layer. Uses aspect-fill so the video covers the full display regardless
    /// of the video's native aspect ratio.
    private func installAerialLayer(player: AVQueuePlayer) {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        wantsLayer = true
        if let host = self.layer {
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.insertSublayer(layer, at: 0)
        }
        self.playerLayer = layer
    }
}
