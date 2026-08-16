import Cocoa
import AVFoundation
import CurtainShared

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
        setGlyph("🔒")
        messageLabel.stringValue = "Remote Session Active"
        Log.event("aerial unavailable for cover, switched to logo")
    }

    /// Set the decorative lock glyph's text AND its accessibility label together,
    /// so VoiceOver never falls back to reading the raw emoji's default
    /// description ("locked padlock" or similar) instead of a clean, contextual
    /// string. The glyph never carries information messageLabel doesn't already
    /// state, so it stays in the VO-Tab traversal order as a lightweight
    /// corroborating label rather than being removed via
    /// setAccessibilityElement(false) (unlike PasswordBox's fully-redundant glyph).
    private func setGlyph(_ value: String) {
        glyph.stringValue = value
        glyph.setAccessibilityLabel(value.isEmpty ? nil : "Locked")
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
                effectiveStyle = "solidColor"  // video is the backdrop; suppress glyph/message
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
            setGlyph("")
            messageLabel.stringValue = Settings.coverMessage.isEmpty ? "Remote Session Active" : Settings.coverMessage
            messageLabel.font = .systemFont(ofSize: 28, weight: .light)
        case "solidColor":
            setGlyph("")
            messageLabel.stringValue = ""
        case "curtainLogo":
            // Branded look: the app's own curtains artwork drawn large and centered,
            // over a dark backdrop, with a quiet subtitle below it.
            setGlyph("")
            layer?.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor
            let side = min(bounds.width, bounds.height) * 0.3
            let iv = NSImageView(
                frame: NSRect(
                    x: (bounds.width - side) / 2,
                    y: bounds.midY - side / 2 + 24,
                    width: side, height: side))
            iv.image = CurtainIcon.appIcon(size: side)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(iv)
            brandIcon = iv
            messageLabel.stringValue = "Locked — press your key to unlock"
        default:  // "logo", "blur"
            setGlyph("🔒")
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
        // (ST2) Give the banner a real accessibility identity up front so it is
        // independently discoverable via ordinary VO-Tab navigation even outside
        // the active-announcement moment fired below in setWarningVisible(true).
        warning.setAccessibilityRole(.staticText)
        warning.setAccessibilityLabel(warning.stringValue)
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

    /// Show/hide the "desk input not blocked" banner. Becoming visible is a
    /// safety-relevant negative-state transition (physical input has stopped
    /// being intercepted) that a VoiceOver user must be actively told about, not
    /// left to discover only if they happen to already have focus on this part
    /// of the cover — so this posts an .announcementRequested notification in
    /// addition to the existing visual change (ST2). CurtainController only ever
    /// calls this via `cover.window.contentView as? CoverContentView`
    /// (CurtainController.swift's setInputBlocked), i.e. only on a view that is
    /// already installed as a real window's contentView — makeCover() sets
    /// `w.contentView = content` and calls `w.orderFrontRegardless()` before the
    /// Cover is ever returned/stored, so by the time any code path can reach this
    /// view through `covers`, its window is already on-screen. `window` is
    /// re-checked here (not force-unwrapped) purely as defense-in-depth against
    /// a future call site that might construct a CoverContentView without
    /// attaching it — NSAccessibility.post is a documented silent no-op (not a
    /// crash) if the element has no window, so this guard converts that into a
    /// logged, diagnosable condition instead of a quiet failure.
    func setWarningVisible(_ visible: Bool) {
        warning.isHidden = !visible
        guard visible else { return }
        guard window != nil else {
            Log.event(
                "WARNING: setWarningVisible(true) called before window attachment — VoiceOver announcement suppressed")
            return
        }
        NSAccessibility.post(
            element: warning, notification: .announcementRequested,
            userInfo: [.announcement: warning.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func color(fromHex hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard let rgb = HexColor.toRGB(trimmed) else { return nil }
        return NSColor(red: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
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
