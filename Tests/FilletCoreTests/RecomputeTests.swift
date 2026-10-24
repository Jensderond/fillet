import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Recompute")
struct RecomputeTests {
    let sketchID = UUID()
    let extrudeID = UUID()

    /// 40×20 plate (width parameter) with a Ø8 hole, extruded 10 mm.
    func plateDocument(width: String = "40") -> Document {
        var doc = Document()
        doc.parameters = [Parameter(name: "width", expression: Expr(stringLiteral: width))]
        let sketch = Sketch(plane: .xy, shapes: [
            SketchShape(.rectangle(anchor: .corner, position: .origin, width: "width", height: 20, angle: 0)),
            SketchShape(.circle(center: Point2Expr(10, 10), diameter: 8)),
        ])
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(sketch)),
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(
                sketch: sketchID, regions: [RegionRef(x: 1, y: 1)], distance: 10))),
        ]
        return doc
    }

    @Test func extrudePlateWithHole() async throws {
        let model = await ModelEvaluator().evaluate(plateDocument())
        #expect(model.status[sketchID] == .ok)
        #expect(model.status[extrudeID] == .ok)
        #expect(model.bodies.count == 1)
        let body = try #require(model.bodies.first)
        #expect(body.name == "Body 1")
        let plate: Double = 8000 - Double.pi * 160
        #expect(abs(body.shape.volume - plate) < 1e-3)
        let sketch = try #require(model.sketches[sketchID])
        #expect(sketch.regions?.count == 2)
        #expect(sketch.regionFills.count == 2)
        #expect(sketch.curves.count == 2)
        let mesh = try #require(model.meshes[body.ref])
        #expect(mesh.triangleCount > 0)
        #expect(mesh.edges.count == body.shape.edgeCount)
    }

    @Test func filletSurvivesParameterChange() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        // Vertical edge at x = 40, y = 0.
        let edgeIndex = try #require(body.shape.edgeInfos.firstIndex {
            $0.curve == .line && abs($0.mid.x - 40) < 1e-6 && abs($0.mid.y) < 1e-6 && abs($0.tangentAtMid.z) > 0.99
        })
        let edgeRef = try #require(first.edgeRef(body: body.ref, edge: edgeIndex))
        let filletID = UUID()
        doc.features.append(Feature(id: filletID, name: "Fillet 1", .fillet(EdgeFeature(body: body.ref, edges: [edgeRef], size: 3))))

        let filleted = await evaluator.evaluate(doc)
        #expect(filleted.status[filletID] == .ok)
        let removed: Double = (1 - Double.pi / 4) * 9 * 10
        let base: Double = 40 * 20 * 10 - Double.pi * 16 * 10
        #expect(abs(try #require(filleted.bodies.first).shape.volume - (base - removed)) < 1e-3)

        // Widen the plate: the edge moves to x = 50 but is still found.
        doc.parameters[0].expression = "50"
        let wider = await evaluator.evaluate(doc)
        #expect(wider.status[filletID] == .ok)
        let wideBase: Double = 50 * 20 * 10 - Double.pi * 16 * 10
        #expect(abs(try #require(wider.bodies.first).shape.volume - (wideBase - removed)) < 1e-3)
    }

    /// The edges a fillet reports as resolved are the pre-fillet edges the kernel rounds: after the
    /// plate widens they move with it, they match resolving against the body before the fillet,
    /// and a fillet that then fails still reports them.
    @Test func filletRecordsResolvedEdges() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        // The two vertical edges on the right-hand side, at x = 40.
        let picked = body.shape.edgeInfos.indices.filter { i in
            let e = body.shape.edgeInfos[i]
            return e.curve == .line && abs(e.mid.x - 40) < 1e-6 && abs(e.tangentAtMid.z) > 0.99
        }
        #expect(picked.count == 2)
        let refs = try picked.map { try #require(first.edgeRef(body: body.ref, edge: $0)) }
        let filletID = UUID()
        doc.features.append(Feature(id: filletID, name: "Fillet 1", .fillet(EdgeFeature(body: body.ref, edges: refs, size: 3))))

        doc.parameters[0].expression = "50"
        let wider = await evaluator.evaluate(doc, before: filletID)
        #expect(wider.status[filletID] == .ok)
        let resolved = try #require(wider.resolvedEdges[filletID])
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { abs($0.mid.x - 50) < 1e-6 && abs($0.tangentAtMid.z) > 0.99 && abs($0.length - 10) < 1e-6 })
        #expect(Set(resolved.map { $0.mid.y.rounded() }) == [0, 20])
        // Same edges as resolving against the body before the fillet.
        let before = try #require(wider.bodiesBefore?.first?.shape)
        let direct = refs.compactMap { ReferenceResolver.resolve($0.signature, in: before.edgeInfos) }.map { before.edgeInfos[$0] }
        #expect(Set(direct) == Set(resolved))

        // A radius the plate can't take: the step fails, but still reports what it tried to round.
        if case .fillet(var f) = doc.features[2].kind {
            f.size = 40
            doc.features[2].kind = .fillet(f)
        }
        let failed = await evaluator.evaluate(doc)
        #expect(failed.error(for: filletID) != nil)
        #expect(Set(try #require(failed.resolvedEdges[filletID])) == Set(resolved))
    }

    @Test func sketchOnFaceAndCut() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.surface == .plane && $0.normal.z > 0.99 })
        let topRef = try #require(first.faceRef(body: body.ref, face: top))
        let fallback = try #require(body.shape.facePlane(top))
        let topPlane = try #require(first.plane(of: topRef))
        // A Ø6 pocket, 4 mm deep, centred at world (30, 10) on the top face.
        let centre = topPlane.project(Vec3(30, 10, 10))
        let pocketSketch = UUID(), pocket = UUID()
        doc.features += [
            Feature(id: pocketSketch, name: "Sketch 2", .sketch(Sketch(
                plane: .face(topRef, fallback: fallback),
                shapes: [SketchShape(.circle(center: Point2Expr(centre), diameter: 6))]))),
            Feature(id: pocket, name: "Pocket", .extrude(Extrude(
                sketch: pocketSketch, regions: [RegionRef(centre)], distance: -4, operation: .cut))),
        ]
        let model = await evaluator.evaluate(doc)
        #expect(model.status[pocket] == .ok)
        let hole: Double = Double.pi * 16 * 10
        let pocketVolume: Double = Double.pi * 9 * 4
        let expected: Double = 8000 - hole - pocketVolume
        #expect(abs(try #require(model.bodies.first).shape.volume - expected) < 1e-3)
    }

    @Test func failingFeatureDoesNotStopLaterFeatures() async throws {
        var doc = plateDocument()
        let first = await ModelEvaluator().evaluate(doc)
        let body = try #require(first.bodies.first)
        let edge = try #require(first.edgeRef(body: body.ref, edge: 0))
        let badFillet = UUID(), box = UUID()
        doc.features += [
            Feature(id: badFillet, name: "Fillet", .fillet(EdgeFeature(body: body.ref, edges: [edge], size: 500))),
            Feature(id: box, name: "Box", .primitive(Primitive(
                kind: .box, position: Point2Expr(100, 0), dimensions: [10, 10, 10]))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.error(for: badFillet) != nil)
        #expect(model.status[box] == .ok)
        #expect(model.bodies.count == 2)
    }

    @Test func rollbackAndSuppression() async throws {
        var doc = plateDocument()
        doc.rollbackIndex = 1
        var model = await ModelEvaluator().evaluate(doc)
        #expect(model.bodies.isEmpty)
        #expect(model.status[extrudeID] == .inactive)
        doc.rollbackIndex = nil
        doc.features[1].suppressed = true
        model = await ModelEvaluator().evaluate(doc)
        #expect(model.bodies.isEmpty)
    }

    @Test func cacheReusesUnchangedPrefix() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let a = await evaluator.evaluate(doc)
        doc.features.append(Feature(name: "Box", .primitive(Primitive(
            kind: .box, position: Point2Expr(100, 0), dimensions: [10, 10, 10]))))
        let b = await evaluator.evaluate(doc)
        // The plate body object is reused, not rebuilt.
        #expect(try #require(a.bodies.first).shape === (try #require(b.bodies.first).shape))
        #expect(b.bodies.count == 2)
    }

    @Test func revolveAroundConstructionLine() async throws {
        var doc = Document()
        let s = UUID(), axisLine = UUID(), r = UUID()
        doc.features = [
            Feature(id: s, name: "Sketch", .sketch(Sketch(plane: .standard(.xz, offset: 0), shapes: [
                SketchShape(.rectangle(anchor: .corner, position: Point2Expr(5, 0), width: 5, height: 10, angle: 0)),
                SketchShape(id: axisLine, construction: true, .line(a: Point2Expr(0, 0), b: Point2Expr(0, 10))),
            ]))),
            Feature(id: r, name: "Revolve", .revolve(Revolve(
                sketch: s, regions: [RegionRef(x: 7, y: 5)], axis: .sketchLine(axisLine)))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[r] == .ok)
        let tube: Double = Double.pi * 75 * 10
        #expect(abs(try #require(model.bodies.first).shape.volume - tube) < 1e-3)
    }

    @Test func mirrorPatternCombineMoveAndLayFlat() async throws {
        var doc = Document()
        let a = UUID(), b = UUID(), mirror = UUID(), pattern = UUID(), combine = UUID(), move = UUID(), flat = UUID()
        doc.features = [
            Feature(id: a, name: "A", .primitive(Primitive(kind: .box, position: Point2Expr(10, 0), dimensions: [4, 4, 4]))),
            Feature(id: b, name: "B", .primitive(Primitive(kind: .cylinder, position: Point2Expr(0, 30), dimensions: [6, 3]))),
            Feature(id: mirror, name: "Mirror", .mirror(Mirror(bodies: [BodyRef(a)], plane: .standard(.yz, offset: 0)))),
            Feature(id: pattern, name: "Pattern", .pattern(Pattern(
                bodies: [BodyRef(b)], layout: .linear(direction: .x, count: 3, spacing: 10)))),
            Feature(id: combine, name: "Combine", .combine(Combine(target: BodyRef(a), tools: [BodyRef(b)]))),
            Feature(id: move, name: "Move", .move(Move(bodies: [BodyRef(a)], translation: Vec3Expr(0, 0, 5)))),
        ]
        let evaluator = ModelEvaluator()
        var model = await evaluator.evaluate(doc)
        for f in doc.features { #expect(model.status[f.id] == .ok, "\(f.name): \(String(describing: model.status[f.id]))") }
        #expect(model.bodies.count == 1)
        let body = try #require(model.bodies.first)
        let volume: Double = 2 * 64.0 + 3 * Double.pi * 9 * 3
        #expect(abs(body.shape.volume - volume) < 1e-3)
        #expect(abs((body.shape.bounds?.min.z ?? 0) - 5) < 1e-6)

        // Lay flat on a cylinder's flat cap, which points down: just drops to z = 0.
        let bottom = try #require(body.shape.faceInfos.firstIndex { $0.surface == .plane && $0.normal.z < -0.99 })
        let faceRef = try #require(model.faceRef(body: body.ref, face: bottom))
        doc.features.append(Feature(id: flat, name: "Lay flat", .layFlat(LayFlat(body: body.ref, face: faceRef))))
        model = await evaluator.evaluate(doc)
        #expect(model.status[flat] == .ok)
        #expect(abs(try #require(model.bodies.first?.shape.bounds).min.z) < 1e-6)
    }

    @Test func layFlatRotatesSideFaceDown() async throws {
        var doc = Document()
        let box = UUID()
        doc.features = [Feature(id: box, name: "Box", .primitive(Primitive(kind: .box, dimensions: [10, 20, 30])))]
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        let side = try #require(body.shape.faceInfos.firstIndex { $0.normal.x > 0.99 })
        doc.features.append(Feature(name: "Flat", .layFlat(LayFlat(body: body.ref, face: try #require(first.faceRef(body: body.ref, face: side))))))
        let model = await evaluator.evaluate(doc)
        let b = try #require(model.bodies.first?.shape.bounds)
        #expect(abs(b.min.z) < 1e-6)
        #expect(abs((b.max.z - b.min.z) - 10) < 1e-6)  // the 10 mm width is now the height
    }
}

@Suite("Parameter rename")
struct ParameterRenameTests {
    @Test func renamesReferencesEverywhere() throws {
        var doc = Document()
        doc.parameters = [Parameter(name: "w", expression: 40), Parameter(name: "half", expression: "w / 2 + w2")]
        let s = UUID()
        doc.features = [
            Feature(id: s, name: "w", .sketch(Sketch(shapes: [SketchShape(.circle(center: Point2Expr("w", 0), diameter: "w*2"))]))),
        ]
        doc.renameParameterReferences(from: "w", to: "width")
        #expect(doc.parameters[1].expression == "width / 2 + w2")
        #expect(doc.features[0].name == "w")
        guard case .sketch(let sketch) = doc.features[0].kind, case .circle(let c, let d) = sketch.shapes[0].kind else {
            Issue.record(); return
        }
        #expect(c.x == "width")
        #expect(d == "width*2")
    }
}
