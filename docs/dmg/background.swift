// Draws the DMG window background: the app icon's engineering paper as a drawing sheet, the
// fillet-orange arrow from Fillet to Applications, and a title block. Writes background.png
// (1x) and background@2x.png to the directory given; build.sh packs them into background.tiff.
//
//     swift background.swift <out-dir>
//
// The layout is in points and must match scripts/dmg-settings.py: a 640×400 window, 112 pt
// icons centred at (192, 192) and (448, 192), both on major grid lines.
import AppKit

let size = CGSize(width: 640, height: 400)
let appCenter = CGPoint(x: 192, y: 192)
let applicationsCenter = CGPoint(x: 448, y: 192)
let iconSize: CGFloat = 112

// Theme.paper / Theme.paperRule / Theme.ink / Theme.inkSecondary / Theme.fillet, light.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let paper = rgb(0xF5EFE0)
let rule = 0x4F8FB0 as UInt32
let ink = rgb(0x1D2B45)
let inkSecondary = rgb(0x5A6680)
let fillet = rgb(0xF26B1D)

func font(_ size: CGFloat, _ weight: NSFont.Weight, condensed: Bool = false) -> NSFont {
    condensed ? .systemFont(ofSize: size, weight: weight, width: .condensed) : .systemFont(ofSize: size, weight: weight)
}

/// Draws `text` with its left edge (or centre) at `x` and its baseline at `y`.
func text(_ string: String, _ font: NSFont, _ color: CGColor, x: CGFloat, baseline y: CGFloat,
          tracking: CGFloat = 0, centered: Bool = false) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking,
    ])
    let width = attributed.size().width - (string.isEmpty ? 0 : tracking)
    attributed.draw(at: CGPoint(x: centered ? x - width / 2 : x, y: y - font.ascender))
}

func draw(_ cg: CGContext) {
    // Paper.
    cg.setFillColor(paper)
    cg.fill(CGRect(origin: .zero, size: size))

    // Graph paper: 16 pt ruling, every fourth line heavier (the icon's 32/128 on 1024).
    let step: CGFloat = 16
    for i in 0...Int(max(size.width, size.height) / step) {
        let p = CGFloat(i) * step
        let major = i % 4 == 0
        cg.setStrokeColor(rgb(rule, major ? 0.30 : 0.14))
        cg.setLineWidth(major ? 1 : 0.5)
        cg.strokeLineSegments(between: [CGPoint(x: p, y: 0), CGPoint(x: p, y: size.height),
                                        CGPoint(x: 0, y: p), CGPoint(x: size.width, y: p)])
    }

    // The sheet's border with centring marks, as on a printed drawing.
    let frame = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
    cg.setStrokeColor(ink.copy(alpha: 0.55)!)
    cg.setLineWidth(1)
    cg.stroke(frame)
    cg.setLineWidth(1.5)
    cg.strokeLineSegments(between: [
        CGPoint(x: frame.midX, y: frame.minY - 6), CGPoint(x: frame.midX, y: frame.minY + 8),
        CGPoint(x: frame.midX, y: frame.maxY - 8), CGPoint(x: frame.midX, y: frame.maxY + 6),
        CGPoint(x: frame.minX - 6, y: frame.midY), CGPoint(x: frame.minX + 8, y: frame.midY),
        CGPoint(x: frame.maxX - 8, y: frame.midY), CGPoint(x: frame.maxX + 6, y: frame.midY),
    ])

    // The arrow: fillet orange between the icons, with a dimension-style label over it.
    let gap: CGFloat = iconSize / 2 + 18
    let start = CGPoint(x: appCenter.x + gap, y: appCenter.y)
    let end = CGPoint(x: applicationsCenter.x - gap, y: applicationsCenter.y)
    cg.setStrokeColor(fillet)
    cg.setLineWidth(3)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokeLineSegments(between: [start, CGPoint(x: end.x - 1, y: end.y)])
    cg.move(to: CGPoint(x: end.x - 9, y: end.y - 9))
    cg.addLine(to: end)
    cg.addLine(to: CGPoint(x: end.x - 9, y: end.y + 9))
    cg.strokePath()
    text("DRAG TO INSTALL", font(10, .semibold, condensed: true), inkSecondary,
         x: (start.x + end.x) / 2, baseline: appCenter.y - 14, tracking: 1.4, centered: true)

    // Title block, bottom right against the border.
    let block = CGRect(x: frame.maxX - 224, y: frame.maxY - 64, width: 224, height: 64)
    cg.setFillColor(paper)
    cg.fill(block)
    cg.setStrokeColor(ink.copy(alpha: 0.55)!)
    cg.setLineWidth(1)
    cg.stroke(block)
    let split = block.minY + 38
    cg.strokeLineSegments(between: [
        CGPoint(x: block.minX, y: split), CGPoint(x: block.maxX, y: split),
        CGPoint(x: block.minX + 80, y: split), CGPoint(x: block.minX + 80, y: block.maxY),
        CGPoint(x: block.minX + 152, y: split), CGPoint(x: block.minX + 152, y: block.maxY),
    ])
    text("Fillet", font(15, .semibold), ink, x: block.minX + 10, baseline: block.minY + 18)
    text("Parametric CAD for 3D printing", font(10, .regular), inkSecondary,
         x: block.minX + 10, baseline: block.minY + 31)
    for (i, (label, value)) in [("UNITS", "mm"), ("SCALE", "1:1"), ("SHEET", "1 / 1")].enumerated() {
        let x = block.minX + [10, 90, 162][i]
        text(label, font(7, .semibold, condensed: true), inkSecondary, x: x, baseline: split + 10, tracking: 0.8)
        text(value, font(10, .medium, condensed: true), ink, x: x, baseline: split + 21)
    }
}

func render(scale: CGFloat, to url: URL) throws {
    let cg = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip so y runs down, like the Finder's icon positions.
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.current = nil
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    rep.size = size
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
