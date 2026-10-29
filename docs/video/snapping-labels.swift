// The card behind the snapping demo's two takes: 1920×1080 paper with "Before" and "After" over
// where record-snapping-demo.sh places them (720 pt wide at x = 200 and x = 1000). Drawn with
// AppKit because Homebrew's ffmpeg has no drawtext.
//
//   swift docs/video/snapping-labels.swift labels.png
import AppKit

let size = NSSize(width: 1920, height: 1080)
let paper = NSColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1)
let ink = NSColor(srgbRed: 0.122, green: 0.165, blue: 0.267, alpha: 1)

let image = NSImage(size: size, flipped: true) { _ in
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()
    func label(_ text: String, _ detail: String, centerX: CGFloat) {
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: ink,
        ])
        let sub = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.6),
        ])
        title.draw(at: NSPoint(x: centerX - title.size().width / 2, y: 14))
        sub.draw(at: NSPoint(x: centerX - sub.size().width / 2, y: 64))
    }
    label("Before", "Snaps to the sketch's own shapes and the grid", centerX: 560)
    label("After", "Also snaps to the part's edges and hole centres", centerX: 1360)
    return true
}
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
