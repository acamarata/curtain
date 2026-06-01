import Cocoa

/// Purpose: The visible cover + password box on the host's physical monitors.
/// How: one borderless, max-level, opaque window per display. Native displays use
///      sharingType=.none (invisible to the remote operator, who sees the real
///      desktop); DisplayLink displays use .readOnly. Windows are click-through
///      (ignoresMouseEvents) and never key, so they never interfere with the
///      remote cursor — physical input is blocked by InputFilter, not the window.
/// SPORT: MASTER-CURTAIN
final class CurtainController {
    private var windows: [NSWindow] = []
    private var box: PasswordBox?
    var onUnlock: (() -> Void)?

    var isShown: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = makeWindow(screen: screen, primary: i == 0)
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        box = nil
    }

    /// Feed a physical key into the password box (from InputFilter).
    func physicalKey(_ keycode: Int, _ chars: String?) {
        box?.key(keycode: keycode, chars: chars)
    }

    /// Called once per second to auto-hide the password box after inactivity.
    func tick() { box?.tick() }

    private func makeWindow(screen: NSScreen, primary: Bool) -> NSWindow {
        let w = CoverWindow(contentRect: screen.frame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.sharingType = System.isDisplayLink(screen) ? .readOnly : .none

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor
        content.autoresizingMask = [.width, .height]
        content.addSubview(centeredLabel("🔒", size: 56, y: content.bounds.midY + 12,
                                         color: NSColor(white: 0.30, alpha: 1), width: content.bounds.width))
        content.addSubview(centeredLabel("Remote Session Active", size: 20, y: content.bounds.midY - 40,
                                         color: NSColor(white: 0.50, alpha: 1), width: content.bounds.width))
        if primary {
            let b = PasswordBox(frame: content.bounds)
            b.isHidden = true
            b.autoresizingMask = [.width, .height]
            b.onSuccess = { [weak self] in self?.onUnlock?() }
            content.addSubview(b)
            box = b
        }
        w.contentView = content
        w.orderFrontRegardless()
        return w
    }

    private func centeredLabel(_ s: String, size: CGFloat, y: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.frame = NSRect(x: 0, y: y, width: width, height: size + 16)
        t.alignment = .center; t.font = .systemFont(ofSize: size, weight: .thin)
        t.textColor = color; t.backgroundColor = .clear; t.isBezeled = false; t.isEditable = false
        t.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        return t
    }
}

/// A window that never becomes key, so it can never steal focus from the remote session.
private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Purpose: the on-curtain unlock box. Keystrokes arrive from InputFilter (physical
///          keyboard), never via normal responder chain, so it works while the
///          curtain stays click-through and non-key.
final class PasswordBox: NSView {
    var onSuccess: (() -> Void)?
    private let dots = NSTextField(labelWithString: "")
    private let err = NSTextField(labelWithString: "")
    private var buffer = ""
    private var hideAt: TimeInterval = 0

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let pw = 380.0, ph = 196.0
        let box = NSView(frame: NSRect(x: (frame.width - pw) / 2, y: (frame.height - ph) / 2, width: pw, height: ph))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.98).cgColor
        box.layer?.cornerRadius = 16
        addSubview(box)
        func label(_ s: String, _ y: Double, _ sz: Double, _ c: NSColor) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.frame = NSRect(x: 10, y: y, width: pw - 20, height: 34); t.alignment = .center
            t.textColor = c; t.backgroundColor = .clear; t.isBezeled = false; t.isEditable = false
            t.font = .systemFont(ofSize: sz, weight: .medium); box.addSubview(t); return t
        }
        _ = label("🔒", 144, 38, .white)
        _ = label("Enter password", 120, 14, NSColor(white: 0.85, alpha: 1))
        let field = NSView(frame: NSRect(x: 90, y: 82, width: 200, height: 30))
        field.wantsLayer = true; field.layer?.backgroundColor = NSColor(white: 0.20, alpha: 1).cgColor
        field.layer?.cornerRadius = 6; box.addSubview(field)
        dots.frame = NSRect(x: 90, y: 84, width: 200, height: 26); dots.alignment = .center
        dots.textColor = .white; dots.backgroundColor = .clear; dots.isBezeled = false; dots.isEditable = false
        dots.font = .systemFont(ofSize: 18); box.addSubview(dots)
        err.frame = NSRect(x: 10, y: 56, width: pw - 20, height: 18); err.alignment = .center
        err.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1); err.backgroundColor = .clear
        err.isBezeled = false; err.isEditable = false; err.font = .systemFont(ofSize: 12); err.isHidden = true
        box.addSubview(err)
        _ = label("Return to unlock · Esc to dismiss", 24, 12, NSColor(white: 0.42, alpha: 1))
    }

    private func bump() { hideAt = Date().timeIntervalSince1970 + 6 }
    func tick() { if !isHidden && Date().timeIntervalSince1970 > hideAt { isHidden = true } }

    func key(keycode: Int, chars: String?) {
        if isHidden { buffer = ""; dots.stringValue = ""; err.isHidden = true; isHidden = false }
        bump()
        switch keycode {
        case 36, 76:                                          // Return / Enter
            if Config.shared.verify(buffer) { onSuccess?() }
            else { buffer = ""; dots.stringValue = ""; err.stringValue = "Wrong password"; err.isHidden = false }
        case 53:                                              // Esc
            isHidden = true
        case 51:                                              // Delete
            if !buffer.isEmpty { buffer.removeLast() }
            dots.stringValue = String(repeating: "•", count: buffer.count); err.isHidden = true
        default:
            if let c = chars, let ch = c.first, ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
                buffer += c
                dots.stringValue = String(repeating: "•", count: buffer.count); err.isHidden = true
            }
        }
    }
}
