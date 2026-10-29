import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Snapping to body edges")
struct BodySnapTests {
    let ev = Evaluator.empty
    let body = UUID()

    func edge(_ curve: CurveType, _ start: Vec3, _ mid: Vec3, _ end: Vec3, radius: Double = 0) -> EdgeInfo {
        EdgeInfo(curve: curve, start: start, mid: mid, end: end, tangentAtMid: (end - start).normalized,
                 length: start.distance(to: end), radius: radius)
    }

    func line(_ a: Vec3, _ b: Vec3) -> EdgeInfo { edge(.line, a, (a + b) / 2, b) }

    func context(_ shapes: [SketchShape] = [], _ references: [SnapReference], tolerance: Double = 0.5) -> SnapContext {
        SnapContext(targets: Sketch(shapes: shapes).snapTargets(using: ev, references: references), tolerance: tolerance, gridSize: 0)
    }

    // MARK: Which edges

    @Test func keepsEdgesInThePlaneAndCornersTouchingIt() {
        let r = SnapReference(source: body, edges: [
            line(Vec3(0, 0, 0), Vec3(40, 0, 0)),     // on the bed
            line(Vec3(0, 0, 10), Vec3(40, 0, 10)),   // the top, above it
            line(Vec3(40, 0, 0), Vec3(40, 0, 10)),   // upright: only its foot is in the plane
            line(Vec3(5, 5, -5), Vec3(5, 5, 5)),     // passes through it, ends on neither side
        ], in: .xy)
        #expect(r.curves == [.line(SIMD2(0, 0), SIMD2(40, 0))])
        #expect(r.points == [SIMD2(40, 0)])
    }

    @Test func circlesAndArcsKeepTheirShape() {
        let r = SnapReference(source: body, edges: [
            // A closed circle of radius 3 around (10, 10): starts and ends at its seam, mid opposite.
            edge(.circle, Vec3(13, 10, 0), Vec3(7, 10, 0), Vec3(13, 10, 0), radius: 3),
            // A quarter arc of radius 5 around the origin.
            edge(.circle, Vec3(5, 0, 0), Vec3(5 / 2.0.squareRoot(), 5 / 2.0.squareRoot(), 0), Vec3(0, 5, 0), radius: 5),
        ], in: .xy)
        #expect(r.curves.count == 2)
        guard case .circle(let c, let radius) = r.curves[0] else { Issue.record("not a circle"); return }
        #expect(c.isClose(to: SIMD2(10, 10), tolerance: 1e-9) && radius == 3)
        guard case .arc(let a, _, let b) = r.curves[1] else { Issue.record("not an arc"); return }
        #expect(a == SIMD2(5, 0) && b == SIMD2(0, 5))
    }

    @Test func usesTheSketchPlanesCoordinates() {
        // The top of a 10 mm part, sketched on from above: x and y as on the bed.
        let r = SnapReference(source: body, edges: [line(Vec3(0, 0, 10), Vec3(40, 0, 10))], in: Plane.xy.offset(by: 10))
        #expect(r.curves == [.line(SIMD2(0, 0), SIMD2(40, 0))])
        // The front plane looks from −Y: u is X, v is Z.
        let front = SnapReference(source: body, edges: [line(Vec3(0, 0, 0), Vec3(0, 0, 10))], in: .xz)
        #expect(front.curves == [.line(SIMD2(0, 0), SIMD2(0, 10))])
    }

    // MARK: Snapping

    @Test func snapsToABodyCorner() {
        let c = context([SnapReference(source: body, curves: [.line(SIMD2(0, 0), SIMD2(40, 0)), .line(SIMD2(40, 0), SIMD2(40, 20))])])
        let r = c.resolve(SIMD2(39.8, 0.3))
        #expect(r.point == SIMD2(40, 0))
        #expect(r.snap == .point(.endpoint))
        // Shared by two edges, the corner is one snap point.
        #expect(c.targets.points.filter { $0.position == SIMD2(40, 0) && $0.kind == .endpoint }.count == 1)
    }

    @Test func snapsToAHoleCentreAndLinesUpWithIt() {
        let c = context([SnapReference(source: body, curves: [.circle(center: SIMD2(10, 10), radius: 3)])])
        #expect(c.resolve(SIMD2(10.2, 9.9)).point == SIMD2(10, 10))
        #expect(c.resolve(SIMD2(10.2, 9.9)).snap == .point(.center))
        // Level with the hole, further along: a horizontal guide from its centre.
        let r = c.resolve(SIMD2(30, 10.2))
        #expect(r.snap == .horizontal)
        #expect(r.point.y == 10)
        #expect(r.guides.map(\.from) == [SIMD2(10, 10)])
    }

    @Test func extendsAStraightBodyEdge() {
        let c = context([SnapReference(source: body, curves: [.line(SIMD2(0, 0), SIMD2(10, 10))])])
        let r = c.resolve(SIMD2(15.2, 14.9))
        #expect(r.snap == .extension)
        #expect(abs(r.point.x - r.point.y) < 1e-9)
    }

    @Test func snapsWhereASketchLineCrossesABodyEdge() {
        // (Its midpoint is elsewhere: a crossing on a point already snapped to isn't added again.)
        let sketchLine = SketchShape(.line(a: Point2Expr(20, -10), b: Point2Expr(20, 30)))
        let c = context([sketchLine], [SnapReference(source: body, curves: [.line(SIMD2(0, 0), SIMD2(40, 0))])])
        #expect(c.targets.points.contains { $0.kind == .intersection && $0.position == SIMD2(20, 0) })
        #expect(c.resolve(SIMD2(20.2, 0.2)).point == SIMD2(20, 0))
    }

    @Test func movedShapesStillSnapToTheBody() {
        let shape = SketchShape(.line(a: Point2Expr(0, 5), b: Point2Expr(5, 5)))
        let targets = Sketch(shapes: [shape]).snapTargets(using: ev, references: [
            SnapReference(source: body, curves: [.line(SIMD2(0, 0), SIMD2(40, 0))], points: [SIMD2(40, 20)]),
        ])
        let others = targets.excluding([shape.id])
        #expect(others.points.contains { $0.position == SIMD2(40, 0) && $0.kind == .endpoint })
        #expect(others.points.contains { $0.position == SIMD2(40, 20) && $0.kind == .endpoint })
        #expect(others.lines.map(\.shape) == [body])
    }

    // MARK: Real bodies

    @Test func aBoxGivesItsBottomAndTopOutlines() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(40, 20, 10))
        let bottom = box.snapReference(in: .xy, source: body)
        #expect(bottom.curves.count == 4)
        #expect(Set(bottom.curves.flatMap { $0.snapPoints.filter { $0.1 == .endpoint }.map { [$0.0.x, $0.0.y] } })
            == [[0, 0], [40, 0], [40, 20], [0, 20]])
        #expect(box.snapReference(in: Plane.xy.offset(by: 10), source: body).curves.count == 4)
        // Halfway up, the upright edges only pass through: nothing to snap to.
        #expect(box.snapReference(in: Plane.xy.offset(by: 5), source: body).isEmpty)
        // Far above, the bounds rule the body out.
        #expect(box.snapReference(in: Plane.xy.offset(by: 50), source: body).isEmpty)
    }

    @Test func aHoleInTheTopFaceSnapsToItsCentre() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(40, 20, 10))
        let drill = try Shape.cylinder(base: Plane(origin: Vec3(10, 10, -1), normal: .unitZ, xDir: .unitX), radius: 3, height: 12)
        let part = try box.cut(by: drill)
        let top = part.snapReference(in: Plane.xy.offset(by: 10), source: body)
        let c = context([top])
        let r = c.resolve(SIMD2(10.3, 9.8))
        #expect(r.snap == .point(.center))
        #expect(r.point.isClose(to: SIMD2(10, 10), tolerance: 1e-6))
    }
}
