import SwiftUI

/// One frame of the launch splash. A pure function of `progress` (0 = first
/// frame, 1 = the end of the exit) and the available size: no state, no
/// animation of its own. `SplashOverlay` drives it from the clock;
/// `SplashFrameExporter` renders it offscreen.
struct SplashArtwork: View {
    let progress: Double

    var body: some View {
        Canvas { context, size in
            SplashRenderer(time: progress * SplashTimeline.duration, size: size,
                           isDark: context.environment.colorScheme == .dark)
                .draw(in: &context)
        }
    }
}

/// Where things go: the drawing and wordmark centred as one block, sized
/// from the shorter side so it reads the same on an iPad in either
/// orientation and in any Mac window from 900×600 up.
struct SplashLayout {
    let size: CGSize
    let drawingWidth: Double
    let drawingCenter: CGPoint
    let wordmarkCenter: CGPoint
    let wordmarkSize: Double
    let lineWidth: Double
    let gridStep: Double

    init(size: CGSize) {
        self.size = size
        drawingWidth = min(max(min(size.width, size.height) * 0.37, 210), 400)
        let drawingHeight = drawingWidth * SplashBlock.aspect()
        wordmarkSize = (drawingWidth * 0.165).rounded()
        let gap = drawingWidth * 0.17
        let block = drawingHeight + gap + wordmarkSize
        // A touch above centre: the optical centre of a screen sits high.
        let top = (size.height - block) / 2 - size.height * 0.02
        drawingCenter = CGPoint(x: (size.width / 2).rounded(), y: (top + drawingHeight / 2).rounded())
        wordmarkCenter = CGPoint(x: size.width / 2, y: top + drawingHeight + gap + wordmarkSize / 2)
        // The icon's proportions: 17 pt ink on a 584 pt drawing, 32 pt grid on 1024.
        lineWidth = drawingWidth * 0.026
        gridStep = (drawingWidth * 0.055).rounded()
    }

    /// The drawing alone, placed by the caller (the document browser's launch
    /// scene, which owns the title). Same proportions as the splash.
    init(size: CGSize, drawingWidth: Double, drawingCenter: CGPoint) {
        self.size = size
        self.drawingWidth = drawingWidth
        self.drawingCenter = drawingCenter
        wordmarkCenter = drawingCenter
        wordmarkSize = 0
        lineWidth = drawingWidth * 0.026
        gridStep = (drawingWidth * 0.055).rounded()
    }
}

/// Draws one frame. Layer order follows `final02()` in docs/icon/flat.py:
/// paper, grid, hidden edges (cut away behind the fillet), fillet, tangent
/// edges, outline.
struct SplashRenderer {
    let time: Double
    let layout: SplashLayout
    let block: SplashBlock
    let isDark: Bool
    /// Per-section fillet radius, 0…~1.05 of the final radius.
    let radii: [Double]

    init(time: Double, size: CGSize, isDark: Bool) {
        self.init(time: time, layout: SplashLayout(size: size), isDark: isDark)
    }

    init(time: Double, layout: SplashLayout, isDark: Bool) {
        self.time = time
        self.isDark = isDark
        self.layout = layout
        block = SplashBlock(drawingWidth: layout.drawingWidth, center: layout.drawingCenter)
        radii = (0...SplashBlock.sections).map { SplashTimeline.filletRadius(section: $0, at: time) * SplashBlock.radius }
    }

    func draw(in context: inout GraphicsContext) {
        let exit = SplashTimeline.exit.value(at: time)
        context.opacity = 1 - exit
        // The sheet lifts toward the viewer as it fades.
        let lift = 1 + 0.03 * exit
        context.translateBy(x: layout.drawingCenter.x, y: layout.drawingCenter.y)
        context.scaleBy(x: lift, y: lift)
        context.translateBy(x: -layout.drawingCenter.x, y: -layout.drawingCenter.y)

        // …and softens, so the drawing and the editor never read as two
        // overlapping pictures. One layer, so the blur runs once, not per stroke.
        if exit > 0 { context.addFilter(.blur(radius: 6 * exit)) }
        context.drawLayer { sheet in
            sheet.fill(Path(CGRect(origin: .zero, size: layout.size).insetBy(dx: -40, dy: -40)), with: .color(Theme.paper))
            drawGrid(in: sheet)
            drawBlock(in: sheet)
            drawWordmark(in: sheet)
        }
    }

    /// The block alone: no paper, grid, wordmark or exit.
    func drawBlock(in context: GraphicsContext) {
        drawHiddenEdges(in: context)
        drawFillet(in: context)
        drawOutline(in: context)
    }

    // MARK: Grid

    /// Every rule draws outward from the drawing's centre lines; rules further
    /// out start a little later, so the sheet rules itself from the middle.
    func drawGrid(in context: GraphicsContext) {
        let step = layout.gridStep
        let c = layout.drawingCenter
        let size = layout.size
        let reachX = max(c.x, size.width - c.x), reachY = max(c.y, size.height - c.y)
        let farthest = max(reachX, reachY)
        let minor = Theme.paperRule.opacity(isDark ? 0.13 : 0.16)
        let major = Theme.paperRule.opacity(isDark ? 0.28 : 0.34)
        let hairline = max(0.5, step * 0.04)

        func rule(offset: Double, isMajor: Bool, vertical: Bool) {
            let delay = SplashTimeline.gridSpread * abs(offset) / farthest
            let p = SplashTimeline.grid.value(at: time - delay)
            guard p > 0 else { return }
            var path = Path()
            if vertical {
                let x = c.x + offset
                path.move(to: CGPoint(x: x, y: c.y - reachY * p))
                path.addLine(to: CGPoint(x: x, y: c.y + reachY * p))
            } else {
                let y = c.y + offset
                path.move(to: CGPoint(x: c.x - reachX * p, y: y))
                path.addLine(to: CGPoint(x: c.x + reachX * p, y: y))
            }
            context.stroke(path, with: .color(isMajor ? major : minor), lineWidth: isMajor ? hairline * 1.8 : hairline)
        }

        for (count, vertical) in [(Int(reachX / step) + 1, true), (Int(reachY / step) + 1, false)] {
            for k in -count...count {
                rule(offset: Double(k) * step, isMajor: k % 4 == 0, vertical: vertical)
            }
        }
    }

    // MARK: Block

    private var ink: Color { Theme.ink }

    private func stroke(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private var filletSurface: Path { Path(block.filletSurface(radii: radii)) }

    /// Dashed, traced outward from the hidden corner, and cut away where they
    /// pass behind the fillet (the icon's `hid` mask).
    private func drawHiddenEdges(in context: GraphicsContext) {
        let p = SplashTimeline.hidden.value(at: time)
        guard p > 0 else { return }
        let w = layout.lineWidth
        context.drawLayer { layer in
            let style = StrokeStyle(lineWidth: w * 0.42, lineCap: .round, dash: [w * 1.5, w * 1.3])
            for edge in block.hiddenEdges() {
                layer.stroke(stroke(edge).trimmedPath(from: 0, to: p), with: .color(ink.opacity(0.5)), style: style)
            }
            layer.blendMode = .destinationOut
            layer.fill(filletSurface, with: .color(.black))
            layer.stroke(filletSurface, with: .color(.black), style: StrokeStyle(lineWidth: w * 0.8, lineJoin: .round))
        }
    }

    /// The hero. Behind the pass the edge is round and orange, with thin
    /// tangent edges where the fillet meets the faces; ahead of it the edge
    /// is still a sharp crease.
    private func drawFillet(in context: GraphicsContext) {
        let w = layout.lineWidth
        context.fill(filletSurface, with: .color(Theme.fillet))

        // How far along the edge the pass front is (0…1, then past the far end).
        let pass = max((time - SplashTimeline.filletStart) / SplashTimeline.filletTravel, 0)
        if pass > 0 {
            let thin = StrokeStyle(lineWidth: w * 0.42, lineCap: .round, lineJoin: .round)
            context.stroke(stroke(block.frontTangent(radii: radii)), with: .color(ink), style: thin)
            context.stroke(stroke(block.topTangent(radii: radii)), with: .color(ink), style: thin)
        }

        // The sharp crease, traced by the pen and then consumed by the pass.
        let traced = SplashTimeline.crease.value(at: time)
        guard traced > 0 else { return }
        let h = SplashBlock.height, width = SplashBlock.width
        // Start a little behind the pass front, where the tangent edges are still
        // a hair apart, so the crease's round cap swallows the split point.
        let start = max(pass - 0.05, 0)
        guard start < traced else { return }
        var crease = Path()
        crease.move(to: block.point(SIMD3(width * start, 0, h)))
        crease.addLine(to: block.point(SIMD3(width * traced, 0, h)))
        context.stroke(crease, with: .color(ink), style: StrokeStyle(lineWidth: w, lineCap: .round))
    }

    /// Two pens trace the left face and the silhouette at once.
    private func drawOutline(in context: GraphicsContext) {
        let p = SplashTimeline.outline.value(at: time)
        guard p > 0 else { return }
        let style = StrokeStyle(lineWidth: layout.lineWidth, lineCap: .round, lineJoin: .round)
        for loop in [block.leftFaceLoop(r: radii.first ?? 0), block.silhouette(r: radii.last ?? 0)] {
            context.stroke(stroke(loop).trimmedPath(from: 0, to: p), with: .color(ink), style: style)
        }
    }

    // MARK: Wordmark

    private func drawWordmark(in context: GraphicsContext) {
        let p = SplashTimeline.wordmark.value(at: time)
        guard p > 0 else { return }
        let size = layout.wordmarkSize
        // Settles: rises 8 pt, sharpens from a 4 pt blur, and its letters close up
        // to display tracking.
        let text = Text("Fillet")
            .font(.system(size: size, weight: .semibold))
            .tracking(size * (0.06 - 0.08 * p))
            .foregroundStyle(ink)
        var c = context
        c.opacity *= p
        if p < 1 { c.addFilter(.blur(radius: 4 * (1 - p))) }
        let center = CGPoint(x: layout.wordmarkCenter.x, y: layout.wordmarkCenter.y + 8 * (1 - p))
        c.draw(c.resolve(text), at: center, anchor: .center)
    }
}
