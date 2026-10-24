import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Sketch tools")
struct SketchToolEngineTests {
    let ctx = SnapContext(points: [], tolerance: 0.5, gridSize: 1)

    func tap(_ e: inout SketchToolEngine, _ x: Double, _ y: Double, _ c: SnapContext? = nil) -> [SketchShape] {
        let p = SIMD2(x, y)
        e.press(p, context: c ?? ctx)
        return e.release(p, context: c ?? ctx)
    }

    @Test func rectangleByTwoTapsSnapsToGrid() throws {
        var e = SketchToolEngine(tool: .rectangle)
        #expect(tap(&e, 10.2, 5.1).isEmpty)
        let shapes = tap(&e, 0.1, 25.4)
        let s = try #require(shapes.first)
        guard case .rectangle(.corner, let pos, let w, let h, _) = s.kind else { Issue.record("not a rectangle"); return }
        #expect(pos == Point2Expr(0, 5))
        #expect(w == 10)
        #expect(h == 20)
        #expect(e.isIdle)
    }

    @Test func rectangleByDrag() throws {
        var e = SketchToolEngine(tool: .rectangle)
        e.press(SIMD2(0, 0), context: ctx)
        e.drag(SIMD2(5, 5), context: ctx)
        let shapes = e.release(SIMD2(30, 12), context: ctx)
        #expect(shapes.count == 1)
    }

    @Test func lineChainClosesOnFirstPoint() throws {
        var e = SketchToolEngine(tool: .line)
        #expect(tap(&e, 0, 0).isEmpty)
        #expect(tap(&e, 10, 0).count == 1)
        #expect(tap(&e, 10, 10).count == 1)
        let closing = tap(&e, 0.3, 0.2)  // near the start → closes
        guard case .line(_, let b) = try #require(closing.first).kind else { Issue.record(); return }
        #expect(b == Point2Expr(0, 0))
        #expect(e.isIdle)
        // The three lines form one closed triangle region.
        let segs = try ([SketchShape]() + [closing[0]]).flatMap { try $0.segments(using: .empty) }
        #expect(segs.count == 1)
    }

    @Test func horizontalInference() {
        var e = SketchToolEngine(tool: .line)
        let off = SnapContext(points: [], tolerance: 0.5, gridSize: 0)
        _ = tap(&e, 0, 0, off)
        e.hover(SIMD2(17.33, 0.3), context: off)
        #expect(e.snap == .horizontal)
        #expect(e.cursor?.y == 0)
    }

    @Test func snapsToExistingEndpoint() {
        let id = UUID()
        let c = SnapContext(points: [SnapPoint(position: SIMD2(3.3, 4.4), kind: .endpoint, shape: id)], tolerance: 0.5, gridSize: 1)
        var e = SketchToolEngine(tool: .circle)
        e.hover(SIMD2(3.5, 4.2), context: c)
        #expect(e.cursor == SIMD2(3.3, 4.4))
        #expect(e.snap == .point(.endpoint))
    }

    @Test func circleArcSlotPolygonSpline() throws {
        var e = SketchToolEngine(tool: .circle)
        _ = tap(&e, 0, 0)
        guard case .circle(_, let d) = try #require(tap(&e, 3, 4).first).kind else { Issue.record(); return }
        #expect(d == 10)

        e.setTool(.arc)
        _ = tap(&e, 0, 0); _ = tap(&e, 10, 0)
        e.hover(SIMD2(5, 4), context: ctx)
        #expect(e.preview().first?.isEmpty == false)
        #expect(tap(&e, 5, 5).count == 1)

        e.setTool(.slot)
        _ = tap(&e, 0, 0); _ = tap(&e, 20, 0)
        guard case .slot(_, _, let w) = try #require(tap(&e, 10, 3).first).kind else { Issue.record(); return }
        #expect(w == 6)

        e.setTool(.polygon)
        e.polygonSides = 6
        _ = tap(&e, 0, 0)
        #expect(tap(&e, 10, 0).count == 1)

        e.setTool(.spline)
        _ = tap(&e, 0, 0); _ = tap(&e, 5, 5); _ = tap(&e, 10, 0)
        #expect(e.finish().count == 1)
    }

    @Test func constructionFlag() throws {
        var e = SketchToolEngine(tool: .line)
        e.construction = true
        _ = tap(&e, 0, 0)
        #expect(try #require(tap(&e, 0, 10).first).construction)
    }

    @Test func centerRectangleSnapsSizeToGrid() throws {
        var e = SketchToolEngine(tool: .centerRectangle)
        _ = tap(&e, 10, 10)
        // Corner at (17.6, 14.1): raw size 15.2 × 8.2 → 15 × 8 (odd widths possible).
        e.hover(SIMD2(17.6, 14.1), context: SnapContext(points: [], tolerance: 0.1, gridSize: 1))
        #expect(e.previewDimensions().map(\.label) == ["15 mm", "8 mm"])
        let s = try #require(tap(&e, 17.6, 14.1, SnapContext(points: [], tolerance: 0.1, gridSize: 1)).first)
        guard case .rectangle(.center, let p, let w, let h, _) = s.kind else { Issue.record(); return }
        #expect(p == Point2Expr(10, 10))
        #expect(w == 15)
        #expect(h == 8)
    }

    @Test func cornerRectangleCornersOnGrid() throws {
        var e = SketchToolEngine(tool: .rectangle)
        _ = tap(&e, 2.4, 3.6)
        let s = try #require(tap(&e, 41.7, 28.2).first)
        guard case .rectangle(.corner, let p, let w, let h, _) = s.kind else { Issue.record(); return }
        #expect(p == Point2Expr(2, 4))
        #expect(w == 40)
        #expect(h == 24)
    }

    @Test func circleDiameterSnapsEvenWhenDraggedDiagonally() throws {
        var e = SketchToolEngine(tool: .circle)
        _ = tap(&e, 0, 0)
        // (5, 5) is 7.07 from the centre → Ø 14.14 → snapped to Ø 14.
        guard case .circle(_, let d) = try #require(tap(&e, 5, 5).first).kind else { Issue.record(); return }
        #expect(d == 14)
    }

    @Test func gridOffKeepsExactSizes() throws {
        let off = SnapContext(points: [], tolerance: 0.1, gridSize: 0)
        var e = SketchToolEngine(tool: .circle)
        _ = tap(&e, 0, 0, off)
        guard case .circle(_, let d) = try #require(tap(&e, 5, 5, off).first).kind else { Issue.record(); return }
        #expect(abs((try Evaluator.empty.length(d)) - 14.1421) < 0.001)
    }
}
