// Crops the guide's screenshots and draws the orange rings that mark the control a step names.
//
//   swift site/shots/files-and-icloud/crops.swift            (from the repo root)
//
// Reads crops.json next to this file. Each entry:
//   { "src": "<capture in build/docs-shots/files-and-icloud>", "out": "<file in src/assets/screens/files-and-icloud>",
//     "rect": [x, y, w, h], "rings": [[x, y, w, h], …] }
// Rects are in points of the 1366×1024 landscape screen (the capture is 2732×2048, 2 px per pt).
// The crop keeps the capture's full resolution, so the PNG is 2× its rect.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Crop: Decodable {
    let src: String
    let out: String
    let rect: [Double]
    let rings: [[Double]]?
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let shots = repo.appendingPathComponent("build/docs-shots/files-and-icloud")
let public_ = repo.appendingPathComponent("site/src/assets/screens/files-and-icloud")
let crops = try JSONDecoder().decode([Crop].self, from: Data(contentsOf: here.appendingPathComponent("crops.json")))

let scale = 2.0
let accent = CGColor(srgbRed: 0xF2 / 255, green: 0x64 / 255, blue: 0x19 / 255, alpha: 1)

for crop in crops {
    guard let source = CGImageSourceCreateWithURL(shots.appendingPathComponent(crop.src) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Can't read \(crop.src)")
    }
    let r = crop.rect.map { $0 * scale }
    let width = Int(r[2]), height = Int(r[3])
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
    // CoreGraphics is y-up: put the crop's top-left at the context's top-left.
    ctx.draw(image, in: CGRect(x: -r[0], y: Double(height) + r[1] - Double(image.height), width: Double(image.width), height: Double(image.height)))
    ctx.setLineJoin(.round)
    for ring in crop.rings ?? [] {
        let x = (ring[0] - crop.rect[0]) * scale, y = (ring[1] - crop.rect[1]) * scale
        let w = ring[2] * scale, h = ring[3] * scale
        let box = CGRect(x: x, y: Double(height) - y - h, width: w, height: h)
        let radius = min(ring.count > 4 ? ring[4] * scale : 12 * scale, min(w, h) / 2)
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // A soft halo, then the ring itself.
        ctx.addPath(path)
        ctx.setStrokeColor(accent.copy(alpha: 0.22)!)
        ctx.setLineWidth(12)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(5)
        ctx.strokePath()
    }
    let out = public_.appendingPathComponent(crop.out)
    guard let result = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError() }
    CGImageDestinationAddImage(dest, result, nil)
    CGImageDestinationFinalize(dest)
    print("\(out.path) \(width)x\(height)")
}
