import Cocoa

/// Purpose: The on-curtain unlock box. Physical keystrokes arrive from InputFilter
///          (never via the normal responder chain), so it works while the curtain
///          stays click-through and non-key. Respects the shared Settings lockout
///          backoff and auto-hides after inactivity.
/// Inputs:  key() from CurtainController.physicalKey(), tick() at 1 Hz.
/// Outputs: onSuccess closure when the correct password is entered.
/// Constraints: @MainActor. Buffer is zeroed on every state transition (success,
///              failure, lockout, Esc, initial reveal) so the plaintext credential
///              never lingers in memory longer than necessary.
///
/// Accessibility (T-P1-E07-01): the physical-key path above is invisible to
/// assistive technology in two independent ways: (1) every rendered element was a
/// plain, non-accessible NSTextField label, so VoiceOver had nothing to announce;
/// (2) even with labels, VoiceOver/Switch Control synthesize standard AX actions
/// and NSEvents that travel through the *normal* responder chain, which this view
/// never joins — CoverWindow.canBecomeKey is hardcoded false and the window
/// ignores mouse events, by design, so the remote session is never interfered with.
/// Two independent fixes, both shipped here:
///   (a) Real NSAccessibility label/value/role on the prompt, masked-value field,
///       and error/lockout label, so VoiceOver announces state correctly. This
///       alone does NOT solve input — see (b).
///   (b) AccessibleField: a genuine NSSecureTextField, shown only while
///       NSWorkspace.shared.isVoiceOverEnabled or .isSwitchControlEnabled is true
///       (both public, KVO-observable, macOS 10.13+ APIs — there is no equivalent
///       public flag for Voice Control; its dictation/commands are delivered as
///       ordinary synthesized keyboard events through the same responder chain,
///       so they are covered by this path once it is live for VoiceOver/Switch
///       Control users triggering it, and by the physical path's CGEventTap
///       otherwise). While shown, PasswordBox asks its hostWindow (a CoverWindow)
///       to accept key status and mouse events — see CoverWindow.allowsKeyForAccessibility.
///   Honest tradeoff: AccessibleField lives OUTSIDE the CGEventTap path by
///   construction, so it cannot re-derive InputFilter's physical-vs-remote
///   distinction (InputFilter.swift's own header already documents that
///   distinction as a convenience filter, not a hard security boundary). While
///   AccessibleField is attached, ANY input that can reach the key window —
///   physical keystrokes typed directly, or a Screen-Sharing operator with
///   control of the remote session — can type into it. This is a narrow,
///   deliberate widening of the trust boundary, scoped to exactly the moments
///   assistive tech is detected running, so a VoiceOver/Switch Control user can
///   complete the unlock flow at all. It is not hidden: it is gated, time-boxed
///   to the field's attachment, and documented here and at each call site.
/// SPORT: MASTER-CURTAIN
@MainActor
final class PasswordBox: NSView {
    var onSuccess: (() -> Void)?
    private let dots = NSTextField(labelWithString: "")
    private let err = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: "Enter password")
    private var buffer = ""
    private var hideAt: TimeInterval = 0

    /// The CoverWindow hosting this box. Weak: CurtainController owns the window;
    /// PasswordBox only needs to toggle its accessibility-only key/mouse exception
    /// while the accessible field is attached, never to keep it alive.
    weak var hostWindow: CoverWindow?

    /// The accessible input path (T-P1-E07-01). Created lazily on first reveal and
    /// shown/hidden per assistive-tech state; see AccessibleField's own header.
    private var accessibleField: AccessibleField?
    private var accessibilityObservers: [NSKeyValueObservation] = []

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // KVO tokens must be invalidated explicitly; they do not tear down with the
        // observed NSWorkspace.shared singleton. Capture-by-value into a local so
        // deinit (which can land off the main actor) never touches `self`.
        let tokens = accessibilityObservers
        Task { @MainActor in tokens.forEach { $0.invalidate() } }
    }

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
        let glyph = label("🔒", 144, 38, .white)
        glyph.setAccessibilityElement(false)  // decorative; the prompt label carries the announcement

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
        let hint = label("Return to unlock · Esc to dismiss", 24, 12, NSColor(white: 0.42, alpha: 1))

        // --- (a) Real accessibility metadata on the existing labels ---
        // prompt: role .staticText with a value that includes the masked-length hint
        // so VoiceOver's single announcement on focus covers "what field is this and
        // what state is it in" without requiring two separate stops.
        prompt.setAccessibilityRole(.staticText)
        prompt.setAccessibilityLabel("Curtain unlock prompt")
        // dots: exposed as a secure-text-field value — VoiceOver announces the dot
        // COUNT (via the accessibility value string built from bullet characters,
        // matching what's on screen), never the plaintext buffer, which never left
        // key() below.
        dots.setAccessibilityRole(.textField)
        dots.setAccessibilitySubrole(.secureTextField)
        dots.setAccessibilityLabel("Password")
        updateAccessibilityValue()
        err.setAccessibilityRole(.staticText)
        err.setAccessibilityLabel("Unlock status")
        hint.setAccessibilityLabel("Keyboard hints: press Return to unlock, Escape to dismiss")

        // Root view groups the above into one navigable unit and exposes a readable
        // group description as a fallback for VO-Tab landing on the container itself.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Curtain unlock")

        installAccessibilityObservers()
    }

    fileprivate func bump() { hideAt = Date().timeIntervalSince1970 + Double(Settings.passwordBoxTimeoutSeconds) }

    func tick() {
        guard !isHidden else { return }
        // While locked out, keep the box up and count the backoff down.
        if Settings.isLockedOut { showLockout(); return }
        if Date().timeIntervalSince1970 > hideAt { isHidden = true }
    }

    func key(keycode: Int, chars: String?) {
        if isHidden { reveal() }
        bump()

        if Settings.isLockedOut { showLockout(); return }

        switch keycode {
        case 36, 76:  // Return / Enter
            attemptUnlock()
        case 53:  // Esc
            // Clear the buffer and dots before hiding so a partial password attempt
            // is not left in memory or on-screen if the box is re-revealed quickly.
            zeroBuffer()
            isHidden = true
        case 51:  // Delete
            if !buffer.isEmpty { buffer.removeLast() }
            refreshMaskedDisplay(); err.isHidden = true
        default:
            if let c = chars, let ch = c.first, ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
                buffer += c
                refreshMaskedDisplay(); err.isHidden = true
            }
        }
    }

    /// Shared verify/lockout path for BOTH entry points (physical key() above and
    /// AccessibleField's Return-key handler below) so lockout/backoff behavior is
    /// byte-for-byte identical regardless of which one produced the attempt.
    private func attemptUnlock() {
        if Settings.verify(buffer) {
            Settings.resetFailedAttempts()
            // Zero the buffer and dot display before calling back so the plaintext
            // credential doesn't linger while the curtain comes down.
            zeroBuffer()
            onSuccess?()
        } else {
            Settings.registerFailedAttempt()
            zeroBuffer()
            if Settings.isLockedOut {
                showLockout()
            } else {
                err.stringValue = "Wrong password"; err.isHidden = false
                postAnnouncement(err.stringValue)
            }
        }
    }

    /// Zero the plaintext buffer and every on-screen reflection of it (dots label,
    /// AccessibleField's own field editor) in one place, so success/failure/lockout/
    /// Esc/reveal all get the same discipline regardless of entry path.
    private func zeroBuffer() {
        buffer = ""
        refreshMaskedDisplay()
        accessibleField?.zeroText()
    }

    private func refreshMaskedDisplay() {
        dots.stringValue = String(repeating: "•", count: buffer.count)
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        // Mirrors what's on screen: a dot count, never the plaintext. VoiceOver's
        // "value" announcement for a secure field is exactly this in system text
        // fields too (spoken as "N dots" / obscured), so this matches user
        // expectation instead of reading the raw bullet string aloud.
        dots.setAccessibilityValue(buffer.isEmpty ? "empty" : "\(buffer.count) characters entered")
    }

    private func reveal() {
        buffer = ""
        dots.stringValue = ""
        updateAccessibilityValue()
        err.isHidden = true
        isHidden = false
        refreshAccessibleFieldVisibility()
    }

    private func showLockout() {
        let secs = Int(ceil(Settings.backoffRemaining))
        zeroBuffer()
        err.stringValue = "Try again in \(secs)s"
        err.isHidden = false
        postAnnouncement(err.stringValue)
    }

    /// Force a VoiceOver announcement for a state change that doesn't move focus
    /// (wrong password / lockout appearing while the caret stays in the field).
    /// Standard AppKit AX API — err is already `.staticText` with a label, so
    /// posting `.announcementRequested` on it is the documented way to make
    /// VoiceOver speak a value change proactively instead of waiting for the user
    /// to re-visit the element with VO-Right/VO-Left.
    private func postAnnouncement(_ message: String) {
        NSAccessibility.post(
            element: err, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - isHidden override: drive the accessible field's lifecycle off the

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            refreshAccessibleFieldVisibility()
        }
    }

    // MARK: - (b) Accessible input path

    /// KVO on both public, documented, macOS-10.13+ NSWorkspace flags. Neither
    /// requires polling: both are marked "observable through KVO" in AppKit's own
    /// header. There is no equivalent public flag for Voice Control (see this
    /// file's header comment) — Voice Control's synthesized events ride the normal
    /// responder chain and are picked up by AccessibleField once it is visible for
    /// VoiceOver/Switch Control, same as any other non-physical input source would be.
    private func installAccessibilityObservers() {
        let ws = NSWorkspace.shared
        let voiceOver = ws.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAccessibleFieldVisibility() }
        }
        let switchControl = ws.observe(\.isSwitchControlEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAccessibleFieldVisibility() }
        }
        accessibilityObservers = [voiceOver, switchControl]
    }

    private var assistiveTechRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }

    /// Attach/detach AccessibleField and grant/revoke the host window's
    /// accessibility-only key exception together, so the window is never left key
    /// after the field is gone and the field is never shown on a non-key window.
    private func refreshAccessibleFieldVisibility() {
        let want = !isHidden && assistiveTechRunning
        if want, accessibleField == nil {
            let f = AccessibleField(owner: self)
            f.frame = NSRect(x: 90, y: 84, width: 200, height: 26)
            // Add to the same visual slot as `dots` so sighted+VoiceOver users see
            // one coherent field, not two overlapping controls.
            if let box = dots.superview { box.addSubview(f, positioned: .above, relativeTo: dots) }
            accessibleField = f
            hostWindow?.allowsKeyForAccessibility = true
            hostWindow?.ignoresMouseEvents = false
            hostWindow?.makeKeyAndOrderFront(nil)
            f.window?.makeFirstResponder(f)
            Log.event("accessible unlock field attached (assistive tech detected)")
        } else if !want, let f = accessibleField {
            f.zeroText()
            f.removeFromSuperview()
            accessibleField = nil
            hostWindow?.resignKey()
            hostWindow?.ignoresMouseEvents = true
            hostWindow?.allowsKeyForAccessibility = false
            Log.event("accessible unlock field detached")
        }
    }
}

/// Purpose: the real, responder-chain-joined NSSecureTextField that lets
/// VoiceOver/Switch Control users type a password. See PasswordBox's header for
/// the full tradeoff writeup — this type exists ONLY while assistive tech is
/// detected running, and its host window's key/mouse-event exception is granted/
/// revoked in lockstep with its attach/detach lifecycle by PasswordBox.
/// Inputs: standard NSTextField delegate callbacks (Return submits, editing
///         changed updates the masked mirror + PasswordBox's own buffer state is
///         intentionally NOT touched — this field keeps its own text and is
///         reconciled with Settings.verify at submit time, exactly like key()'s
///         Return case does for the physical path).
/// Outputs: none directly; calls back into `owner` (attemptUnlock via key(_:_:))
///          semantics by re-using PasswordBox's own zeroBuffer/attemptUnlock path
///          is avoided (would require exposing buffer as non-private); instead
///          this field independently calls Settings.verify so both paths share
///          the exact same lockout/verify functions, not just the same behavior.
/// Constraints: @MainActor. stringValue is cleared on every state transition
///              (submit success/failure, lockout, PasswordBox hide) — see
///              zeroText(). Never retains plaintext beyond the current attempt.
/// SPORT: MASTER-CURTAIN
@MainActor
private final class AccessibleField: NSSecureTextField, NSTextFieldDelegate {
    private weak var owner: PasswordBox?

    init(owner: PasswordBox) {
        self.owner = owner
        super.init(frame: .zero)
        placeholderString = "Password"
        font = .systemFont(ofSize: 18)
        alignment = .center
        isBezeled = true
        bezelStyle = .roundedBezel
        target = self
        action = #selector(submit)
        delegate = self
        setAccessibilityLabel("Password — accessible unlock field")
        setAccessibilityHelp("Type the curtain password, then press Return to unlock.")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Bump the same auto-hide timer the physical path bumps on every key() call,
    /// so the box doesn't vanish mid-dictation/mid-typing out from under a
    /// VoiceOver/Switch Control user who is naturally slower to enter each
    /// character than a sighted user typing normally.
    func controlTextDidChange(_ obligation: Notification) {
        owner?.bump()
    }

    @objc private func submit() {
        guard Settings.isLockedOut == false else {
            // Match the physical path's key(): a submit attempt while already
            // locked out re-announces the remaining backoff rather than silently
            // discarding the keystroke, so a VoiceOver user gets the same feedback
            // a sighted user reading the countdown label would.
            zeroText()
            owner?.reportLockoutForAccessibleField()
            return
        }
        let candidate = stringValue
        if Settings.verify(candidate) {
            Settings.resetFailedAttempts()
            zeroText()
            owner?.onSuccess?()
        } else {
            Settings.registerFailedAttempt()
            zeroText()
            owner?.reportAccessibleFieldOutcome()
        }
    }

    /// Wipe the field editor's text so the plaintext candidate never lingers
    /// beyond the current submit — mirrors PasswordBox.zeroBuffer()'s discipline
    /// for the physical-key path's `buffer`.
    func zeroText() {
        stringValue = ""
    }
}

extension PasswordBox {
    /// Called by AccessibleField after a failed/locked-out submit so the shared
    /// err label (and its VoiceOver announcement) reflects the outcome regardless
    /// of which entry path produced the attempt.
    fileprivate func reportAccessibleFieldOutcome() {
        if Settings.isLockedOut {
            showLockout()
        } else {
            err.stringValue = "Wrong password"
            err.isHidden = false
            postAnnouncement(err.stringValue)
        }
    }

    /// Called by AccessibleField when a submit lands while already locked out,
    /// so the countdown re-announces instead of the keystroke being silently
    /// swallowed — matches key()'s `if Settings.isLockedOut { showLockout(); return }`
    /// guard at the top of the physical path.
    fileprivate func reportLockoutForAccessibleField() {
        showLockout()
    }
}
