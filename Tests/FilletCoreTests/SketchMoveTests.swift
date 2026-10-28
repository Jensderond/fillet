import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Moving sketch shapes")
struct SketchMoveTests {
    let ev = Evaluator.empty

    @Test func translatesEveryPositionButNotSizesOrAngles() {
        let shapes: [SketchShapeKind] = [
            .line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)),
            .polyline(vertices: [PolylineVertex(0, 0), PolylineVertex(5, 5, bulge: 1)], closed: true),
            .rectangle(anchor: .corner, position: Point2Expr(1, 2), width: 10, height: 20, angle: 30),
            .circle(center: Point2Expr(3, 4), diameter: 8),
            .arc(start: Point2Expr(0, 0), through: Point2Expr(1, 1), end: Point2Expr(2, 0)),
            .polygon(center: Point2Expr(0, 0), sides: 6, radius: 5, inscribed: true, angle: 15),
            .slot(a: Point2Expr(0, 0), b: Point2Expr(10, 0), width: 4),
            .spline(points: [Point2Expr(0, 0), Point2Expr(1, 2), Point2Expr(3, 1)]),
            .point(Point2Expr(7, 7)),
        ]
        let offset = SIMD2(2.5, -1.0)
        for kind in shapes {
            let shape = SketchShape(kind)
            let moved = shape.translated(by: offset, using: ev)
            #expect(moved.id == shape.id)
            #expect(moved.kind.typeName == kind.typeName)
            // Every snap point moved by exactly the offset (sizes and angles kept the shape).
            let before = shape.snapPoints(using: ev).map(\.position)
            let after = moved.snapPoints(using: ev).map(\.position)
            #expect(before.count == after.count, "\(kind.typeName)")
            for (a, b) in zip(before, after) {
                #expect((b - a - offset).x.magnitude < 1e-9 && (b - a - offset).y.magnitude < 1e-9, "\(kind.typeName)")
            }
        }
        // Sizes, angles and bulges are untouched.
        let rect = SketchShape(.rectangle(anchor: .center, position: Point2Expr(0, 0), width: "w", height: 5, angle: 30))
        #expect(rect.translated(by: SIMD2(1, 1), using: ev).kind
            == .rectangle(anchor: .center, position: Point2Expr(1, 1), width: "w", height: 5, angle: 30))
        let poly = SketchShape(.polyline(vertices: [PolylineVertex(0, 0, bulge: 2)], closed: false))
        #expect(poly.translated(by: SIMD2(1, 0), using: ev).kind == .polyline(vertices: [PolylineVertex(1, 0, bulge: 2)], closed: false))
    }

    @Test func plainNumbersStayPlainAndRound() {
        #expect(Expr(10).offset(by: 2.5, using: ev) == Expr(12.5))
        #expect(Expr("10 mm").offset(by: -10, using: ev) == Expr(0))
        #expect(Expr(0.1).offset(by: 0.2, using: ev) == Expr(0.3))  // not 0.30000000000000004
        #expect(Expr("w/2").offset(by: 0, using: ev) == Expr("w/2"))  // no offset, no change
    }

    @Test func parametricCoordinatesKeepTheirParameters() throws {
        let ev = Evaluator(values: ["w": Quantity(40, .length)])
        let once = Expr("w/2").offset(by: 5, using: ev)
        #expect(once == Expr("w/2 + 5"))
        let twice = once.offset(by: -8, using: ev)
        #expect(twice == Expr("w/2 - 3"))  // folded, not "w/2 + 5 - 8"
        #expect(try ev.length(twice) == 17)
        #expect(twice.offset(by: 3, using: ev) == Expr("w/2"))
        // A trailing term that isn't a plain offset isn't folded into.
        let product = Expr("w - 2 * 3").offset(by: 1, using: ev)
        #expect(try ev.length(product) == 35)
        #expect(product.referencedNames == ["w"])
    }

    @Test func anchorIsTheGrabbedPointOrTheNearestKeyPoint() {
        let circle = SketchShape(.circle(center: Point2Expr(10, 10), diameter: 10))
        let sketch = Sketch(shapes: [circle])
        // Grabbing the rim moves by the centre (quadrants aren't anchors).
        let rim = SketchMove(original: sketch, shapes: [circle.id], grabbed: circle.id, press: SIMD2(15.2, 10), using: ev)
        #expect(rim.anchor == SIMD2(10, 10))
        // A picked point is the anchor itself.
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let lines = Sketch(shapes: [line])
        let end = SketchMove(original: lines, shapes: [line.id], grabbed: line.id, point: 1, press: SIMD2(9.8, 0.1), using: ev)
        #expect(end.anchor == SIMD2(10, 0))
        let mid = SketchMove(original: lines, shapes: [line.id], grabbed: line.id, press: SIMD2(5.4, 0.2), using: ev)
        #expect(mid.anchor == SIMD2(5, 0))
    }

    @Test func offsetSnapsTheAnchorToTheGrid() {
        // An off-grid circle grabbed at its rim: the centre lands on the grid.
        let circle = SketchShape(.circle(center: Point2Expr(10.3, 10.3), diameter: 10))
        let move = SketchMove(original: Sketch(shapes: [circle]), shapes: [circle.id], grabbed: circle.id,
                              press: SIMD2(15.3, 10.3), using: ev)
        let ctx = SnapContext(points: circle.snapPoints(using: ev), tolerance: 0.5, gridSize: 1)
        let (offset, snap) = move.offset(to: SIMD2(17.1, 12.4), context: ctx)
        #expect(snap == .grid)
        #expect(abs(offset.x - 1.7) < 1e-9 && abs(offset.y - 1.7) < 1e-9)  // centre 10.3 → 12, 10.3 → 12
        let moved = move.moved(by: offset, using: ev)
        #expect(moved.shapes[0].kind == .circle(center: Point2Expr(12, 12), diameter: 10))
    }

    @Test func offsetSnapsToOtherShapesButNotItself() {
        let fixed = SketchShape(.point(Point2Expr(20, 0)))
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let sketch = Sketch(shapes: [fixed, line])
        let points = sketch.snapPoints(using: ev)
        let ctx = SnapContext(points: points, tolerance: 0.5, gridSize: 0)
        let move = SketchMove(original: sketch, shapes: [line.id], grabbed: line.id, point: 1, press: SIMD2(10, 0), using: ev)
        // Near the fixed point: the end lands exactly on it.
        let near = move.offset(to: SIMD2(19.7, 0.3), context: ctx)
        #expect(near.snap == .point(.point))
        #expect(near.offset == SIMD2(10, 0))
        // Barely moved: its own (old) points don't hold it in place; grid off rounds to 0.01 mm.
        // (Its old end at x = 10 would line up vertically; the fixed point at y = 0 is out of reach.)
        let small = move.offset(to: SIMD2(10.234, 2.111), context: ctx)
        #expect(small.snap == .none)
        #expect(abs(small.offset.x - 0.23) < 1e-9 && abs(small.offset.y - 2.11) < 1e-9)
        // Level with the fixed point: lines up with it horizontally.
        let level = move.resolve(to: SIMD2(10.234, 0.111), context: ctx)
        #expect(level.resolution.snap == .horizontal)
        #expect(level.offset.y == 0)
        #expect(level.resolution.guides == [SnapGuide(kind: .horizontal, from: SIMD2(20, 0), to: SIMD2(10.23, 0))])
        // Only the moving shapes move.
        let moved = move.moved(by: near.offset, using: ev)
        #expect(moved.shapes[0] == fixed)
        #expect(moved.shapes[1].kind == .line(a: Point2Expr(10, 0), b: Point2Expr(20, 0)))
    }

    @Test func movesSeveralShapesTogether() {
        let a = SketchShape(.circle(center: Point2Expr(0, 0), diameter: 4))
        let b = SketchShape(.rectangle(anchor: .corner, position: Point2Expr(5, 5), width: 2, height: 2, angle: 0))
        let c = SketchShape(.point(Point2Expr(50, 50)))
        let move = SketchMove(original: Sketch(shapes: [a, b, c]), shapes: [a.id, b.id], grabbed: a.id, press: SIMD2(2, 0), using: ev)
        let ctx = SnapContext(points: [], tolerance: 0.1, gridSize: 1)
        let (offset, _) = move.offset(to: SIMD2(5.2, 3.1), context: ctx)
        #expect(offset == SIMD2(3, 3))
        let moved = move.moved(by: offset, using: ev)
        #expect(moved.shapes[0].kind == .circle(center: Point2Expr(3, 3), diameter: 4))
        #expect(moved.shapes[1].kind == .rectangle(anchor: .corner, position: Point2Expr(8, 8), width: 2, height: 2, angle: 0))
        #expect(moved.shapes[2] == c)
    }
}
