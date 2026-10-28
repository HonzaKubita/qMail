// Draws the release DMG's window background: Tools/dmg/background.png (640×400) and background@2x.png.
//   swift Tools/dmg/make-background.swift
// The icon positions here must match icon_locations in Tools/dmg/settings.py.
import AppKit

let size = CGSize(width: 640, height: 400)
let appIcon = CGPoint(x: 170, y: 196)
let applicationsIcon = CGPoint(x: 470, y: 196)

/// The app icon's blue-to-indigo gradient.
let blue = NSColor(srgbRed: 0.31, green: 0.47, blue: 0.98, alpha: 1)
let indigo = NSColor(srgbRed: 0.42, green: 0.33, blue: 0.95, alpha: 1)

func draw() {
    // Top-left origin, like the Finder window's icon coordinates.
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)

    // A light background, so Finder's dark icon labels stay readable in light and dark mode.
    NSGradient(colors: [
        NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.94, blue: 1.0, alpha: 1),
    ])!.draw(in: CGRect(origin: .zero, size: size), angle: -90)

    // Two faint chat bubbles, like the icon's, in opposite corners.
    bubble(CGRect(x: -90, y: 272, width: 230, height: 100), tailRight: true, alpha: 0.10)
    bubble(CGRect(x: 488, y: -36, width: 220, height: 120), tailRight: false, alpha: 0.08)

    text("qMail", size: 40, weight: .bold, color: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), centerY: 56)
    text("Email that reads like a chat", size: 15, weight: .medium, color: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.47, alpha: 1), centerY: 94)

    arrow(from: CGPoint(x: appIcon.x + 84, y: appIcon.y), to: CGPoint(x: applicationsIcon.x - 84, y: applicationsIcon.y))

    text("Drag qMail into Applications", size: 14, weight: .semibold, color: NSColor(srgbRed: 0.33, green: 0.33, blue: 0.38, alpha: 1), centerY: 340)
}

func bubble(_ rect: CGRect, tailRight: Bool, alpha: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.42, yRadius: rect.height * 0.42)
    // The tail hangs from the bottom corner (y grows downwards here).
    let x = tailRight ? rect.maxX - rect.width * 0.2 : rect.minX + rect.width * 0.2
    let direction: CGFloat = tailRight ? 1 : -1
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: x - 22 * direction, y: rect.maxY - 12))
    tail.curve(to: CGPoint(x: x + 18 * direction, y: rect.maxY + 30),
               controlPoint1: CGPoint(x: x - 4 * direction, y: rect.maxY + 14),
               controlPoint2: CGPoint(x: x + 6 * direction, y: rect.maxY + 26))
    tail.curve(to: CGPoint(x: x + 22 * direction, y: rect.maxY - 12),
               controlPoint1: CGPoint(x: x + 22 * direction, y: rect.maxY + 16),
               controlPoint2: CGPoint(x: x + 26 * direction, y: rect.maxY + 2))
    tail.close()
    // Fill both opaque in one layer, then fade the layer, so where they overlap isn't lighter or darker.
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.setAlpha(alpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    let gradient = NSGradient(colors: [blue, indigo])!
    gradient.draw(in: path, angle: -60)
    gradient.draw(in: tail, angle: -60)
    context.endTransparencyLayer()
    context.restoreGState()
}

func arrow(from start: CGPoint, to end: CGPoint) {
    let head: CGFloat = 22
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: CGPoint(x: end.x - head * 0.6, y: end.y))
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round

    let tip = NSBezierPath()
    tip.move(to: CGPoint(x: end.x - head, y: end.y - head * 0.8))
    tip.line(to: end)
    tip.line(to: CGPoint(x: end.x - head, y: end.y + head * 0.8))
    tip.lineWidth = 7
    tip.lineCapStyle = .round
    tip.lineJoinStyle = .round

    // Stroke both as one shape filled with the gradient.
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.addPath(shaft.cgPath.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.addPath(tip.cgPath.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.clip()
    NSGradient(colors: [blue, indigo])!.draw(in: CGRect(x: start.x, y: end.y - head, width: end.x - start.x, height: head * 2).insetBy(dx: -8, dy: -8), angle: 0)
    context.restoreGState()
}

func text(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
    let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let bounds = attributed.size()
    // Text draws upright only in an unflipped context, so flip back around its own box.
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: 0, y: centerY + bounds.height / 2)
    context.scaleBy(x: 1, y: -1)
    attributed.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 0))
    context.restoreGState()
}

func render(scale: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size  // 72 dpi at 1×, 144 dpi at 2×
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
render(scale: 1, to: folder + "/background.png")
render(scale: 2, to: folder + "/background@2x.png")
print("Wrote \(folder)/background.png and background@2x.png")
