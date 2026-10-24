import FilletKernel
import Foundation
import Testing
import simd

@testable import FilletCore

func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tol: Double = 1e-9) -> Bool { simd_distance(a, b) <= tol }

func endpoints(_ s: Segment2D) -> (SIMD2<Double>, SIMD2<Double>)? {
    switch s {
    case .line(let a, let b): (a, b)
    case .arc(let a, _, let b): (a, b)
    default: nil
    }
}

@Suite("Sketch geometry")
struct SketchGeometryTests {
    let ev = Evaluator.empty

    func segs(_ kind: SketchShapeKind, _ e: Evaluator = .empty) throws -> [Segment2D] {
        try SketchShape(kind).segments(using: e)
    }

    @Test func line() throws {
        let s = try segs(.line(a: Point2Expr(0, 0), b: Point2Expr(10, "5 mm")))
        #expect(s == [.line(SIMD2(0, 0), SIMD2(10, 5))])
        #expect(throws: SketchError.self) { try segs(.line(a: .origin, b: .origin)) }
    }

    @Test func rectangleCornerAndCenter() throws {
        let corner = try segs(.rectangle(anchor: .corner, position: Point2Expr(1, 2), width: 10, height: 4, angle: 0))
        #expect(corner.count == 4)
        #expect(corner[0] == .line(SIMD2(1, 2), SIMD2(11, 2)))
        #expect(corner[2] == .line(SIMD2(11, 6), SIMD2(1, 6)))

        let center = try segs(.rectangle(anchor: .center, position: .origin, width: 10, height: 4, angle: 0))
        #expect(center[0] == .line(SIMD2(-5, -2), SIMD2(5, -2)))
        // Closed loop: each segment starts where the previous ended.
        for i in 0..<4 {
            let (_, end) = try #require(endpoints(center[i]))
            let (start, _) = try #require(endpoints(center[(i + 1) % 4]))
            #expect(close(end, start))
        }
    }

    @Test func rectangleRotated() throws {
        let s = try segs(.rectangle(anchor: .corner, position: .origin, width: 10, height: 5, angle: 90))
        let pts = s.compactMap { endpoints($0)?.0 }
        #expect(close(pts[0], SIMD2(0, 0)))
        #expect(close(pts[1], SIMD2(0, 10)))
        #expect(close(pts[2], SIMD2(-5, 10)))
        #expect(close(pts[3], SIMD2(-5, 0)))

        let c = try segs(.rectangle(anchor: .center, position: Point2Expr(5, 5), width: 4, height: 2, angle: "45 deg"))
        let first = try #require(endpoints(c[0])?.0)
        let h = 1 / 2.0.squareRoot()
        // Corner (-2, -1) rotated by 45° around the centre.
        #expect(close(first, SIMD2(5 + (-2 * h + 1 * h), 5 + (-2 * h - 1 * h)), 1e-12))
    }

    @Test func circleAndArc() throws {
        #expect(try segs(.circle(center: Point2Expr(3, 4), diameter: 10)) == [.circle(center: SIMD2(3, 4), radius: 5)])
        #expect(throws: SketchError.self) { try segs(.circle(center: .origin, diameter: 0)) }
        let arc = try segs(.arc(start: Point2Expr(10, 0), through: Point2Expr(0, 10), end: Point2Expr(-10, 0)))
        #expect(arc.count == 1)
        #expect(throws: SketchError.self) {
            try segs(.arc(start: Point2Expr(0, 0), through: Point2Expr(1, 1), end: Point2Expr(2, 2)))
        }
        let geometry = try #require(Arc2D(start: SIMD2(10, 0), through: SIMD2(0, 10), end: SIMD2(-10, 0)))
        #expect(close(geometry.center, .zero))
        #expect(abs(geometry.radius - 10) < 1e-12)
        #expect(abs(geometry.sweep - .pi) < 1e-12)
        // Same endpoints, through point below: clockwise.
        let cw = try #require(Arc2D(start: SIMD2(10, 0), through: SIMD2(0, -10), end: SIMD2(-10, 0)))
        #expect(abs(cw.sweep + .pi) < 1e-12)
        #expect(close(cw.mid, SIMD2(0, -10), 1e-9))
    }

    @Test func polygonVertices() throws {
        let hex = try segs(.polygon(center: .origin, sides: 6, radius: 10, inscribed: true, angle: 0))
        #expect(hex.count == 6)
        let v = hex.compactMap { endpoints($0)?.0 }
        #expect(close(v[0], SIMD2(10, 0)))
        #expect(close(v[1], SIMD2(5, 10 * 3.0.squareRoot() / 2), 1e-12))
        for p in v { #expect(abs(simd_length(p) - 10) < 1e-12) }

        // Circumscribed: edges touch the circle, so the edge midpoints are at the radius.
        let sq = try segs(.polygon(center: Point2Expr(1, 1), sides: 4, radius: 5, inscribed: false, angle: 45))
        for s in sq {
            let (a, b) = try #require(endpoints(s))
            #expect(abs(simd_distance((a + b) / 2, SIMD2(1, 1)) - 5) < 1e-12)
        }
        let first = try #require(endpoints(sq[0])?.0)
        #expect(close(first, SIMD2(6, 6), 1e-12))

        #expect(throws: SketchError.self) { try segs(.polygon(center: .origin, sides: 2, radius: 5, inscribed: true, angle: 0)) }
        #expect(throws: EvalError.self) { try segs(.polygon(center: .origin, sides: "3 mm", radius: 5, inscribed: true, angle: 0)) }
    }

    @Test func slotGeometry() throws {
        let s = try segs(.slot(a: Point2Expr(0, 0), b: Point2Expr(20, 0), width: 6))
        #expect(s.count == 4)
        #expect(s[0] == .line(SIMD2(0, -3), SIMD2(20, -3)))
        #expect(s[1] == .arc(start: SIMD2(20, -3), through: SIMD2(23, 0), end: SIMD2(20, 3)))
        #expect(s[2] == .line(SIMD2(20, 3), SIMD2(0, 3)))
        #expect(s[3] == .arc(start: SIMD2(0, 3), through: SIMD2(-3, 0), end: SIMD2(0, -3)))
        // Coincident centres degenerate to a circle.
        #expect(try segs(.slot(a: .origin, b: .origin, width: 4)) == [.circle(center: .zero, radius: 2)])
    }

    @Test func diagonalSlotIsClosed() throws {
        let s = try segs(.slot(a: Point2Expr(1, 2), b: Point2Expr(7, 10), width: 3))
        for i in 0..<4 {
            let (_, end) = try #require(endpoints(s[i]))
            let (start, _) = try #require(endpoints(s[(i + 1) % 4]))
            #expect(close(end, start, 1e-12))
        }
        // The far tip lies one half-width beyond b along the axis.
        if case .arc(_, let tip, _) = s[1] { #expect(close(tip, SIMD2(7 + 0.9, 10 + 1.2), 1e-12)) }
    }

    @Test func polylineWithBulge() throws {
        let kind = SketchShapeKind.polyline(
            vertices: [PolylineVertex(0, 0), PolylineVertex(10, 0, bulge: 5), PolylineVertex(10, 10), PolylineVertex(0, 10)],
            closed: true)
        let s = try segs(kind)
        #expect(s.count == 4)
        #expect(s[0] == .line(SIMD2(0, 0), SIMD2(10, 0)))
        // Bulge 5 to the left of travel (+y → -x): semicircle through (5, 5)... reaches x = 10 - 5.
        #expect(s[1] == .arc(start: SIMD2(10, 0), through: SIMD2(5, 5), end: SIMD2(10, 10)))
        #expect(s[3] == .line(SIMD2(0, 10), SIMD2(0, 0)))
        let open = try segs(.polyline(vertices: [PolylineVertex(0, 0), PolylineVertex(5, 0)], closed: false))
        #expect(open.count == 1)
        #expect(throws: SketchError.self) { try segs(.polyline(vertices: [PolylineVertex(0, 0)], closed: false)) }
    }

    @Test func splineAndPoint() throws {
        let pts = [Point2Expr(0, 0), Point2Expr(5, 5), Point2Expr(10, 0)]
        #expect(try segs(.spline(points: pts)) == [.bspline([SIMD2(0, 0), SIMD2(5, 5), SIMD2(10, 0)])])
        #expect(try segs(.point(Point2Expr(1, 1))).isEmpty)
    }

    @Test func constructionShapesHaveNoProfileSegments() throws {
        let shape = SketchShape(construction: true, .line(a: .origin, b: Point2Expr(10, 0)))
        #expect(try shape.segments(using: ev).isEmpty)
        #expect(try shape.curves(using: ev).count == 1)
        #expect(shape.displayPolyline(using: ev) == [[SIMD2(0, 0), SIMD2(10, 0)]])
        let sketch = Sketch(shapes: [shape, SketchShape(.circle(center: .origin, diameter: 4))])
        #expect(try sketch.segments(using: ev).count == 1)
    }

    @Test func parametricDimensions() throws {
        let table = ParameterTable([Parameter(name: "w", expression: "30"), Parameter(name: "h", expression: "w/3")])
        let s = try segs(.rectangle(anchor: .center, position: .origin, width: "w", height: "h", angle: 0), table.evaluator)
        #expect(s[0] == .line(SIMD2(-15, -5), SIMD2(15, -5)))
    }

    @Test func errorsCarryShapeID() throws {
        let shape = SketchShape(.circle(center: .origin, diameter: -1))
        do {
            _ = try shape.segments(using: ev)
            Issue.record("expected error")
        } catch let error as SketchError {
            #expect(error.shape == shape.id)
        }
    }

    @Test func displayPolylines() throws {
        let rect = SketchShape(.rectangle(anchor: .corner, position: .origin, width: 4, height: 2, angle: 0))
        let poly = rect.displayPolyline(using: ev)
        #expect(poly.count == 1)  // merged into one closed loop
        #expect(poly[0].count == 5)
        #expect(close(poly[0].first!, poly[0].last!))

        let circle = SketchShape(.circle(center: .origin, diameter: 20)).displayPolyline(using: ev)
        #expect(circle.count == 1)
        #expect(circle[0].count >= 73)
        for p in circle[0] { #expect(abs(simd_length(p) - 10) < 1e-9) }

        let slot = SketchShape(.slot(a: .origin, b: Point2Expr(10, 0), width: 4)).displayPolyline(using: ev)
        #expect(slot.count == 1)
        for p in slot[0] { #expect(p.x >= -2 - 1e-9 && p.x <= 12 + 1e-9 && abs(p.y) <= 2 + 1e-9) }

        let spline = SketchShape(.spline(points: [Point2Expr(0, 0), Point2Expr(5, 5), Point2Expr(10, 0)]))
            .displayPolyline(using: ev)
        #expect(spline[0].count > 3)
        #expect(spline[0].contains { close($0, SIMD2(5, 5), 1e-9) })
        #expect(close(spline[0].last!, SIMD2(10, 0), 1e-9))

        #expect(SketchShape(.point(Point2Expr(1, 2))).displayPolyline(using: ev) == [[SIMD2(1, 2)]])
        #expect(SketchShape(.circle(center: .origin, diameter: "bad")).displayPolyline(using: ev).isEmpty)
    }

    @Test func snapPoints() throws {
        let rect = SketchShape(.rectangle(anchor: .corner, position: .origin, width: 10, height: 4, angle: 0))
        let snaps = rect.snapPoints(using: ev)
        #expect(snaps.filter { $0.kind == .endpoint }.count == 4)
        #expect(snaps.filter { $0.kind == .midpoint }.count == 4)
        #expect(snaps.contains { $0.kind == .center && close($0.position, SIMD2(5, 2)) })
        #expect(snaps.allSatisfy { $0.shape == rect.id })

        let circle = SketchShape(.circle(center: Point2Expr(1, 1), diameter: 4)).snapPoints(using: ev)
        #expect(circle.filter { $0.kind == .quadrant }.map(\.position).contains(SIMD2(3, 1)))
        #expect(circle.filter { $0.kind == .center }.count == 1)

        let arc = SketchShape(.arc(start: Point2Expr(10, 0), through: Point2Expr(0, 10), end: Point2Expr(-10, 0)))
            .snapPoints(using: ev)
        #expect(arc.contains { $0.kind == .center && close($0.position, .zero, 1e-9) })
        #expect(arc.contains { $0.kind == .midpoint && close($0.position, SIMD2(0, 10), 1e-9) })

        let slot = SketchShape(.slot(a: .origin, b: Point2Expr(10, 0), width: 4)).snapPoints(using: ev)
        #expect(slot.filter { $0.kind == .center }.count == 2)

        let hex = SketchShape(.polygon(center: Point2Expr(2, 2), sides: 6, radius: 5, inscribed: true, angle: 0))
            .snapPoints(using: ev)
        #expect(hex.filter { $0.kind == .endpoint }.count == 6)
        #expect(hex.contains { $0.kind == .center && $0.position == SIMD2(2, 2) })

        #expect(SketchShape(.point(Point2Expr(3, 4))).snapPoints(using: ev).map(\.kind) == [.point])
    }
}
