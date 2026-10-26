import FilletKernel
import Foundation
import Testing
import simd

@testable import FilletCore

@Suite("Sketch offset")
struct SketchOffsetTests {
    let ev = Evaluator.empty

    func sketch(_ kinds: SketchShapeKind...) -> Sketch {
        Sketch(shapes: kinds.map { SketchShape($0) })
    }

    /// Offsets the chain of the first shape.
    func offset(_ s: Sketch, _ d: Double, pick: Int = 0) throws -> [SketchShapeKind] {
        let chain = try #require(s.offsetChain(containing: s.shapes[pick].id, using: ev))
        return try chain.offset(by: d)
    }

    /// Area enclosed by a closed shape's curves (sampled finely).
    func area(_ kind: SketchShapeKind) throws -> Double {
        let pts = try SketchShape(kind).curves(using: ev).flatMap { $0.sampled(maxAngleStep: .pi / 2000).dropLast() }
        var a = 0.0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            a += p.x * q.y - q.x * p.y
        }
        return abs(a) / 2
    }

    /// The distance from `p` to the nearest curve of `kind`.
    func distance(_ p: SIMD2<Double>, to kind: SketchShapeKind) throws -> Double {
        try SketchShape(kind).curves(using: ev).flatMap(ChainCurve.from).map { $0.closest(to: p).distance }.min() ?? .infinity
    }

    /// Every sampled point of `result` lies `d` from `original`.
    func expectOffset(_ result: SketchShapeKind, from original: [SketchShapeKind], by d: Double) throws {
        let originals = try original.flatMap { try SketchShape($0).curves(using: ev).flatMap(ChainCurve.from) }
        for p in try SketchShape(result).curves(using: ev).flatMap({ $0.sampled() }) {
            let nearest = originals.map { $0.closest(to: p).distance }.min() ?? .infinity
            #expect(abs(nearest - d) < 1e-3, "point \(p) is \(nearest) from the original, not \(d)")
        }
    }

    // MARK: Shape kinds

    @Test func circleGivesConcentricCircles() throws {
        let s = sketch(.circle(center: Point2Expr("cx", 4), diameter: 10))
        let ev = Evaluator(values: ["cx": Quantity(3, .length)])
        let chain = try #require(s.offsetChain(containing: s.shapes[0].id, using: ev))
        #expect(chain.closed)
        #expect(try chain.offset(by: 2) == [.circle(center: Point2Expr("cx", 4), diameter: 14)])
        #expect(try chain.offset(by: -3) == [.circle(center: Point2Expr("cx", 4), diameter: 4)])
        #expect(throws: SketchError.self) { try chain.offset(by: -5) }
        // The pointer's side: inside is negative.
        #expect(abs(chain.signedDistance(to: SIMD2(3, 6)).distance + 3) < 1e-9)
        #expect(abs(chain.signedDistance(to: SIMD2(3, 12)).distance - 3) < 1e-9)
    }

    @Test func arcGivesConcentricArc() throws {
        // Counter-clockwise half circle of radius 10: left is towards the centre.
        let s = sketch(.arc(start: Point2Expr(10, 0), through: Point2Expr(0, 10), end: Point2Expr(-10, 0)))
        guard case .arc(let a, let m, let b) = try #require(offset(s, 2).first) else { Issue.record("not an arc"); return }
        #expect(a == Point2Expr(8, 0) && m == Point2Expr(0, 8) && b == Point2Expr(-8, 0))
        guard case .arc(let a2, _, let b2) = try #require(offset(s, -3).first) else { Issue.record("not an arc"); return }
        #expect(a2 == Point2Expr(13, 0) && b2 == Point2Expr(-13, 0))
        #expect(throws: SketchError.self) { try offset(s, 10) }
    }

    @Test func lineMovesSideways() throws {
        let s = sketch(.line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)))
        #expect(try offset(s, 2) == [.line(a: Point2Expr(0, 2), b: Point2Expr(10, 2))])
        #expect(try offset(s, -2) == [.line(a: Point2Expr(0, -2), b: Point2Expr(10, -2))])
        let chain = try #require(s.offsetChain(containing: s.shapes[0].id, using: ev))
        #expect(chain.signedDistance(to: SIMD2(5, -4)).distance == -4)
    }

    @Test func rectangleOutwardRoundsCorners() throws {
        let rect = SketchShapeKind.rectangle(anchor: .corner, position: .origin, width: 60, height: 30, angle: 0)
        let result = try offset(sketch(rect), 5)
        guard case .polyline(let vertices, true) = try #require(result.first) else { Issue.record("not a closed polyline"); return }
        // Four sides and four corner arcs.
        #expect(vertices.count == 8)
        #expect(vertices.filter { $0.bulge != nil }.count == 4)
        try expectOffset(result[0], from: [rect], by: 5)
        let expected = 70.0 * 40 - 4 * 25 + .pi * 25
        #expect(abs(try area(result[0]) - expected) < 0.01)
    }

    @Test func rectangleInwardStaysARectangle() throws {
        let rect = SketchShapeKind.rectangle(anchor: .corner, position: Point2Expr(60, 30), width: -60, height: -30, angle: 30)
        let result = try offset(sketch(rect), -5)
        guard case .rectangle(.center, let c, 50, 20, let angle) = try #require(result.first) else {
            Issue.record("not a centred 50 × 20 rectangle: \(result)"); return
        }
        #expect(angle == 30)
        try expectOffset(result[0], from: [rect], by: 5)
        _ = c
        #expect(throws: SketchError.self) { try offset(sketch(rect), -15) }
    }

    @Test func polygonInwardAndOutward() throws {
        let hex = SketchShapeKind.polygon(center: .origin, sides: 6, radius: 20, inscribed: true, angle: 0)
        let inward = try offset(sketch(hex), -3)
        guard case .polygon(_, 6, let r, true, 0) = try #require(inward.first) else { Issue.record("not a hexagon"); return }
        #expect(abs(try ev.length(r) - (20 - 3 / cos(Double.pi / 6))) < 1e-3)
        try expectOffset(inward[0], from: [hex], by: 3)
        let outward = try offset(sketch(hex), 3)
        guard case .polyline(let vertices, true) = try #require(outward.first) else { Issue.record("not a polyline"); return }
        #expect(vertices.count == 12)
        try expectOffset(outward[0], from: [hex], by: 3)
        // Circumscribed: the radius is the distance to the sides.
        let square = SketchShapeKind.polygon(center: .origin, sides: 4, radius: 10, inscribed: false, angle: 45)
        guard case .polygon(_, _, let r2, false, _) = try #require(offset(sketch(square), -4).first) else { Issue.record(); return }
        #expect(try ev.length(r2) == 6)
    }

    @Test func slotGivesSlot() throws {
        let slot = SketchShapeKind.slot(a: Point2Expr(0, 0), b: Point2Expr(20, 0), width: 8)
        #expect(try offset(sketch(slot), 2) == [.slot(a: Point2Expr(0, 0), b: Point2Expr(20, 0), width: 12)])
        #expect(try offset(sketch(slot), -3) == [.slot(a: Point2Expr(0, 0), b: Point2Expr(20, 0), width: 2)])
        #expect(throws: SketchError.self) { try offset(sketch(slot), -4) }
    }

    @Test func splineIsApproximated() throws {
        let s = sketch(.spline(points: [Point2Expr(0, 0), Point2Expr(10, 5), Point2Expr(20, 0)]))
        guard case .spline(let points) = try #require(offset(s, 2).first) else { Issue.record("not a spline"); return }
        #expect(points.count == 3)
        // The middle point moves straight up (the curve runs level there).
        #expect(points[1] == Point2Expr(10, 7))
    }

    // MARK: Chains

    @Test func pickingOneLineTakesTheChain() throws {
        // An L of two lines (drawn in opposite directions) and a separate line.
        let s = sketch(
            .line(a: Point2Expr(0, 0), b: Point2Expr(20, 0)),
            .line(a: Point2Expr(20, 10), b: Point2Expr(20, 0)),
            .line(a: Point2Expr(50, 0), b: Point2Expr(60, 0)))
        let chain = try #require(s.offsetChain(containing: s.shapes[1].id, using: ev))
        #expect(Set(chain.shapes) == Set([s.shapes[0].id, s.shapes[1].id]))
        #expect(!chain.closed)
    }

    @Test func chainStopsAtABranch() throws {
        // Three lines meet at (10, 0): no single way on.
        let s = sketch(
            .line(a: Point2Expr(0, 0), b: Point2Expr(10, 0)),
            .line(a: Point2Expr(10, 0), b: Point2Expr(20, 0)),
            .line(a: Point2Expr(10, 0), b: Point2Expr(10, 10)))
        let chain = try #require(s.offsetChain(containing: s.shapes[0].id, using: ev))
        #expect(chain.shapes == [s.shapes[0].id])
    }

    @Test func openChainConvexAndConcaveCorners() throws {
        // An L running right then up: it turns left, so its left side is the concave one.
        let l: [SketchShapeKind] = [.line(a: Point2Expr(0, 0), b: Point2Expr(20, 0)), .line(a: Point2Expr(20, 0), b: Point2Expr(20, 10))]
        let s = Sketch(shapes: l.map { SketchShape($0) })
        let chain = try #require(s.offsetChain(containing: s.shapes[0].id, using: ev))
        let first = try chain.signedDistance(to: SIMD2(5, 2))
        let side: Double = first.distance > 0 ? 1 : -1  // the chain may run either way
        // Inside the corner: trimmed to a sharp corner at (18, 2).
        guard case .polyline(let inner, false) = try #require(chain.offset(by: 2 * side).first) else { Issue.record(); return }
        #expect(inner.count == 3)
        #expect(inner.contains { $0.point == Point2Expr(18, 2) })
        #expect(inner.allSatisfy { $0.bulge == nil })
        // Outside: a quarter arc around the corner.
        let outerKind = try #require(chain.offset(by: -2 * side).first)
        guard case .polyline(let outer, false) = outerKind else { Issue.record(); return }
        #expect(outer.count == 4)
        #expect(outer.filter { $0.bulge != nil }.count == 1)
        try expectOffset(outerKind, from: l, by: 2)
    }

    @Test func closedChainWithAConcaveCorner() throws {
        // An L-shaped outline drawn clockwise as one closed polyline: five convex corners, one concave.
        let outline = SketchShapeKind.polyline(vertices: [
            PolylineVertex(0, 0), PolylineVertex(0, 30), PolylineVertex(10, 30), PolylineVertex(10, 10),
            PolylineVertex(30, 10), PolylineVertex(30, 0),
        ], closed: true)
        let s = sketch(outline)
        let outward = try #require(offset(s, 2).first)
        guard case .polyline(let v, true) = outward else { Issue.record(); return }
        #expect(v.filter { $0.bulge != nil }.count == 5)
        #expect(v.count == 11)
        try expectOffset(outward, from: [outline], by: 2)
        let inward = try #require(offset(s, -2).first)
        guard case .polyline(let w, true) = inward else { Issue.record(); return }
        #expect(w.filter { $0.bulge != nil }.count == 1)
        try expectOffset(inward, from: [outline], by: 2)
        // The legs are 10 wide: 5 in meets in the middle.
        #expect(throws: SketchError.self) { try offset(s, -5) }
    }

    @Test func chainOfLinesAndArcsCloses() throws {
        // A slot drawn by hand: two lines and two arcs.
        let s = sketch(
            .line(a: Point2Expr(0, -5), b: Point2Expr(20, -5)),
            .arc(start: Point2Expr(20, -5), through: Point2Expr(25, 0), end: Point2Expr(20, 5)),
            .line(a: Point2Expr(0, 5), b: Point2Expr(20, 5)),  // drawn the other way
            .arc(start: Point2Expr(0, 5), through: Point2Expr(-5, 0), end: Point2Expr(0, -5)))
        let chain = try #require(s.offsetChain(containing: s.shapes[2].id, using: ev))
        #expect(chain.closed && chain.shapes.count == 4)
        let out = try #require(chain.offset(by: 1).first)
        guard case .polyline(let v, true) = out else { Issue.record(); return }
        #expect(v.count == 4)  // smooth joins: no corner arcs
        #expect(abs(try area(out) - (20 * 12 + .pi * 36)) < 0.05)
        #expect(throws: SketchError.self) { try chain.offset(by: -5) }
    }

    // MARK: The tool

    func context(_ s: Sketch, grid: Double = 1) -> SnapContext {
        var c = SnapContext(points: s.snapPoints(using: ev), tolerance: 0.5, gridSize: grid)
        c.sketch = s
        return c
    }

    func tap(_ e: inout SketchToolEngine, _ p: SIMD2<Double>, _ c: SnapContext) -> [SketchShape] {
        e.press(p, context: c)
        return e.release(p, context: c)
    }

    @Test func toolPicksThenPlaces() throws {
        let s = sketch(.rectangle(anchor: .corner, position: .origin, width: 60, height: 30, angle: 0))
        let c = context(s)
        var e = SketchToolEngine(tool: .offset)
        e.hover(SIMD2(30, 0.2), context: c)
        #expect(!e.preview().isEmpty, "the chain under the pointer previews")
        #expect(tap(&e, SIMD2(30, 0.2), c).isEmpty)
        #expect(e.offset.chains.count == 1 && !e.isIdle)
        #expect(e.dimensionKinds == [.distance])
        // Outside, 4.8 mm below: the distance snaps to 5 mm.
        e.hover(SIMD2(30, -4.8), context: c)
        #expect(e.dimensionFields().first?.value == 5)
        #expect(e.previewDimensions().first?.label == "5 mm")
        let placed = tap(&e, SIMD2(30, -4.8), c)
        guard case .polyline(_, true)? = placed.first?.kind else { Issue.record("no outward offset: \(placed)"); return }
        #expect(e.isIdle && e.offset.chains.isEmpty)
    }

    @Test func toolInwardTooFarSaysWhy() throws {
        let s = sketch(.rectangle(anchor: .corner, position: .origin, width: 60, height: 30, angle: 0))
        let c = context(s)
        var e = SketchToolEngine(tool: .offset)
        _ = tap(&e, SIMD2(0.1, 10), c)
        e.hover(SIMD2(20, 16), context: c)  // 14 in: fine
        #expect(e.blocker == nil && !e.preview().isEmpty)
        e.hover(SIMD2(30, 15.2), context: c)  // 15 in: collapses
        #expect(e.blocker != nil && e.preview().isEmpty)
        #expect(e.hint(verb: "Click") == e.blocker)
        #expect(tap(&e, SIMD2(30, 15.2), c).isEmpty)
        #expect(!e.isIdle, "still picked, to try a smaller distance")
    }

    @Test func typedDistanceTakesThePointersSide() throws {
        let s = sketch(.circle(center: .origin, diameter: 20))
        let c = context(s)
        var e = SketchToolEngine(tool: .offset)
        e.preselectOffset([s.shapes[0].id])
        #expect(!e.isIdle)
        e.resolveOffset(in: s, using: ev)
        // No pointer yet: outward.
        let locked = e.lock(0, to: 2), zero = e.lock(0, to: 0)
        #expect(locked && !zero)
        e.hover(SIMD2(3, 0), context: c)  // inside
        let placed = e.placeTyped()
        #expect(placed.map(\.kind) == [.circle(center: .origin, diameter: 16)])
        // A negative distance takes the other side of the pointer.
        e.preselectOffset([s.shapes[0].id])
        e.hover(SIMD2(3, 0), context: c)
        let negative = e.lock(0, to: -2)
        #expect(negative)
        #expect(e.placeTyped().map(\.kind) == [.circle(center: .origin, diameter: 24)])
    }

    @Test func dragFromACurveOffsetsIt() throws {
        let s = sketch(.circle(center: .origin, diameter: 20))
        let c = context(s)
        var e = SketchToolEngine(tool: .offset)
        e.press(SIMD2(10, 0), context: c)
        e.drag(SIMD2(12, 0), context: c)
        #expect(e.offset.chains.count == 1)
        let placed = e.release(SIMD2(13.1, 0), context: c)
        #expect(placed.map(\.kind) == [.circle(center: .origin, diameter: 26)])
    }

    @Test func preselectionOffsetsEveryChain() throws {
        let s = sketch(
            .circle(center: .origin, diameter: 10),
            .circle(center: Point2Expr(30, 0), diameter: 10),
            .rectangle(anchor: .center, position: Point2Expr(15, 0), width: 60, height: 20, angle: 0))
        var e = SketchToolEngine(tool: .offset)
        e.preselectOffset([s.shapes[0].id, s.shapes[1].id])
        let c = context(s)
        e.hover(SIMD2(0, 7), context: c)  // 2 outside the first circle
        let placed = tap(&e, SIMD2(0, 7), c)
        #expect(placed.map(\.kind) == [.circle(center: .origin, diameter: 14), .circle(center: Point2Expr(30, 0), diameter: 14)])
    }

    // MARK: Profiles

    @Test func offsetRectangleRingExtrudes() async throws {
        let rect = SketchShape(.rectangle(anchor: .corner, position: .origin, width: 40, height: 20, angle: 0))
        let ring = try #require(Sketch(shapes: [rect]).offsetChain(containing: rect.id, using: ev)?.offset(by: 3).first)
        let sketchID = UUID(), extrudeID = UUID()
        var doc = Document()
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(Sketch(plane: .xy, shapes: [rect, SketchShape(ring)]))),
            // A point in the ring, between the rectangle and its offset.
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(sketch: sketchID, regions: [RegionRef(x: 20, y: -1.5)], distance: 5))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.sketches[sketchID]?.regions?.count == 2)
        #expect(model.status[extrudeID] == .ok)
        let volume = try #require(model.bodies.first).shape.volume
        let outer: Double = 46 * 26 - 4 * 9 + Double.pi * 9
        let ringArea = outer - 40 * 20
        #expect(abs(volume - ringArea * 5) < 0.05, "volume \(volume)")
    }
}
