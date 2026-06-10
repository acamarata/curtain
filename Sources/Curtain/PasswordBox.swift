import Cocoa

/// Purpose: The on-curtain unlock box. Keystrokes arrive from InputFilter
///          (physical keyboard), never via the normal responder chain, so it
///          works while the curtain stays click-through and non-key. Respects the
///          shared Settings lockout backoff and auto-hides after inactivity.
/// Inputs:  key() from CurtainController.physicalKey(), tick() at 1 Hz.
/// Outputs: onSuccess closure when the correct password is entered.
/// Constraints: @MainActor. Buffer is zeroed on every state transition (success,
///              failure, lockout, Esc, initial reveal) so the plaintext credential
///              never lingers in memory longer than necessary.
/// SPORT: MASTER-CURTAIN
@MainActor
final class PasswordBox: NSView {
    var onSuccess: (() -> Void)?
    private let dots = NSTextField(labelWithString: "")
    private let err = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: "Enter password")
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
        box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(box)

        func label(_ s: String, _ y: Double, _ sz: Double, _ c: NSColor) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.frame = NSRect(x: 10, y: y, width: pw - 20, height: 34); t.alignment = .center
            t.textColor = c; t.backgroundColor = .clear; t.isBezeled = false; t.isEditable = false
            t.font = .systemFont(ofSize: sz, weight: .medium); box.addSubview(t); return t
        }
        _ = label("🔒", 144, 38, .white)

        prompt.frame = NSRect(x: 10, y: 120, width: pw - 20, height: 34); prompt.alignment = .center
        prompt.textColor = NSColor(white: 0.85, alpha: 1); prompt.backgroundColor = .clear
        prompt.isBezeled = false; prompt.isEditable = false; prompt.font = .systemFont(ofSize: 14, weight: .medium)
        box.addSubview(prompt)

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

    private func bump() { hideAt = Date().timeIntervalSince1970 + Double(Settings.passwordBoxTimeoutSeconds) }

    func tick() {
        guard !isHidden else { return }
        // While locked out, keep the box up and count the backoff down.
        if Settings.isLockedOut { showLockout(); return }
        if Date().timeIntervalSince1970 > hideAt { isHidden = true }
    }

    func key(keycode: Int, chars: String?) {
        if isHidden { buffer = ""; dots.stringValue = ""; err.isHidden = true; isHidden = false }
        bump()

        if Settings.isLockedOut { showLockout(); return }

        switch keycode {
        case 36, 76:                                          // Return / Enter
            if Settings.verify(buffer) {
                Settings.resetFailedAttempts()
                // Zero the buffer and dot display before calling back so the
                // plaintext credential doesn't linger while the curtain comes down.
                buffer = ""
                dots.stringValue = ""
                onSuccess?()
            } else {
                Settings.registerFailedAttempt()
                buffer = ""; dots.stringValue = ""
                if Settings.isLockedOut { showLockout() }
                else { err.stringValue = "Wrong password"; err.isHidden = false }
            }
        case 53:                                              // Esc
            // Clear the buffer and dots before hiding so a partial password attempt
            // is not left in memory or on-screen if the box is re-revealed quickly.
            buffer = ""
            dots.stringValue = ""
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

    private func showLockout() {
        let secs = Int(ceil(Settings.backoffRemaining))
        buffer = ""; dots.stringValue = ""
        err.stringValue = "Try again in \(secs)s"
        err.isHidden = false
    }
}
