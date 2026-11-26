// Draws the Bassment icons into Resources/: AppIcon.icns (via iconutil) and the menu bar template.
// Run: swift scripts/icon.swift   (from the repo root)
import AppKit
import CoreText

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let orange = c(0xFF8A00), red = c(0xFF2E4D)

func bitmap(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The letter B as a path, centered at (cx, cy) with the given cap height.
func letterB(height: CGFloat, cx: CGFloat, cy: CGFloat) -> NSBezierPath {
    let font = NSFont.systemFont(ofSize: 100, weight: .black) as CTFont
    var ch: UniChar = 66, glyph = CGGlyph(0)
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
    let path = CTFontCreatePathForGlyph(font, glyph, nil)!
    let box = path.boundingBoxOfPath, k = height / box.height
    var t = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: k, y: k).translatedBy(x: -box.midX, y: -box.midY)
    return NSBezierPath(cgPath: path.copy(using: &t)!)
}

func wave(_ s: CGFloat) -> NSBezierPath {
    let w = NSBezierPath(); w.lineWidth = 18 * s / 1024; w.lineCapStyle = .round
    let x0 = 140 * s / 1024, x1 = 884 * s / 1024
    for x in stride(from: x0, through: x1, by: max(1, s / 256)) {
        let y = (215 + 38 * sin((x - x0) / (x1 - x0) * 2 * .pi * 1.5)) * s / 1024
        x == x0 ? w.move(to: NSPoint(x: x, y: y)) : w.line(to: NSPoint(x: x, y: y))
    }
    return w
}

func appIcon(_ s: CGFloat) {
    let k = s / 1024
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k), xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.45); sh.shadowBlurRadius = 28 * k; sh.shadowOffset = NSSize(width: 0, height: -12 * k)
    sh.set(); c(0x0D0A14).setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: c(0x2A1840), ending: c(0x0D0A14))!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let b = letterB(height: 504 * k, cx: 512 * k, cy: 565 * k)
    NSGraphicsContext.saveGraphicsState()
    let g = NSShadow(); g.shadowColor = orange.withAlphaComponent(0.8); g.shadowBlurRadius = 60 * k; g.shadowOffset = .zero; g.set()
    red.setFill(); b.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [c(0xFFB347), orange, red])!.draw(in: b, angle: -90)
    NSColor.white.withAlphaComponent(0.85).setStroke(); wave(s).stroke()
    NSGraphicsContext.restoreGraphicsState()
}

/// Menu bar: black B on transparent, used as a template image (macOS tints it).
func menuIcon(_ s: CGFloat) {
    NSColor.black.setFill()
    letterB(height: s * 0.78, cx: s / 2, cy: s / 2).fill()
}

func png(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    png(bitmap(base, appIcon), "\(iconset)/icon_\(base)x\(base).png")
    png(bitmap(base * 2, appIcon), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
png(bitmap(1024, appIcon), "Resources/AppIcon.png")
png(bitmap(18, menuIcon), "Resources/MenuBarIcon.png")
png(bitmap(36, menuIcon), "Resources/MenuBarIcon@2x.png")
print(p.terminationStatus == 0 ? "ok" : "iconutil failed")
