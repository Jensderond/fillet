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
        // The body before the fillet is meshed too, for the viewport to test those edges' depth
        // against; editing again (a new radius) finds it cached.
        let meshBefore = try #require(wider.meshesBefore[body.ref])
        #expect(!meshBefore.indices.isEmpty)
        #expect(meshBefore.indices != wider.meshes[body.ref]?.indices)  // not the rounded result
        if case .fillet(var f) = doc.features[2].kind {
            f.size = 2
            doc.features[2].kind = .fillet(f)
        }
        let smaller = await evaluator.evaluate(doc, before: filletID)
        #expect(smaller.meshesBefore[body.ref] != nil)
        #expect(await evaluator.lastTessellatedCount == 1)  // only the new result
        #expect(await evaluator.evaluate(doc).meshesBefore.isEmpty)

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

    /// An agent's step is previewed, then committed (or refused) on the same evaluator.
    @Test func previewKeepsTheCacheAndCommitsForFree() async throws {
        let a = UUID(), b = UUID(), cut = UUID(), extra = UUID()
        var doc = Document()
        doc.features = [
            Feature(id: a, name: "A", .primitive(Primitive(kind: .box, dimensions: [20, 20, 10]))),
            Feature(id: b, name: "B", .primitive(Primitive(kind: .cylinder, dimensions: [6, 10]))),
            Feature(id: cut, name: "Cut", .combine(Combine(target: BodyRef(a), tools: [BodyRef(b)], operation: .cut))),
        ]
        let ev = ModelEvaluator(recordsTimings: true)
        func recomputed() async -> [UUID] { await ev.lastStepTimings.map(\.feature) }
        _ = await ev.evaluate(doc)
        #expect(await recomputed() == [a, b, cut])

        // A new step: only it is computed, and committing it computes nothing.
        var added = doc
        added.features.append(Feature(id: extra, name: "Extra", .primitive(Primitive(kind: .sphere, dimensions: [4]))))
        let previewed = await ev.preview(added)
        #expect(await recomputed() == [extra])
        let committed = await ev.evaluate(added, before: extra)
        #expect(await recomputed() == [])
        #expect(committed.bodies.map(\.ref) == previewed.bodies.map(\.ref))
        #expect(committed.bodies.map { ObjectIdentifier($0.shape) } == previewed.bodies.map { ObjectIdentifier($0.shape) })
        #expect(committed.bodiesBefore?.map(\.ref) == [BodyRef(a)])
        #expect(Set(committed.meshes.keys) == Set(previewed.meshes.keys) && committed.meshes.count == 2)

        // A refused edit of the first step leaves the evaluated document cached.
        var edited = added
        edited.features[0] = Feature(id: a, name: "A", .primitive(Primitive(kind: .box, dimensions: [30, 20, 10])))
        _ = await ev.preview(edited)
        #expect(await recomputed() == [a, b, cut, extra])  // keyed on the whole prefix
        _ = await ev.evaluate(added)
        #expect(await recomputed() == [])
        // Going back to an earlier document still reuses its prefix.
        _ = await ev.evaluate(doc, before: cut)
        #expect(await recomputed() == [])
    }

    /// Undoing a step brings back bodies the evaluate before last meshed: no re-meshing.
    @Test func undoReusesTheMeshesOfTheStepBefore() async throws {
        let a = UUID(), b = UUID(), cut = UUID()
        var doc = Document()
        doc.features = [
            Feature(id: a, name: "A", .primitive(Primitive(kind: .box, dimensions: [20, 20, 10]))),
            Feature(id: b, name: "B", .primitive(Primitive(kind: .cylinder, dimensions: [6, 10]))),
        ]
        let ev = ModelEvaluator()
        let before = await ev.evaluate(doc)
        #expect(await ev.lastTessellatedCount == 2)
        var added = doc
        added.features.append(Feature(id: cut, name: "Cut", .combine(Combine(target: BodyRef(a), tools: [BodyRef(b)], operation: .cut))))
        _ = await ev.evaluate(added)
        #expect(await ev.lastTessellatedCount == 1)  // the cut body
        let undone = await ev.evaluate(doc)
        #expect(await ev.lastTessellatedCount == 0)
        for body in before.bodies {
            #expect(undone.meshes[body.ref]?.positions == before.meshes[body.ref]?.positions)
            #expect(undone.meshes[body.ref]?.indices == before.meshes[body.ref]?.indices)
        }
    }
}

@Suite("Feature pattern")
struct FeaturePatternTests {
    let box = UUID(), pattern = UUID()

    /// A 60×20×10 box centred on the origin (x −30…30, y −10…10, z 0…10).
    func boxDocument() -> Document {
        var doc = Document()
        doc.features = [Feature(id: box, name: "Box", .primitive(Primitive(kind: .box, dimensions: [60, 20, 10])))]
        return doc
    }

    func linear(count: Expr, spacing: Expr) -> PatternLayout { .linear(direction: .x, count: count, spacing: spacing) }

    @Test func linearPatternRepeatsACut() async throws {
        var doc = boxDocument()
        let sketch = UUID(), cut = UUID()
        doc.features += [
            Feature(id: sketch, name: "Sketch", .sketch(Sketch(plane: .xy, shapes: [
                SketchShape(.circle(center: Point2Expr(-20, 0), diameter: 6)),
            ]))),
            Feature(id: cut, name: "Cut", .extrude(Extrude(
                sketch: sketch, regions: [RegionRef(x: -20, y: 0)], distance: 30, symmetric: true, operation: .cut))),
            Feature(id: pattern, name: "Pattern", .pattern(Pattern(features: [cut], layout: linear(count: 3, spacing: 20)))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[pattern] == .ok, "\(String(describing: model.status[pattern]))")
        #expect(model.bodies.count == 1)
        let body = try #require(model.bodies.first)
        #expect(abs(body.shape.volume - (12000 - 3 * Double.pi * 9 * 10)) < 1e-3)
        #expect(body.lastFeature == pattern)
    }

    /// Holes in a side face, patterned around Z: each copy drills along its own turned direction.
    @Test func circularPatternRepeatsAHole() async throws {
        var doc = Document()
        let block = UUID(), hole = UUID()
        // 40×40×40, x and y −20…20.
        doc.features = [Feature(id: block, name: "Block", .primitive(Primitive(kind: .box, dimensions: [40, 40, 40])))]
        let ev = ModelEvaluator()
        let first = await ev.evaluate(doc)
        let body = try #require(first.bodies.first)
        let side = try #require(body.shape.faceInfos.firstIndex { $0.normal.x > 0.99 })
        let face = try #require(first.faceRef(body: body.ref, face: side))
        let plane = try #require(body.shape.facePlane(side))
        doc.features += [
            Feature(id: hole, name: "Hole", .hole(Hole(
                face: face, centers: [Point2Expr(plane.project(Vec3(20, 0, 20)))], diameter: 4, depth: 5, tipAngle: 0))),
            Feature(id: pattern, name: "Pattern", .pattern(Pattern(
                features: [hole], layout: .circular(axis: .z, count: 4, angle: 360)))),
        ]
        let model = await ev.evaluate(doc)
        #expect(model.status[hole] == .ok)
        #expect(model.status[pattern] == .ok, "\(String(describing: model.status[pattern]))")
        let drilled = try #require(model.bodies.first)
        #expect(abs(drilled.shape.volume - (64000 - 4 * Double.pi * 4 * 5)) < 1e-3)
        // One hole wall per side.
        let walls = drilled.shape.faceInfos.filter { $0.surface == .cylinder }
        #expect(walls.count == 4)
        #expect(drilled.lastFeature == pattern)
    }

    @Test func linearPatternRepeatsAJoin() async throws {
        var doc = boxDocument()
        let boss = UUID()
        doc.features += [
            Feature(id: boss, name: "Boss", .primitive(Primitive(
                kind: .cylinder, plane: .standard(.xy, offset: 10), position: Point2Expr(-20, 0), dimensions: [6, 5],
                operation: .join))),
            Feature(id: pattern, name: "Pattern", .pattern(Pattern(features: [boss], layout: linear(count: 3, spacing: 20)))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[pattern] == .ok, "\(String(describing: model.status[pattern]))")
        #expect(model.bodies.count == 1)
        #expect(abs(try #require(model.bodies.first).shape.volume - (12000 + 3 * Double.pi * 9 * 5)) < 1e-3)
    }

    @Test func newBodyCopiesBecomeBodies() async throws {
        var doc = Document()
        let ball = UUID()
        doc.features = [
            Feature(id: ball, name: "Ball", .primitive(Primitive(kind: .sphere, dimensions: [4]))),
            Feature(id: pattern, name: "Pattern", .pattern(Pattern(features: [ball], layout: linear(count: 4, spacing: 10)))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[pattern] == .ok)
        #expect(model.bodies.count == 4)
        #expect(Set(model.bodies.map(\.ref)).count == 4)
        #expect(model.bodies.allSatisfy { abs($0.shape.volume - 4 / 3 * Double.pi * 8) < 1e-3 })
        let xs = model.bodies.compactMap { $0.shape.bounds.map { (($0.min.x + $0.max.x) / 2).rounded() } }
        #expect(xs == [0, 10, 20, 30])
    }

    /// A new body and a cut through it, picked either way round: the copies run in timeline
    /// order, so each copied box gets its copied hole.
    @Test func stepsRepeatInTimelineOrder() async throws {
        let cut = UUID()
        for picked in [[box, cut], [cut, box]] {
            var doc = boxDocument()
            doc.features += [
                Feature(id: cut, name: "Cut", .primitive(Primitive(
                    kind: .cylinder, position: Point2Expr(-20, 0), dimensions: [6, 12], operation: .cut))),
                Feature(id: pattern, name: "Pattern", .pattern(Pattern(features: picked, layout: linear(count: 2, spacing: 70)))),
            ]
            let model = await ModelEvaluator().evaluate(doc)
            #expect(model.status[pattern] == .ok, "\(String(describing: model.status[pattern]))")
            #expect(model.bodies.count == 2)
            #expect(model.bodies.allSatisfy { abs($0.shape.volume - (12000 - Double.pi * 9 * 10)) < 1e-3 })
        }
    }

    @Test func missingOrUnpatternableStepsFail() async throws {
        var doc = boxDocument()
        doc.features.append(Feature(id: pattern, name: "Pattern", .pattern(Pattern(features: [], layout: linear(count: 2, spacing: 70)))))
        let ev = ModelEvaluator()
        #expect(await ev.evaluate(doc).error(for: pattern) == "Pick at least one step in the timeline")

        doc.features[1].kind = .pattern(Pattern(features: [box], layout: linear(count: 2, spacing: 70)))
        var model = await ev.evaluate(doc)
        #expect(model.status[pattern] == .ok)
        #expect(model.bodies.count == 2)

        // The picked step suppressed: the pattern says so instead of doing nothing.
        doc.features[0].suppressed = true
        model = await ev.evaluate(doc)
        #expect(model.error(for: pattern)?.contains("suppressed") == true)
        #expect(model.bodies.isEmpty)

        // A step that can't be patterned.
        doc.features[0].suppressed = false
        let sketch = UUID()
        doc.features.insert(Feature(id: sketch, name: "Sketch", .sketch(Sketch(plane: .xy, shapes: []))), at: 1)
        doc.features[2].kind = .pattern(Pattern(features: [sketch], layout: linear(count: 2, spacing: 70)))
        model = await ev.evaluate(doc)
        #expect(model.error(for: pattern)?.hasPrefix("Only extrudes") == true)
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
