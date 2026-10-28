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

    // MARK: Vertices

    @Test func pickedEndsAreVerticesButMidpointsAndCentresAreNot() {
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let circle = SketchShape(.circle(center: Point2Expr(30, 0), diameter: 4))
        let spline = SketchShape(.spline(points: [Point2Expr(0, 10), Point2Expr(5, 12), Point2Expr(10, 10)]))
        let sketch = Sketch(shapes: [line, circle, spline])
        // A line's snap points: start, end, midpoint.
        #expect(sketch.vertex(shape: line.id, point: 0, using: ev) == SketchVertex(shape: line.id, index: 0))
        #expect(sketch.vertex(shape: line.id, point: 1, using: ev) == SketchVertex(shape: line.id, index: 1))
        #expect(sketch.vertex(shape: line.id, point: 2, using: ev) == nil)
        #expect(sketch.vertex(shape: circle.id, point: 0, using: ev) == nil)
        // A spline's interior point is one.
        let interior = spline.snapPoints(using: ev).firstIndex { $0.kind == .point }
        #expect(interior.flatMap { sketch.vertex(shape: spline.id, point: $0, using: ev) } == SketchVertex(shape: spline.id, index: 1))
    }

    @Test func draggingAnEndMovesOnlyThatEnd() throws {
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let other = SketchShape(.point(Point2Expr(20, 20)))
        let sketch = Sketch(shapes: [line, other])
        let drag = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: line.id, index: 1),
                                           press: SIMD2(9.8, 0.1), using: ev))
        #expect(drag.anchor == SIMD2(10, 0))
        #expect(drag.shapes == [line.id])
        let ctx = SnapContext(targets: sketch.snapTargets(using: ev), tolerance: 0.5, gridSize: 1)
        // Onto the other shape's point: the end lands on it, the start stays.
        let onto = drag.resolve(to: SIMD2(19.6, 20.3), context: ctx)
        #expect(onto.resolution.snap == .point(.point))
        let moved = drag.moved(by: onto.offset, using: ev)
        #expect(moved.shapes[0].kind == .line(a: Point2Expr(0, 0), b: Point2Expr(20, 20)))
        #expect(moved.shapes[1] == other)
    }

    @Test func aDraggedEndLinesUpWithItsOtherEndButNeverLandsOnIt() throws {
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 5)))
        let sketch = Sketch(shapes: [line])
        let drag = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: line.id, index: 1),
                                           press: SIMD2(10, 5), using: ev))
        let ctx = SnapContext(targets: sketch.snapTargets(using: ev), tolerance: 0.5, gridSize: 0)
        // Nearly level with the start: a horizontal guide from it makes the line level.
        let level = drag.resolve(to: SIMD2(12.34, 0.2), context: ctx)
        #expect(level.resolution.snap == .horizontal)
        #expect(level.resolution.guides.first?.from == SIMD2(0, 0))
        #expect(drag.moved(by: level.offset, using: ev).shapes[0].kind == .line(a: Point2Expr(0, 0), b: Point2Expr(12.34, 0)))
        // Right by the start: lined up both ways, which is the start itself, so the drag refuses it.
        let onto = drag.resolve(to: SIMD2(0.1, 0.1), context: ctx)
        #expect(onto.resolution.snap != .point(.endpoint))
        #expect(drag.collapses(by: onto.offset, using: ev))
        #expect(!drag.collapses(by: level.offset, using: ev))
    }

    @Test func joinedEndsMoveTogether() throws {
        // An open triangle of lines drawn end to end, and a line that only passes nearby.
        let ab = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let bc = SketchShape(.line(a: Point2Expr(10, 0), b: Point2Expr(5, 8)))
        let ca = SketchShape(.line(a: Point2Expr(5, 8), b: Point2Expr(0, 0)))
        let apart = SketchShape(.line(a: Point2Expr(10, 0.5), b: Point2Expr(20, 0.5)))
        let sketch = Sketch(shapes: [ab, bc, ca, apart])
        let drag = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: ab.id, index: 1),
                                           press: SIMD2(10, 0), using: ev))
        #expect(drag.shapes == [ab.id, bc.id])
        #expect(Set(drag.vertices) == [SketchVertex(shape: ab.id, index: 1), SketchVertex(shape: bc.id, index: 0)])
        let moved = drag.moved(by: SIMD2(2, -1), using: ev)
        #expect(moved.shapes[0].kind == .line(a: Point2Expr(0, 0), b: Point2Expr(12, -1)))
        #expect(moved.shapes[1].kind == .line(a: Point2Expr(12, -1), b: Point2Expr(5, 8)))
        #expect(moved.shapes[2] == ca)
        #expect(moved.shapes[3] == apart)
        // Both other corners guide.
        #expect(Set(drag.fixedVertices.map { [$0.x, $0.y] }) == [[0, 0], [5, 8]])
    }

    @Test func polylineAndSplineVerticesMoveAlone() throws {
        let poly = SketchShape(.polyline(vertices: [PolylineVertex(0, 0), PolylineVertex(10, 0, bulge: 2), PolylineVertex(10, 10)],
                                         closed: true))
        let spline = SketchShape(.spline(points: [Point2Expr(0, 20), Point2Expr(5, 22), Point2Expr(10, 20)]))
        let sketch = Sketch(shapes: [poly, spline])
        let corner = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: poly.id, index: 1), press: SIMD2(10, 0), using: ev))
        #expect(corner.moved(by: SIMD2(1, 1), using: ev).shapes[0].kind
            == .polyline(vertices: [PolylineVertex(0, 0), PolylineVertex(11, 1, bulge: 2), PolylineVertex(10, 10)], closed: true))
        // Closed: the last vertex neighbours the first.
        let last = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: poly.id, index: 2), press: SIMD2(10, 10), using: ev))
        #expect(last.collapses(by: SIMD2(-10, -10), using: ev))
        let mid = try #require(SketchMove(original: sketch, vertex: SketchVertex(shape: spline.id, index: 1), press: SIMD2(5, 22), using: ev))
        #expect(mid.moved(by: SIMD2(0, 3), using: ev).shapes[1].kind == .spline(points: [Point2Expr(0, 20), Point2Expr(5, 25), Point2Expr(10, 20)]))
    }

    @Test func parametricEndsKeepTheirParameters() throws {
        let ev = Evaluator(values: ["w": Quantity(40, .length)])
        let line = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr("w", 0)))
        let drag = try #require(SketchMove(original: Sketch(shapes: [line]), vertex: SketchVertex(shape: line.id, index: 1),
                                           press: SIMD2(40, 0), using: ev))
        #expect(drag.anchor == SIMD2(40, 0))
        #expect(drag.moved(by: SIMD2(5, 0), using: ev).shapes[0].kind == .line(a: Point2Expr(0, 0), b: Point2Expr("w + 5", 0)))
    }

    @Test func typingAnEndKeepsJoinedEndsJoined() {
        let ab = SketchShape(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        let bc = SketchShape(.line(a: Point2Expr(10, 0), b: Point2Expr(5, 8)))
        let circle = SketchShape(.circle(center: Point2Expr(10, 0), diameter: 2))
        let sketch = Sketch(shapes: [ab, bc, circle])
        var typed = ab
        typed.kind = .line(a: Point2Expr(0, 0), b: Point2Expr("w", 0))
        let ev = Evaluator(values: ["w": Quantity(12, .length)])
        let edited = sketch.replacing(typed, using: ev)
        #expect(edited.shapes[0] == typed)
        #expect(edited.shapes[1].kind == .line(a: Point2Expr("w", 0), b: Point2Expr(5, 8)))
        #expect(edited.shapes[2] == circle)  // a centre isn't a vertex
        // A shape whose vertices didn't change leaves the rest alone.
        var renamed = bc
        renamed.construction = true
        #expect(sketch.replacing(renamed, using: ev).shapes[0] == ab)
    }
}
