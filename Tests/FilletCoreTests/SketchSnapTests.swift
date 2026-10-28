import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Sketch snapping")
struct SketchSnapTests {
    let ev = Evaluator.empty

    func context(_ shapes: [SketchShape], tolerance: Double = 0.5, grid: Double = 0) -> SnapContext {
        SnapContext(targets: Sketch(shapes: shapes).snapTargets(using: ev), tolerance: tolerance, gridSize: grid)
    }

    func tap(_ e: inout SketchToolEngine, _ p: SIMD2<Double>, _ c: SnapContext) -> [SketchShape] {
        e.press(p, context: c)
        return e.release(p, context: c)
    }

    func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SketchShape {
        SketchShape(.line(a: Point2Expr(Expr(a.x), Expr(a.y)), b: Point2Expr(Expr(b.x), Expr(b.y))))
    }

    func point(_ p: SIMD2<Double>) -> SketchShape { SketchShape(.point(Point2Expr(Expr(p.x), Expr(p.y)))) }

    // MARK: Alignment

    @Test func horizontalGuideFromTheStartVertex() {
        let c = context([point(SIMD2(30, 20))])
        var e = SketchToolEngine(tool: .line)
        _ = tap(&e, SIMD2(30.2, 19.9), c)  // starts on the vertex
        e.hover(SIMD2(10.3, 20.3), context: c)
        #expect(e.snap == .horizontal)
        #expect(e.cursor == SIMD2(10.3, 20))
        #expect(e.guides == [SnapGuide(kind: .horizontal, from: SIMD2(30, 20), to: SIMD2(10.3, 20))])
        #expect(e.markers == [.anchor(SIMD2(30, 20))])
        guard case .line(let a, let b)? = tap(&e, SIMD2(10.3, 20.3), c).first?.kind else { Issue.record("no line"); return }
        #expect(a == Point2Expr(30, 20) && b == Point2Expr(10.3, 20))
    }

    @Test func verticalGuideFromAnExistingVertex() {
        let c = context([point(SIMD2(5, 40))])
        var e = SketchToolEngine(tool: .line)
        _ = tap(&e, SIMD2(-20, 0), c)
        e.hover(SIMD2(5.3, 12.2), context: c)
        #expect(e.snap == .vertical)
        #expect(e.cursor == SIMD2(5, 12.2))
        #expect(e.guides.map(\.from) == [SIMD2(5, 40)])
    }

    @Test func twoGuidesFixBothCoordinates() {
        // Level with one vertex, under another: their crossing.
        let c = context([point(SIMD2(10, 40)), point(SIMD2(30, 5))])
        let r = c.resolve(SIMD2(10.2, 5.25))
        #expect(r.snap == .aligned)
        #expect(r.point == SIMD2(10, 5))
        #expect(Set(r.guides.map(\.from)) == [SIMD2(10, 40), SIMD2(30, 5)])
        #expect(Set(r.guides.map(\.kind)) == [.horizontal, .vertical])
    }

    @Test func alignmentKeepsTheGridForTheFreeCoordinate() {
        let c = context([point(SIMD2(0, 7))], grid: 1)
        let r = c.resolve(SIMD2(12.4, 7.2))
        #expect(r.snap == .horizontal)
        #expect(r.point == SIMD2(12, 7))
    }

    @Test func rectangleCornerDoesNotLineUpWithItsFirstCorner() {
        let c = context([point(SIMD2(20, 15))])
        var e = SketchToolEngine(tool: .rectangle)
        _ = tap(&e, SIMD2(0, 0), c)
        e.hover(SIMD2(10, 0.2), context: c)
        #expect(e.snap == .none)  // would make a flat rectangle
        e.hover(SIMD2(19.8, 30.2), context: c)
        #expect(e.snap == .vertical)
        #expect(e.cursor?.x == 20)
    }

    // MARK: Points

    @Test func midpointOfAFarAwaySegment() {
        // Only the midpoint is near the pointer; the segment's ends are 500 mm away.
        let c = context([line(SIMD2(0, 100), SIMD2(1000, 100))])
        let r = c.resolve(SIMD2(500.3, 100.2))
        #expect(r.snap == .point(.midpoint))
        #expect(r.point == SIMD2(500, 100))
        #expect(r.markers == [.target(SIMD2(500, 100), .midpoint)])
    }

    @Test func triangleVertexOnTheMidpointOfAnEdge() throws {
        let edge = line(SIMD2(0, 0), SIMD2(20, 0))
        let c = context([edge])
        var e = SketchToolEngine(tool: .line)
        #expect(tap(&e, SIMD2(10.2, 0.3), c).isEmpty)
        let first = try #require(tap(&e, SIMD2(25, 15), c).first)
        #expect(tap(&e, SIMD2(-5, 15), c).count == 1)
        let closing = try #require(tap(&e, SIMD2(10.1, -0.2), c).first)
        guard case .line(let a, _) = first.kind, case .line(_, let b) = closing.kind else { Issue.record(); return }
        #expect(a == Point2Expr(10, 0))
        #expect(b == Point2Expr(10, 0))
        #expect(e.isIdle)
    }

    @Test func pointsBeforeMidpointsBeforeGuides() {
        // The endpoint wins over a closer midpoint; the midpoint over a guide.
        let short = line(SIMD2(0, 0), SIMD2(0.8, 0))
        let c = context([short, point(SIMD2(50, 0.1))])
        #expect(c.resolve(SIMD2(0.5, 0.1)).snap == .point(.endpoint))
        let far = context([line(SIMD2(0, 0), SIMD2(40, 0)), point(SIMD2(20.2, 30))])
        #expect(far.resolve(SIMD2(20.1, 0.1)).snap == .point(.midpoint))
    }

    @Test func prioritiesAreConfigurable() {
        var c = context([line(SIMD2(0, 0), SIMD2(40, 0)), point(SIMD2(20.3, 30))])
        c.settings.priorities = [.point: 0, .alignment: 1, .midpoint: 2]
        let r = c.resolve(SIMD2(20.2, 0.1))
        #expect(r.snap == .point(.midpoint))  // points beat guides whatever their rank…
        c.settings.priorities[.midpoint] = nil  // …but a kind left out is off: under the point, level with the line
        let guided = c.resolve(SIMD2(20.2, 0.1))
        #expect(guided.snap == .aligned)
        #expect(guided.point == SIMD2(20.3, 0))
    }

    // MARK: Intersections

    @Test func crossingLines() {
        // (Off both midpoints, which would snap first.)
        let c = context([line(SIMD2(0, 0), SIMD2(10, 10)), line(SIMD2(0, 9), SIMD2(6, 3))])
        let r = c.resolve(SIMD2(4.7, 4.3))
        #expect(r.snap == .point(.intersection))
        #expect(r.point.isClose(to: SIMD2(4.5, 4.5), tolerance: 1e-12))
    }

    @Test func lineThroughACircleAndArcs() {
        let circle = SketchShape(.circle(center: .origin, diameter: 10))
        let chord = line(SIMD2(-10, 3), SIMD2(10, 3))
        let crossings = Sketch(shapes: [circle, chord]).snapTargets(using: ev).points.filter { $0.kind == .intersection }
        #expect(crossings.count == 2)
        #expect(crossings.allSatisfy { abs(abs($0.position.x) - 4) < 1e-12 && abs($0.position.y - 3) < 1e-12 })
        #expect(Set(crossings.compactMap(\.other)).count == 1)

        // An upper half arc crosses the chord twice, a lower one not at all.
        let upper = SketchShape(.arc(start: Point2Expr(5, 0), through: Point2Expr(0, 5), end: Point2Expr(-5, 0)))
        let lower = SketchShape(.arc(start: Point2Expr(5, 0), through: Point2Expr(0, -5), end: Point2Expr(-5, 0)))
        #expect(Sketch(shapes: [upper, chord]).snapTargets(using: ev).points.filter { $0.kind == .intersection }.count == 2)
        #expect(Sketch(shapes: [lower, chord]).snapTargets(using: ev).points.filter { $0.kind == .intersection }.isEmpty)
    }

    @Test func twoCircles() {
        let a = SketchShape(.circle(center: .origin, diameter: 10))
        let b = SketchShape(.circle(center: Point2Expr(8, 0), diameter: 10))
        let crossings = Sketch(shapes: [a, b]).snapTargets(using: ev).points.filter { $0.kind == .intersection }
        #expect(crossings.count == 2)
        #expect(crossings.allSatisfy { abs($0.position.x - 4) < 1e-12 && abs(abs($0.position.y) - 3) < 1e-12 })
    }

    @Test func sharedCornersAreEndpointsNotIntersections() {
        let targets = Sketch(shapes: [line(SIMD2(0, 0), SIMD2(10, 0)), line(SIMD2(10, 0), SIMD2(10, 10))]).snapTargets(using: ev)
        #expect(!targets.points.contains { $0.kind == .intersection })
    }

    // MARK: Extensions

    @Test func collinearExtensionPastAnEnd() {
        let c = context([line(SIMD2(0, 0), SIMD2(10, 5))])
        let r = c.resolve(SIMD2(20.1, 10.2))
        #expect(r.snap == .extension)
        let v = r.point - SIMD2(10, 5)
        #expect(abs(v.x * 5 - v.y * 10) < 1e-9)  // exactly on the line through the edge
        #expect(r.guides == [SnapGuide(kind: .extension, from: SIMD2(10, 5), to: r.point)])
        // Beside the edge itself there's nothing to extend.
        #expect(c.resolve(SIMD2(4, 1)).snap == .none)
    }

    @Test func extensionCrossingAGuide() {
        // The edge's extension meets the horizontal through a vertex.
        let c = context([line(SIMD2(0, 0), SIMD2(10, 5)), point(SIMD2(-30, 10))])
        let r = c.resolve(SIMD2(20.2, 10.1))
        #expect(r.snap == .aligned)
        #expect(r.point.isClose(to: SIMD2(20, 10), tolerance: 1e-9))
    }

    // MARK: Hysteresis

    @Test func holdsTheCurrentSnapUntilARivalIsClearlyCloser() {
        let c = context([point(SIMD2(0, 0)), point(SIMD2(0.6, 0))])
        var e = SketchToolEngine(tool: .point)
        e.hover(SIMD2(0.1, 0), context: c)
        #expect(e.cursor == SIMD2(0, 0))
        e.hover(SIMD2(0.32, 0), context: c)  // the other point is nearer, but not by much
        #expect(e.cursor == SIMD2(0, 0))
        e.hover(SIMD2(0.5, 0), context: c)
        #expect(e.cursor == SIMD2(0.6, 0))
        // Without a held snap, the nearer one wins straight away.
        var fresh = SketchToolEngine(tool: .point)
        fresh.hover(SIMD2(0.32, 0), context: c)
        #expect(fresh.cursor == SIMD2(0.6, 0))
    }

    @Test func holdsJustPastTheRadius() {
        let c = context([point(SIMD2(0, 0))])
        var e = SketchToolEngine(tool: .point)
        // Diagonally, so no guide through the point catches the pointer instead.
        e.hover(SIMD2(0.3, 0.3), context: c)
        e.hover(SIMD2(0.5, 0.5), context: c)  // 0.71: past 0.5, inside 0.75
        #expect(e.cursor == SIMD2(0, 0))
        e.hover(SIMD2(0.6, 0.6), context: c)
        #expect(e.snap == .none)
        var fresh = SketchToolEngine(tool: .point)
        fresh.hover(SIMD2(0.5, 0.5), context: c)
        #expect(fresh.snap == .none)
    }

    @Test func guidesEndWithTheGesture() {
        let c = context([point(SIMD2(30, 20))])
        var e = SketchToolEngine(tool: .line)
        _ = tap(&e, SIMD2(0, 0), c)
        e.press(SIMD2(10, 20.1), context: c)
        #expect(!e.guides.isEmpty)
        _ = e.release(SIMD2(10, 20.1), context: c)
        #expect(e.guides.isEmpty && e.markers.isEmpty)
        e.hover(SIMD2(12, 20.1), context: c)
        #expect(!e.guides.isEmpty)
        e.cancel()
        #expect(e.guides.isEmpty)
    }

    @Test func typedSizesDropTheGuides() {
        let c = context([point(SIMD2(30, 20))])
        var e = SketchToolEngine(tool: .line)
        _ = tap(&e, SIMD2(0, 0), c)
        e.hover(SIMD2(10, 20.1), context: c)
        #expect(!e.guides.isEmpty)
        e.lock(0, to: 5)
        e.hover(SIMD2(10, 20.1), context: c)
        #expect(e.guides.isEmpty)
    }

    // MARK: Index and scale

    @Test func indexFindsTheSamePointsAsAScan() {
        var rng = SystemRandomNumberGenerator()
        let points = (0..<500).map { _ in
            SnapPoint(position: SIMD2(Double.random(in: -100...100, using: &rng), Double.random(in: -100...100, using: &rng)),
                      kind: .point, shape: UUID())
        }
        let targets = SnapTargets(points: points)
        for _ in 0..<50 {
            let q = SIMD2(Double.random(in: -100...100, using: &rng), Double.random(in: -100...100, using: &rng))
            let r = Double.random(in: 0.1...20, using: &rng)
            #expect(Set(targets.points(near: q, within: r)) == Set(points.filter { snapDistance($0.position, q) <= r }))
            #expect(Set(targets.points(xWithin: r, of: q.x)) == Set(points.filter { abs($0.position.x - q.x) <= r }))
            #expect(Set(targets.points(yWithin: r, of: q.y)) == Set(points.filter { abs($0.position.y - q.y) <= r }))
        }
    }

    @Test func excludingDropsIntersectionsOfEitherShape() {
        let a = line(SIMD2(0, 0), SIMD2(10, 10)), b = line(SIMD2(0, 9), SIMD2(6, 3))
        let targets = Sketch(shapes: [a, b]).snapTargets(using: ev)
        #expect(targets.points.contains { $0.kind == .intersection })
        #expect(!targets.excluding([b.id]).points.contains { $0.kind == .intersection })
        #expect(targets.excluding([b.id]).lines.map(\.shape) == [a.id])
    }

    @Test func radiusIsInScreenPoints() {
        let s = SnapSettings()
        // Twice the zoom, half the radius in mm: the same distance on screen.
        #expect(s.radius(pointerTolerance: 10, unitsPerPoint: 0.2) == 3)
        #expect(s.radius(pointerTolerance: 10, unitsPerPoint: 0.1) == 1.5)
        // A finger catches from further away than the Pencil.
        #expect(s.radius(pointerTolerance: 10, unitsPerPoint: 0.1) > s.radius(pointerTolerance: 6, unitsPerPoint: 0.1))
    }
}
