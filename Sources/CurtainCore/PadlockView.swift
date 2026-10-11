import Cocoa

/// Purpose: The artificial lock screen shown on a monitor while the padlock screen is up: black,
///          a large padlock, and a short caption. It carries no controls; the password box lives on
///          one monitor only.
/// Inputs: frame.
/// Outputs: a view that draws itself.
/// Constraints: @MainActor (AppKit). Pure drawing, no state.
/// SPORT: MASTER-CURTAIN
@MainActor
final class PadlockView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]

        let icon = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 140, weight: .regular)
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(config)
        icon.contentTintColor = NSColor(white: 0.85, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: "This Mac is in use remotely")
        caption.font = .systemFont(ofSize: 22, weight: .medium)
        caption.textColor = NSColor(white: 0.5, alpha: 1)
        caption.alignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(caption)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("Locked. This Mac is in use remotely.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
