import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Press Pull recompute")
struct PressPullRecomputeTests {
    let sketchID = UUID()
    let extrudeID = UUID()
    let pressPullID = UUID()

    /// 40 × 20 plate (width parameter) with a Ø8 hole, extruded 10 mm.
    func plateDocument() -> Document {
        var doc = Document()
        doc.parameters = [Parameter(name: "width", expression: "40"), Parameter(name: "lift", expression: "5")]
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

    func plate(width: Double, height: Double, holeRadius: Double = 4) -> Double {
        (width * 20 - .pi * holeRadius * holeRadius) * height
    }

    /// The pulled distance follows a parameter, and the top face is still found after the
    /// plate it sits on is widened upstream.
    @Test func parameterDrivesDistanceAndFaceSurvivesUpstreamEdit() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.surface == .plane && $0.normal.z > 0.99 })
        let ref = try #require(first.faceRef(body: body.ref, face: top))
        doc.features.append(Feature(id: pressPullID, name: "Press Pull 1", .pressPull(PressPull(body: body.ref, faces: [ref], distance: "lift"))))

        let pulled = await evaluator.evaluate(doc)
        #expect(pulled.status[pressPullID] == .ok)
        #expect(pulled.bodies.count == 1)
        #expect(abs(try #require(pulled.bodies.first).shape.volume - plate(width: 40, height: 15)) < 1e-3)
        #expect(pulled.references[pressPullID]?.count == 1)

        doc.parameters[1].expression = "-4"
        let pushed = await evaluator.evaluate(doc)
        #expect(pushed.status[pressPullID] == .ok)
        #expect(abs(try #require(pushed.bodies.first).shape.volume - plate(width: 40, height: 6)) < 1e-3)

        doc.parameters[1].expression = "8"
        doc.parameters[0].expression = "50"
        let wider = await evaluator.evaluate(doc)
        #expect(wider.status[pressPullID] == .ok)
        #expect(abs(try #require(wider.bodies.first).shape.volume - plate(width: 50, height: 18)) < 1e-3)
    }

    /// A hole's wall pulled outward (into the hole) narrows it.
    @Test func narrowsAHole() async throws {
        var doc = plateDocument()
        let evaluator = ModelEvaluator()
        let first = await evaluator.evaluate(doc)
        let body = try #require(first.bodies.first)
        let hole = try #require(body.shape.faceInfos.firstIndex { $0.surface == .cylinder })
        let ref = try #require(first.faceRef(body: body.ref, face: hole))
        doc.features.append(Feature(id: pressPullID, name: "Press Pull 1", .pressPull(PressPull(body: body.ref, faces: [ref], distance: 1))))
        let model = await evaluator.evaluate(doc)
        #expect(model.status[pressPullID] == .ok)
        #expect(abs(try #require(model.bodies.first).shape.volume - plate(width: 40, height: 10, holeRadius: 3)) < 1e-3)
    }

    @Test func failures() async throws {
        var doc = plateDocument()
        let body = BodyRef(extrudeID)
        doc.features.append(Feature(id: pressPullID, name: "Press Pull 1", .pressPull(PressPull(body: body, faces: [], distance: 2))))
        let evaluator = ModelEvaluator()
        #expect(await evaluator.evaluate(doc).error(for: pressPullID) == "Select at least one face")
        let nowhere = FaceRef(body: body, signature: FaceSignature(
            surface: .plane, centroid: Vec3(500, 500, 500), normal: .unitZ, area: 1, extent: Vec3(1, 1, 0)))
        doc.features[2].kind = .pressPull(PressPull(body: body, faces: [nowhere], distance: 2))
        let missing = await evaluator.evaluate(doc)
        #expect(missing.error(for: pressPullID)?.contains("can no longer be found") == true)
        #expect(missing.references[pressPullID] == [nil])
        // The body is left as it was.
        #expect(abs(try #require(missing.bodies.first).shape.volume - plate(width: 40, height: 10)) < 1e-3)
    }
}
