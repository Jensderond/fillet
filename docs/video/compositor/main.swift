// Fillet announcement compositor.
//
// Draws every frame of the announcement with CoreGraphics (titles are laid out once
// with SwiftUI's ImageRenderer) and writes raw BGRA frames to stdout for ffmpeg:
//
//   compositor PLAN.json DEVICE.mp4 ICON.png WIDTH HEIGHT            > raw frames
//   compositor PLAN.json DEVICE.mp4 ICON.png WIDTH HEIGHT --poster T OUT.png
//
// It is compiled together with the app's splash sources (Theme.swift and
// App/Sources/Splash/*), so the opening is the app's own pen-plotter drawing,
// rendered at full frame and slowed down, on the same graph paper the rest of
// the film sits on. See build.py.
//
// Motion follows the project's motion rules: strong ease-out for things entering
// (cubic-bezier(0.23, 1, 0.32, 1)), quicker exits, ease-in-out for moves, nothing
// grows from zero (scale 0.96 + opacity), short staggers between lines.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: Plan

struct Plan: Decodable {
    struct Segment: Decodable { let label: String; let out_start: Double; let out_end: Double }
    struct Counter: Decodable { let start: Double; let end: Double; let a: Int; let b: Int; let unit: String }
    struct Title: Decodable {
        let key: String
        let start: Double
        let end: Double
        let style: String?
        let eyebrow: String
        let headline: String
        let sub: [String]
        let counter: Counter?
        let callout: String?
        /// When each line comes in (default: 75 ms apart from `start`), so lines can land on beats.
        let line_starts: [Double]?
    }
    struct Callout: Decodable { let rect: [Double]; let scale: Double }
    /// Framing of the device: from this time it shows screen point (fx, fy) at output pixel
    /// (ax, ay), scaled by `scale`; `dur` 0 cuts to it, otherwise it eases there (in-out).
    struct Zoom: Decodable {
        let t: Double; let scale: Double; let fx: Double; let fy: Double; let ax: Double; let ay: Double; let dur: Double
        /// "sine" for a slow, even push (default: the strong ease-in-out of moves).
        let curve: String?
    }
    /// A big number landing under a title (the Section film's "60 fps").
    struct Stat: Decodable { let title: String; let start: Double; let text: String; let unit: String; let note: String }
    let fps: Double
    let total: Double
    let opener: Double
    let opener_draw: Double
    let device_in: Double
    let device_out: Double
    let end_card: Double
    let segments: [Segment]
    let titles: [Title]
    let callouts: [String: Callout]
    let zoom: [Zoom]?
    let stat: Stat?
    /// End card lines under the icon (default: the announcement's).
    let end_lines: [String]?
    /// How long after `end_card` the icon starts (default 0.12 s, after the device starts to leave).
    let end_card_delay: Double?
    /// Poster text: name, headline, line, platforms (default: the announcement's).
    let poster_lines: [String]?
    /// The poster's framing of the device (default: as it sits mid-film).
    let poster_zoom: Zoom?
}

// MARK: Easing

enum Ease {
    /// Strong ease-out: entrances.
    static let out = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.23, y: 1), endControlPoint: UnitPoint(x: 0.32, y: 1))
    /// Strong ease-in-out: things moving on screen.
    static let inOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.77, y: 0), endControlPoint: UnitPoint(x: 0.175, y: 1))

    static func progress(_ t: Double, _ start: Double, _ duration: Double, _ curve: UnitCurve = out) -> Double {
        curve.value(at: min(max((t - start) / duration, 0), 1))
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: Palette

enum Ink {
    static let paper = CGColor(srgbRed: 0xF5 / 255, green: 0xEF / 255, blue: 0xE0 / 255, alpha: 1)
    static let ink = Color(hex: 0x1D2B45)
    static let inkSecondary = Color(hex: 0x5A6680)
    static let filletInk = Color(hex: 0xC94F0B)
    static let fillet = Color(hex: 0xF26B1D)
    static func cg(_ hex: UInt32, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: a)
    }
}

// MARK: Images

@MainActor
func render<V: View>(_ view: V, scale: Double = 2) -> CGImage {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
    r.scale = scale
    r.isOpaque = false
    return r.cgImage!
}

func loadImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func writePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// A pre-rendered piece of text and its size in output pixels.
struct Sprite {
    let image: CGImage
    let size: CGSize
    init(_ image: CGImage, scale: Double = 2) {
        self.image = image
        size = CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
    }
}

// MARK: Device frames

/// Reads the iPad recording (already cut, constant frame rate) one frame at a time.
final class DeviceReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private(set) var index = -1
    private(set) var current: CGImage?
    let fps: Double

    init(path: String, fps: Double) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        self.fps = fps
    }

    /// The frame at device time `t` (holds the last frame past the end).
    func frame(at t: Double) -> CGImage? {
        let want = max(Int((t * fps).rounded()), 0)
        while index < want, let sample = output.copyNextSampleBuffer() {
            index += 1
            if index >= want - 1 || current == nil, let buffer = CMSampleBufferGetImageBuffer(sample) {
                current = Self.image(buffer)
            }
        }
        return current
    }

    static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let data = Data(bytes: base, count: row * h)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: Layout

struct Layout {
    let size: CGSize
    var square: Bool { abs(size.width - size.height) < 1 }
    /// iPad Pro 12.9" screen, points.
    static let screenPoints = CGSize(width: 1024, height: 1366)

    var bezel: Double { square ? 17 : 22 }
    var deviceHeight: Double { square ? 720 : 960 }
    var deviceCenter: CGPoint { square ? CGPoint(x: size.width / 2, y: 398) : CGPoint(x: 1352, y: size.height / 2) }
    var screenSize: CGSize {
        let h = deviceHeight - 2 * bezel
        return CGSize(width: h * Self.screenPoints.width / Self.screenPoints.height, height: h)
    }
    var screenRect: CGRect {
        let s = screenSize
        return CGRect(x: deviceCenter.x - s.width / 2, y: deviceCenter.y - s.height / 2, width: s.width, height: s.height)
    }
    var deviceRect: CGRect { screenRect.insetBy(dx: -bezel, dy: -bezel) }
    var screenCorner: Double { square ? 11 : 14 }

    /// Left column for titles (16:9), or the caption band (square).
    var textX: Double { square ? 70 : 150 }
    var textWidth: Double { square ? size.width - 140 : 700 }
    var bandTop: Double { 806 }

    // Type sizes.
    var eyebrowSize: Double { square ? 21 : 24 }
    var headlineSize: Double { square ? 44 : 60 }
    var subSize: Double { square ? 24 : 28 }
    var statementSize: Double { square ? 58 : 74 }
}

// MARK: Compositor

@MainActor
final class Compositor {
    let plan: Plan
    let layout: Layout
    let W: Int, H: Int
    let background: CGImage
    let icon: CGImage
    var titleSprites: [String: [Sprite]] = [:]
    var counterSprites: [Int: Sprite] = [:]
    var counterUnit: Sprite?
    var statSprites: [Sprite] = []
    var endSprites: [Sprite] = []
    var posterSprites: [Sprite] = []
    let device: DeviceReader
    var splashCache: [Int: CGImage] = [:]

    init(plan: Plan, size: CGSize, device: DeviceReader, iconPath: String) {
        self.plan = plan
        layout = Layout(size: size)
        W = Int(size.width); H = Int(size.height)
        self.device = device
        icon = loadImage(iconPath)
        background = Compositor.paper(size: size)
        prepareTitles()
    }

    // MARK: Background

    /// The splash's graph paper at rest: same centre, step, colours and line weights as
    /// `SplashRenderer.drawGrid`, so the opening dissolves into it without a seam.
    static func paper(size: CGSize) -> CGImage {
        let view = Canvas { context, size in
            let layout = SplashLayout(size: size)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper))
            let step = layout.gridStep, c = layout.drawingCenter
            let reachX = max(c.x, size.width - c.x), reachY = max(c.y, size.height - c.y)
            let minor = Theme.paperRule.opacity(0.16), major = Theme.paperRule.opacity(0.34)
            let hairline = max(0.5, step * 0.04)
            for (count, vertical) in [(Int(reachX / step) + 1, true), (Int(reachY / step) + 1, false)] {
                for k in -count...count {
                    var p = Path()
                    if vertical {
                        let x = c.x + Double(k) * step
                        p.move(to: CGPoint(x: x, y: c.y - reachY)); p.addLine(to: CGPoint(x: x, y: c.y + reachY))
                    } else {
                        let y = c.y + Double(k) * step
                        p.move(to: CGPoint(x: c.x - reachX, y: y)); p.addLine(to: CGPoint(x: c.x + reachX, y: y))
                    }
                    let isMajor = k % 4 == 0
                    context.stroke(p, with: .color(isMajor ? major : minor), lineWidth: isMajor ? hairline * 1.8 : hairline)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        return render(view, scale: 1)
    }

    /// One frame of the app's launch splash at splash time `time` (seconds), full frame.
    func splash(_ time: Double) -> CGImage {
        let key = Int((time * 1000).rounded())
        if let hit = splashCache[key] { return hit }
        let view = SplashArtwork(progress: time / SplashTimeline.duration)
            .frame(width: layout.size.width, height: layout.size.height)
        let image = render(view, scale: 1)
        splashCache[key] = image
        return image
    }

    // MARK: Text

    func text(_ s: String, size: Double, weight: Font.Weight, color: Color, condensed: Bool = false, width: Double? = nil,
              align: TextAlignment = .leading, tracking: Double = 0, lineSpacing: Double = 0) -> Sprite {
        var font = Font.system(size: size, weight: weight)
        if condensed { font = font.width(.condensed) }
        let view = Text(s)
            .font(font)
            .tracking(tracking)
            .lineSpacing(lineSpacing)
            .foregroundStyle(color)
            .multilineTextAlignment(align)
            .frame(width: width.map { CGFloat($0) }, alignment: align == .center ? .center : .leading)
            .fixedSize(horizontal: width == nil, vertical: true)
            .padding(.vertical, size * 0.12)
        return Sprite(render(view))
    }

    func prepareTitles() {
        let L = layout
        let align: TextAlignment = L.square ? .center : .leading
        for t in plan.titles {
            var lines: [Sprite] = []
            if t.style == "statement" {
                lines.append(text(t.headline, size: L.statementSize, weight: .semibold, color: Ink.ink,
                                  width: L.square ? L.size.width - 140 : 1180, align: align, tracking: -0.8, lineSpacing: L.statementSize * 0.04))
            } else if t.style == "hero" {
                // Centred: eyebrow, a big headline, a sub line.
                if !t.eyebrow.isEmpty {
                    lines.append(text(t.eyebrow, size: L.eyebrowSize * 1.25, weight: .semibold, color: Ink.filletInk, condensed: true,
                                      align: .center, tracking: 2.2))
                }
                lines.append(text(t.headline, size: L.statementSize * 1.6, weight: .semibold, color: Ink.ink, align: .center, tracking: -2.4))
                for s in t.sub {
                    lines.append(text(s, size: L.subSize * 1.25, weight: .regular, color: Ink.inkSecondary, align: .center))
                }
            } else {
                if !t.eyebrow.isEmpty {
                    lines.append(text(t.eyebrow, size: L.eyebrowSize, weight: .semibold, color: Ink.filletInk, condensed: true,
                                      width: L.textWidth, align: align, tracking: 1.4))
                }
                let headline = L.square ? t.headline.replacingOccurrences(of: "\n", with: " ") : t.headline
                lines.append(text(headline, size: L.headlineSize, weight: .semibold, color: Ink.ink, width: L.textWidth,
                                  align: align, tracking: -0.6, lineSpacing: L.headlineSize * 0.02))
                // The square band has room for one sub line.
                let subs = L.square ? (t.sub.isEmpty ? [] : [t.sub.count > 1 ? t.sub[0] : t.sub[0]]) : t.sub
                for s in subs {
                    lines.append(text(s, size: L.subSize, weight: .regular, color: Ink.inkSecondary, width: L.textWidth, align: align))
                }
            }
            titleSprites[t.key] = lines
            if let c = t.counter {
                for v in min(c.a, c.b)...max(c.a, c.b) {
                    counterSprites[v] = text("\(v)", size: L.square ? 96 : 150, weight: .semibold, color: Ink.fillet, condensed: true)
                }
                counterUnit = text(c.unit, size: L.square ? 40 : 56, weight: .medium, color: Ink.ink, condensed: true)
            }
        }
        let center: TextAlignment = .center
        let end = plan.end_lines ?? ["Fillet", "Parametric CAD for the things you print.", "iPad and Mac"]
        endSprites = [
            text(end[0], size: L.square ? 88 : 104, weight: .semibold, color: Ink.ink, align: center, tracking: -1.5),
            text(end[1], size: L.square ? 34 : 38, weight: .regular, color: Ink.inkSecondary, align: center),
            text(end[2], size: L.square ? 28 : 30, weight: .semibold, color: Ink.filletInk, condensed: true, align: center, tracking: 1.6),
        ]
        if let s = plan.stat {
            statSprites = [
                text(s.text, size: 150, weight: .semibold, color: Ink.fillet, condensed: true),
                text(s.unit, size: 56, weight: .medium, color: Ink.ink, condensed: true),
                text(s.note, size: L.subSize, weight: .regular, color: Ink.inkSecondary),
            ]
        }
        let poster = plan.poster_lines ?? ["Fillet", "Parametric CAD for\nthe things you print.", "Offline. One file per design. No account.", "iPad and Mac"]
        posterSprites = [
            text(poster[0], size: 112, weight: .semibold, color: Ink.ink, tracking: -1.6),
            text(poster[1], size: 52, weight: .semibold, color: Ink.ink, width: 700, tracking: -0.5),
            text(poster[2], size: 28, weight: .regular, color: Ink.inkSecondary, width: 700),
            text(poster[3], size: 30, weight: .semibold, color: Ink.filletInk, condensed: true, tracking: 1.6),
        ]
    }

    // MARK: Drawing helpers

    func makeContext() -> CGContext {
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        // y down, like the layout.
        ctx.translateBy(x: 0, y: Double(H))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Draws an image into a y-down rect (CG draws images y-up).
    func draw(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    func draw(_ sprite: Sprite, at origin: CGPoint, opacity: Double, _ ctx: CGContext) {
        guard opacity > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        draw(sprite.image, in: CGRect(origin: origin, size: sprite.size), ctx)
        ctx.restoreGState()
    }

    /// Scales about `anchor` for the duration of `body`.
    func scaled(_ s: Double, about anchor: CGPoint, _ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -anchor.x, y: -anchor.y)
        body()
        ctx.restoreGState()
    }

    // MARK: Frame

    func frame(at t: Double) -> CGContext {
        let ctx = makeContext()
        draw(background, in: CGRect(x: 0, y: 0, width: W, height: H), ctx)
        drawOpener(t, ctx)
        drawDevice(t, ctx)
        for title in plan.titles { drawTitle(title, t, ctx) }
        drawEndCard(t, ctx)
        return ctx
    }

    /// The splash drawing, slowed down, then dissolving into the paper as the statement comes in.
    func drawOpener(_ t: Double, _ ctx: CGContext) {
        let fadeStart = plan.opener - 0.3
        guard plan.opener > 0, t < plan.opener + 0.05 else { return }
        let splashTime = min(t / plan.opener_draw, 1) * SplashTimeline.restingTime
        let fade = Ease.progress(t, fadeStart, 0.3)
        let image = splash(splashTime)
        ctx.saveGState()
        ctx.setAlpha(1 - fade)
        // Lifts very slightly as it leaves (the splash's own exit gesture, quieter).
        scaled(1 + 0.02 * fade, about: CGPoint(x: Double(W) / 2, y: Double(H) / 2), ctx) {
            draw(image, in: CGRect(x: 0, y: 0, width: W, height: H), ctx)
        }
        ctx.restoreGState()
    }

    func drawDevice(_ t: Double, _ ctx: CGContext) {
        guard t >= plan.device_in - 0.01, t < plan.end_card + 0.4 else { return }
        let enter = Ease.progress(t, plan.device_in, 0.85)
        let exit = Ease.progress(t, plan.end_card, 0.32)
        let opacity = enter * (1 - exit)
        guard opacity > 0.001 else { return }
        let rise = (1 - enter) * (layout.square ? 70 : 90)
        let scale = (0.96 + 0.04 * enter) * (1 - 0.03 * exit)
        let L = layout
        let deviceTime = t - plan.device_in
        guard let screen = device.frame(at: deviceTime) else { return }

        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)  // fade the device as one piece
        ctx.translateBy(x: 0, y: rise)
        applyZoom(t, ctx)
        scaled(scale, about: L.deviceCenter, ctx) {
            let outer = L.deviceRect
            let outerRadius = L.screenCorner + L.bezel
            let body = CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
            // Soft shadow on the paper, then a tighter contact shadow.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 60, color: Ink.cg(0x1D2B45, 0.22))
            ctx.addPath(body); ctx.setFillColor(Ink.cg(0x1A1D23)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: Ink.cg(0x1D2B45, 0.25))
            ctx.addPath(body); ctx.setFillColor(Ink.cg(0x1A1D23)); ctx.fillPath()
            ctx.restoreGState()
            // Bezel: graphite with a faint lighter rim.
            ctx.addPath(body)
            ctx.setStrokeColor(Ink.cg(0x4A505C, 0.9)); ctx.setLineWidth(1.6); ctx.strokePath()
            let inner = outer.insetBy(dx: 2.5, dy: 2.5)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: outerRadius - 2.5, cornerHeight: outerRadius - 2.5, transform: nil))
            ctx.setStrokeColor(Ink.cg(0x000000, 0.5)); ctx.setLineWidth(1); ctx.strokePath()
            // Screen.
            let sr = L.screenRect
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: sr, cornerWidth: L.screenCorner, cornerHeight: L.screenCorner, transform: nil))
            ctx.clip()
            draw(screen, in: sr, ctx)
            ctx.restoreGState()
            drawCalloutSource(t, ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        drawCallout(t, screen: screen, ctx)
    }

    /// The framing at time t: (scale, screen point in output pixels at scale 1, where it lands).
    func zoomState(_ t: Double) -> (s: Double, p: CGPoint, a: CGPoint) {
        let sr = layout.screenRect
        let k = sr.width / Layout.screenPoints.width
        func state(_ z: Plan.Zoom) -> (Double, CGPoint, CGPoint) {
            (z.scale, CGPoint(x: sr.minX + z.fx * k, y: sr.minY + z.fy * k), CGPoint(x: z.ax, y: z.ay))
        }
        let identity = (1.0, CGPoint(x: layout.size.width / 2, y: layout.size.height / 2), CGPoint(x: layout.size.width / 2, y: layout.size.height / 2))
        guard let keys = plan.zoom, !keys.isEmpty else { return identity }
        var current = identity
        for z in keys where z.t <= t + 1e-9 {
            let target = state(z)
            let p = z.dur <= 0 ? 1 : (z.curve == "sine" ? (1 - cos(Double.pi * min(max((t - z.t) / z.dur, 0), 1))) / 2
                                                         : Ease.progress(t, z.t, z.dur, Ease.inOut))
            current = (lerp(current.0, target.0, p),
                       CGPoint(x: lerp(current.1.x, target.1.x, p), y: lerp(current.1.y, target.1.y, p)),
                       CGPoint(x: lerp(current.2.x, target.2.x, p), y: lerp(current.2.y, target.2.y, p)))
        }
        return current
    }

    func applyZoom(_ t: Double, _ ctx: CGContext) {
        let z = zoomState(t)
        ctx.translateBy(x: z.a.x, y: z.a.y)
        ctx.scaleBy(x: z.s, y: z.s)
        ctx.translateBy(x: -z.p.x, y: -z.p.y)
    }

    // MARK: Titles

    /// Entrance for line `i` of a title: opacity and a short rise, strong ease-out, staggered.
    func lineState(_ title: Plan.Title, _ i: Int, _ t: Double) -> (opacity: Double, dy: Double) {
        let begin = title.line_starts.flatMap { i < $0.count ? $0[i] : $0.last.map { $0 + 0.075 } } ?? (title.start + 0.075 * Double(i))
        let enter = Ease.progress(t, begin, 0.6)
        let exit = Ease.progress(t, title.end - 0.26, 0.26)
        return (enter * (1 - exit), (1 - enter) * 22 - exit * 8)
    }

    func drawTitle(_ title: Plan.Title, _ t: Double, _ ctx: CGContext) {
        guard t >= title.start, t <= title.end, let lines = titleSprites[title.key] else { return }
        let L = layout
        if title.style == "hero" {
            let gaps = [L.eyebrowSize * 0.9, L.headlineSize * 0.35, 0]
            var total = lines.map(\.size.height).reduce(0, +)
            for i in 0..<max(lines.count - 1, 0) { total += gaps[min(i, 2)] }
            var y = (L.size.height - total) / 2 - 20
            for (i, s) in lines.enumerated() {
                let (o, dy) = lineState(title, i, t)
                draw(s, at: CGPoint(x: (L.size.width - s.size.width) / 2, y: y + dy), opacity: o, ctx)
                y += s.size.height + gaps[min(i, 2)]
            }
            return
        }
        if title.style == "statement" {
            let s = lines[0]
            let (o, dy) = lineState(title, 0, t)
            let x = L.square ? (L.size.width - s.size.width) / 2 : L.textX
            let y = (L.size.height - s.size.height) / 2 - 10 + dy
            draw(s, at: CGPoint(x: x, y: y), opacity: o, ctx)
            return
        }
        let gap = [L.eyebrowSize * 0.55, L.headlineSize * 0.28]
        let heights = lines.map(\.size.height)
        var total = heights.reduce(0, +)
        for i in 1..<max(lines.count, 1) { total += i < 3 ? gap[min(i - 1, 1)] : 0 }
        var y: Double
        if L.square {
            y = L.bandTop + (L.size.height - L.bandTop - total) / 2 - 10
        } else if title.callout != nil {
            y = 150
        } else if title.counter != nil {
            y = 250
        } else {
            y = (L.size.height - total) / 2 - 30
        }
        for (i, s) in lines.enumerated() {
            let (o, dy) = lineState(title, i, t)
            let x = L.square ? (L.size.width - s.size.width) / 2 : L.textX
            draw(s, at: CGPoint(x: x, y: y + dy), opacity: o, ctx)
            y += s.size.height + (i < 2 ? gap[min(i, 1)] : 0)
        }
        if let c = title.counter, !L.square { drawCounter(c, title, below: y + 26, t, ctx) }
        if let s = plan.stat, s.title == title.key, !L.square { drawStat(s, title, below: y + 18, t, ctx) }
        if let c = title.counter, L.square { drawCounterSquare(c, title, t, ctx) }
    }

    /// The hero number: counts with the plate as it widens.
    func drawCounter(_ c: Plan.Counter, _ title: Plan.Title, below y: Double, _ t: Double, _ ctx: CGContext) {
        let (o, dy) = lineState(title, 3, t)
        let p = Ease.progress(t, c.start, c.end - c.start, Ease.inOut)
        let v = Int(lerp(Double(c.a), Double(c.b), p).rounded())
        guard let digits = counterSprites[v], let unit = counterUnit else { return }
        let x = layout.textX - 4
        // A gentle lift while it counts, settling on the result.
        let pop = sin(Double.pi * p) * 0.03
        let origin = CGPoint(x: x, y: y + dy)
        scaled(1 + pop, about: CGPoint(x: origin.x, y: origin.y + digits.size.height / 2), ctx) {
            draw(digits, at: origin, opacity: o, ctx)
            draw(unit, at: CGPoint(x: x + digits.size.width + 12, y: origin.y + digits.size.height - unit.size.height - 22), opacity: o, ctx)
        }
    }

    /// A big number landing on its beat under the title: rises in, a small overshoot, settles.
    func drawStat(_ s: Plan.Stat, _ title: Plan.Title, below y: Double, _ t: Double, _ ctx: CGContext) {
        guard t >= s.start, statSprites.count == 3 else { return }
        let enter = Ease.progress(t, s.start, 0.5)
        let exit = Ease.progress(t, title.end - 0.26, 0.26)
        let o = enter * (1 - exit)
        let dy = (1 - enter) * 30
        let x = layout.textX - 4
        let digits = statSprites[0], unit = statSprites[1], note = statSprites[2]
        let pop = 1 + 0.06 * sin(Double.pi * min((t - s.start) / 0.35, 1)) * (1 - min((t - s.start) / 0.35, 1) * 0.0)
        scaled(t - s.start < 0.35 ? pop : 1, about: CGPoint(x: x, y: y + digits.size.height / 2), ctx) {
            draw(digits, at: CGPoint(x: x, y: y + dy), opacity: o, ctx)
            draw(unit, at: CGPoint(x: x + digits.size.width + 12, y: y + dy + digits.size.height - unit.size.height - 22), opacity: o, ctx)
        }
        let p2 = Ease.progress(t, s.start + 0.12, 0.5) * (1 - exit)
        draw(note, at: CGPoint(x: x + 4, y: y + digits.size.height - 6 + (1 - p2) * 18), opacity: p2, ctx)
    }

    func drawCounterSquare(_ c: Plan.Counter, _ title: Plan.Title, _ t: Double, _ ctx: CGContext) {
        // In the square cut the number sits over the device's lower-left corner, on a paper chip.
        let (o, _) = lineState(title, 2, t)
        let p = Ease.progress(t, c.start, c.end - c.start, Ease.inOut)
        let v = Int(lerp(Double(c.a), Double(c.b), p).rounded())
        guard let digits = counterSprites[v], let unit = counterUnit, o > 0.001 else { return }
        let w = digits.size.width + unit.size.width + 48, h = digits.size.height + 8
        let rect = CGRect(x: 40, y: layout.deviceRect.maxY - h - 40, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(o)
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: Ink.cg(0x1D2B45, 0.2))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setFillColor(Ink.paper); ctx.fillPath()
        ctx.restoreGState()
        draw(digits, at: CGPoint(x: rect.minX + 18, y: rect.minY + 4), opacity: o, ctx)
        draw(unit, at: CGPoint(x: rect.minX + 26 + digits.size.width, y: rect.maxY - unit.size.height - 18), opacity: o, ctx)
    }

    // MARK: Callout

    func activeCallout(_ t: Double) -> (Plan.Title, Plan.Callout)? {
        for title in plan.titles where t >= title.start && t <= title.end {
            if let key = title.callout, let c = plan.callouts[key] { return (title, c) }
        }
        return nil
    }

    func calloutProgress(_ title: Plan.Title, _ t: Double) -> Double {
        Ease.progress(t, title.start + 0.3, 0.55) * (1 - Ease.progress(t, title.end - 0.26, 0.26))
    }

    /// Screen-point rect of the callout on the device, in output pixels.
    func screenRect(points r: [Double]) -> CGRect {
        let sr = layout.screenRect
        let k = sr.width / Layout.screenPoints.width
        return CGRect(x: sr.minX + r[0] * k, y: sr.minY + r[1] * k, width: r[2] * k, height: r[3] * k)
    }

    /// An orange outline on the device marks where the magnified card comes from.
    func drawCalloutSource(_ t: Double, _ ctx: CGContext) {
        guard let (title, c) = activeCallout(t) else { return }
        let p = calloutProgress(title, t)
        guard p > 0.001 else { return }
        let r = screenRect(points: c.rect).insetBy(dx: -3, dy: -3)
        ctx.saveGState()
        ctx.setAlpha(p)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.setStrokeColor(Ink.cg(0xF26B1D)); ctx.setLineWidth(2.5); ctx.strokePath()
        ctx.restoreGState()
    }

    func drawCallout(_ t: Double, screen: CGImage, _ ctx: CGContext) {
        guard let (title, c) = activeCallout(t) else { return }
        let p = calloutProgress(title, t)
        guard p > 0.001 else { return }
        // Crop from the full-resolution screen frame.
        let px = Double(screen.width) / Layout.screenPoints.width
        let crop = CGRect(x: c.rect[0] * px, y: c.rect[1] * px, width: c.rect[2] * px, height: c.rect[3] * px)
        guard let piece = screen.cropping(to: crop) else { return }
        let scale = layout.square ? c.scale * 0.8 : c.scale
        let size = CGSize(width: c.rect[2] * scale, height: c.rect[3] * scale)
        let origin = layout.square ? CGPoint(x: layout.size.width - 36 - size.width, y: 96) : CGPoint(x: layout.textX, y: 330)
        let rect = CGRect(origin: origin, size: size)
        // Grows out of the device side (right edge) a little, never from nothing.
        let anchor = layout.square ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.midY)
        ctx.saveGState()
        ctx.setAlpha(p)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        scaled(0.95 + 0.05 * p, about: anchor, ctx) {
            let path = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: Ink.cg(0x1D2B45, 0.22))
            ctx.addPath(path); ctx.setFillColor(Ink.cg(0xF6F7F9)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            draw(piece, in: rect, ctx)
            ctx.restoreGState()
            ctx.addPath(path); ctx.setStrokeColor(Ink.cg(0x1D2B45, 0.14)); ctx.setLineWidth(1.2); ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: End card

    func drawIcon(_ rect: CGRect, opacity: Double, _ ctx: CGContext) {
        let r = rect.width * 0.225
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: Ink.cg(0x1D2B45, 0.25))
        ctx.addPath(path); ctx.setFillColor(Ink.paper); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        draw(icon, in: rect, ctx)
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(Ink.cg(0x1D2B45, 0.12)); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func drawEndCard(_ t: Double, _ ctx: CGContext) {
        let start = plan.end_card + (plan.end_card_delay ?? 0.12)
        guard t >= start else { return }
        let L = layout
        let iconSize = L.square ? 210.0 : 220.0
        let spacing = [34.0, 6.0, 26.0]
        var total = iconSize
        for (i, s) in endSprites.enumerated() { total += spacing[i] + s.size.height }
        var y = (L.size.height - total) / 2 - 8
        let cx = L.size.width / 2
        // Icon first, then each line, 80 ms apart; strong ease-out, rising 18 px, from 0.96 scale.
        let p0 = Ease.progress(t, start, 0.7)
        let iconRect = CGRect(x: cx - iconSize / 2, y: y + (1 - p0) * 18, width: iconSize, height: iconSize)
        scaled(0.96 + 0.04 * p0, about: CGPoint(x: iconRect.midX, y: iconRect.midY), ctx) {
            drawIcon(iconRect, opacity: p0, ctx)
        }
        y += iconSize
        for (i, s) in endSprites.enumerated() {
            y += spacing[i]
            let p = Ease.progress(t, start + 0.1 + 0.08 * Double(i + 1), 0.7)
            draw(s, at: CGPoint(x: cx - s.size.width / 2, y: y + (1 - p) * 18), opacity: p, ctx)
            y += s.size.height
        }
    }

    // MARK: Poster

    func poster(deviceTime: Double) -> CGImage {
        let ctx = makeContext()
        draw(background, in: CGRect(x: 0, y: 0, width: W, height: H), ctx)
        // The device as it sits mid-film.
        let saved = plan
        _ = saved
        drawDevicePoster(deviceTime, ctx)
        let iconSize = 132.0
        var y = 236.0
        drawIcon(CGRect(x: layout.textX, y: y, width: iconSize, height: iconSize), opacity: 1, ctx)
        y += iconSize + 34
        let spacing = [0.0, 18.0, 22.0, 30.0]
        for (i, s) in posterSprites.enumerated() {
            y += spacing[i]
            draw(s, at: CGPoint(x: layout.textX - (i == 0 ? 4 : 0), y: y), opacity: 1, ctx)
            y += s.size.height
        }
        return ctx.makeImage()!
    }

    func drawDevicePoster(_ deviceTime: Double, _ ctx: CGContext) {
        guard let screen = device.frame(at: deviceTime) else { return }
        let L = layout
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let z = plan.poster_zoom {
            let k = L.screenRect.width / Layout.screenPoints.width
            ctx.translateBy(x: z.ax, y: z.ay)
            ctx.scaleBy(x: z.scale, y: z.scale)
            ctx.translateBy(x: -(L.screenRect.minX + z.fx * k), y: -(L.screenRect.minY + z.fy * k))
        }
        let outer = L.deviceRect
        let outerRadius = L.screenCorner + L.bezel
        let body = CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 60, color: Ink.cg(0x1D2B45, 0.22))
        ctx.addPath(body); ctx.setFillColor(Ink.cg(0x1A1D23)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(body); ctx.setStrokeColor(Ink.cg(0x4A505C, 0.9)); ctx.setLineWidth(1.6); ctx.strokePath()
        let sr = L.screenRect
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: sr, cornerWidth: L.screenCorner, cornerHeight: L.screenCorner, transform: nil))
        ctx.clip()
        draw(screen, in: sr, ctx)
        ctx.restoreGState()
    }
}

// MARK: Main

@main
enum Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 6 else {
            FileHandle.standardError.write(Data("usage: compositor PLAN DEVICE ICON W H [--poster T OUT]\n".utf8))
            exit(2)
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let size = CGSize(width: Double(args[4])!, height: Double(args[5])!)
        let device = try await DeviceReader(path: args[2], fps: plan.fps)
        try await MainActor.run {
            let comp = Compositor(plan: plan, size: size, device: device, iconPath: args[3])
            if args.count >= 9, args[6] == "--poster" {
                let image = comp.poster(deviceTime: Double(args[7])!)
                writePNG(image, args[8])
                return
            }
            if args.count >= 9, args[6] == "--still" {
                // A single frame of the film at output time T (for checks).
                let ctx = comp.frame(at: Double(args[7])!)
                writePNG(ctx.makeImage()!, args[8])
                return
            }
            let frames = Int((plan.total * plan.fps).rounded())
            let out = FileHandle.standardOutput
            for i in 0..<frames {
                autoreleasepool {
                    let ctx = comp.frame(at: Double(i) / plan.fps)
                    let bytes = Data(bytesNoCopy: ctx.data!, count: comp.W * comp.H * 4, deallocator: .none)
                    out.write(bytes)
                }
                if i % 150 == 0 { FileHandle.standardError.write(Data("frame \(i)/\(frames)\n".utf8)) }
            }
            _ = try? out.synchronize()
        }
    }
}
