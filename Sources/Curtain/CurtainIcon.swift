import Cocoa

/// Purpose: Draw the Curtain logo (classic theater curtains) at any size, for both
///          the menu-bar item (monochrome template) and the app icon (full color).
///          Self-contained CoreGraphics so there are no image assets to ship.
/// SPORT: MASTER-ICON
enum CurtainIcon {

    /// A monochrome, template menu-bar image (adapts to light/dark menu bars).
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, monochrome: true); return true
        }
        img.isTemplate = true
        return img
    }

    /// A full-color app icon at the given pixel size.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, monochrome: false); return true
        }
    }

    /// Export a full .iconset folder of PNGs (for `iconutil` to turn into .icns).
    static func exportIconset(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let specs: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (name, px) in specs {
            guard let png = pngData(size: px) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    /// Render the icon to PNG via an offscreen bitmap context (no running app / window server).
    static func pngData(size: CGFloat) -> Data? {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw(in: NSRect(x: 0, y: 0, width: size, height: size), monochrome: false)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Drawing

    private static func draw(in rect: NSRect, monochrome: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = rect.width, h = rect.height

        if !monochrome {
            // Rounded dark "stage" background.
            let bg = NSBezierPath(roundedRect: rect, xRadius: w * 0.22, yRadius: w * 0.22)
            NSColor(red: 0.10, green: 0.07, blue: 0.09, alpha: 1).setFill(); bg.fill()
        }

        let panelTop = h * 0.86
        let panelBottom = h * 0.10
        let rod = h * 0.90
        let panelColor = monochrome ? NSColor.black : NSColor(red: 0.74, green: 0.12, blue: 0.16, alpha: 1)
        let foldColor  = monochrome ? NSColor.black.withAlphaComponent(0.55)
                                    : NSColor(red: 0.55, green: 0.07, blue: 0.10, alpha: 1)

        // Two curtain panels, slightly parted in the middle.
        drawPanel(ctx, x0: w * 0.10, x1: w * 0.46, top: panelTop, bottom: panelBottom,
                  folds: 3, color: panelColor, fold: foldColor, mirrored: false)
        drawPanel(ctx, x0: w * 0.54, x1: w * 0.90, top: panelTop, bottom: panelBottom,
                  folds: 3, color: panelColor, fold: foldColor, mirrored: true)

        // Curtain rod / valance across the top.
        let rodColor = monochrome ? NSColor.black : NSColor(red: 0.85, green: 0.68, blue: 0.30, alpha: 1)
        rodColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: w * 0.07, y: rod, width: w * 0.86, height: h * 0.055),
                     xRadius: h * 0.03, yRadius: h * 0.03).fill()
    }

    private static func drawPanel(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, top: CGFloat, bottom: CGFloat,
                                  folds: Int, color: NSColor, fold: NSColor, mirrored: Bool) {
        let width = x1 - x0
        // Panel body with a gently scalloped bottom hem.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: top))
        path.line(to: NSPoint(x: x0, y: bottom + (top - bottom) * 0.06))
        let segs = folds
        for i in 0..<segs {
            let sx = x0 + width * CGFloat(i) / CGFloat(segs)
            let ex = x0 + width * CGFloat(i + 1) / CGFloat(segs)
            let mid = (sx + ex) / 2
            path.curve(to: NSPoint(x: ex, y: bottom + (top - bottom) * 0.06),
                       controlPoint1: NSPoint(x: mid, y: bottom - (top - bottom) * 0.04),
                       controlPoint2: NSPoint(x: mid, y: bottom - (top - bottom) * 0.04))
        }
        path.line(to: NSPoint(x: x1, y: top))
        path.close()
        color.setFill(); path.fill()

        // Vertical fold shading lines.
        fold.setStroke()
        for i in 1..<folds {
            let fx = x0 + width * CGFloat(i) / CGFloat(folds)
            let line = NSBezierPath()
            line.lineWidth = max(1, width * 0.03)
            line.move(to: NSPoint(x: fx, y: top))
            line.line(to: NSPoint(x: fx, y: bottom + (top - bottom) * 0.07))
            line.stroke()
        }
        _ = mirrored
    }
}
