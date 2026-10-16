import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Renders at an exact pixel size in an explicitly-sized bitmap context —
/// NSImage.lockFocus draws at the display's backing scale, so Retina
/// regeneration produced double-resolution PNGs iconutil rejects.
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    let inset = side * 0.05
    let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.35, alpha: 1),
        ending: NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.75, alpha: 1))!
    gradient.draw(in: path, angle: -60)
    let glyph = "◆" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: side * 0.52, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1),
    ]
    let glyphSize = glyph.size(withAttributes: attrs)
    glyph.draw(
        at: NSPoint(x: (side - glyphSize.width) / 2, y: (side - glyphSize.height) / 2),
        withAttributes: attrs)
    return rep.representation(using: .png, properties: [:])!
}

// iconutil accepts exactly these ten names; anything else is ignored.
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("rendered 10 sizes to \(outDir.path)")
