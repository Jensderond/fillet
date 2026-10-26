import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Hole feature")
struct HoleFeatureTests {
    let sketchID = UUID()
    let extrudeID = UUID()
    let holeID = UUID()

    /// A `width` × 20 block, `height` tall (both parameters), standing on the XY plane.
    func blockDocument() -> Document {
        var doc = Document()
        doc.parameters = [
            Parameter(name: "width", expression: "40"), Parameter(name: "height", expression: "10"),
            Parameter(name: "d", expression: "4"),
        ]
        let sketch = Sketch(plane: .xy, shapes: [
            SketchShape(.rectangle(anchor: .corner, position: .origin, width: "width", height: 20, angle: 0)),
        ])
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(sketch)),
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(
                sketch: sketchID, regions: [RegionRef(x: 1, y: 1)], distance: "height"))),
        ]
        return doc
    }

    /// The block's top face, referenced from its first evaluation.
    func topFace(_ model: EvaluatedModel) throws -> FaceRef {
        let body = try #require(model.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.normal.z > 0.99 })
        return try #require(model.faceRef(body: body.ref, face: top))
    }

    func volume(_ model: EvaluatedModel) throws -> Double { try #require(model.bodies.first).shape.volume }

    /// The hole walls (cylinders) of the evaluated block.
    func walls(_ model: EvaluatedModel) throws -> [FaceInfo] {
        try #require(model.bodies.first).shape.faceInfos.filter { $0.surface == .cylinder }
    }

    @Test func parameterDrivesTheDiameter() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let face = try topFace(await ev.evaluate(doc))
        doc.features.append(Feature(id: holeID, name: "Hole 1", .hole(Hole(
            face: face, centers: [Point2Expr(-10, 0), Point2Expr(10, 0)], diameter: "d", extent: .throughAll))))

        let drilled = await ev.evaluate(doc)
        #expect(drilled.status[holeID] == .ok)
        #expect(abs(try volume(drilled) - (8000 - 2 * Double.pi * 4 * 10)) < 1e-3)
        #expect(drilled.references[holeID]?.first??.index != nil)

        doc.parameters[2].expression = "6"
        let wider = await ev.evaluate(doc)
        #expect(wider.status[holeID] == .ok)
        #expect(abs(try volume(wider) - (8000 - 2 * Double.pi * 9 * 10)) < 1e-3)
    }

    @Test func holesFollowTheFaceWhenAnEarlierStepMovesIt() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let face = try topFace(await ev.evaluate(doc))
        // One hole at the face centre, 5 mm deep with a flat bottom.
        doc.features.append(Feature(id: holeID, name: "Hole 1", .hole(Hole(
            face: face, centers: [.origin], diameter: 4, depth: 5, tipAngle: 0))))
        let first = await ev.evaluate(doc)
        let wall = try #require(try walls(first).first)
        #expect(abs(wall.boundsMax.z - 10) < 1e-6 && abs(wall.boundsMin.z - 5) < 1e-6)
        #expect(abs(wall.centroid.x - 20) < 1e-6)

        // Taller and wider: the top face rises to z = 15 and its centre moves to x = 25.
        doc.parameters[0].expression = "50"
        doc.parameters[1].expression = "15"
        let moved = await ev.evaluate(doc)
        #expect(moved.status[holeID] == .ok)
        let after = try #require(try walls(moved).first)
        #expect(abs(after.boundsMax.z - 15) < 1e-6 && abs(after.boundsMin.z - 10) < 1e-6)
        #expect(abs(after.centroid.x - 25) < 1e-6)
        #expect(abs(try volume(moved) - (50 * 20 * 15 - Double.pi * 4 * 5)) < 1e-3)
    }

    @Test func counterboreAndCountersink() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let face = try topFace(await ev.evaluate(doc))
        doc.features.append(Feature(id: holeID, name: "Hole 1", .hole(Hole(
            face: face, centers: [.origin], holeType: .counterbore, diameter: 4, extent: .throughAll,
            counterboreDiameter: 8, counterboreDepth: 3))))
        let cbore = await ev.evaluate(doc)
        #expect(cbore.status[holeID] == .ok)
        let cboreRemoved: Double = Double.pi * (16 * 3 + 4 * 7)
        #expect(abs(try volume(cbore) - (8000 - cboreRemoved)) < 1e-3)

        doc.features[2].kind = .hole(Hole(face: face, centers: [.origin], holeType: .countersink, diameter: 4,
                                          extent: .throughAll, countersinkDiameter: 8, countersinkAngle: 90))
        let csk = await ev.evaluate(doc)
        #expect(csk.status[holeID] == .ok)
        // A 2 mm deep frustum from r = 4 to r = 2, then 8 mm of r = 2.
        let cskRemoved: Double = Double.pi * (2.0 / 3 * (16 + 8 + 4) + 4 * 8)
        #expect(abs(try volume(csk) - (8000 - cskRemoved)) < 1e-3)
    }

    @Test func explainsWhatIsMissing() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let face = try topFace(await ev.evaluate(doc))
        doc.features.append(Feature(id: holeID, name: "Hole 1", .hole(Hole(face: nil))))
        #expect(await ev.evaluate(doc).error(for: holeID) == "Pick a flat face to drill into")
        doc.features[2].kind = .hole(Hole(face: face))
        #expect(await ev.evaluate(doc).error(for: holeID) == "Place at least one hole on the face")
        doc.features[2].kind = .hole(Hole(face: face, centers: [.origin], depth: 0))
        #expect(await ev.evaluate(doc).error(for: holeID) == "Depth must be greater than zero")
    }

    @Test func jsonRoundTripAndDefaults() throws {
        let face = FaceRef(body: BodyRef(extrudeID), signature: FaceSignature(
            surface: .plane, centroid: Vec3(20, 10, 10), normal: .unitZ, area: 800, extent: Vec3(40, 20, 0)))
        let hole = Feature(id: holeID, name: "Hole 1", .hole(Hole(
            face: face, centers: [Point2Expr(1, 2), Point2Expr("width/4", -3)], holeType: .countersink, diameter: "d",
            extent: .throughAll, countersinkAngle: 82)))
        let data = try JSONEncoder().encode(hole)
        #expect(try JSONDecoder().decode(Feature.self, from: data) == hole)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kind = try #require(json["kind"] as? [String: Any])
        #expect(kind["type"] as? String == "hole")
        #expect(kind["extent"] as? String == "throughAll")
        #expect(kind["countersinkAngle"] as? String == "82")

        // Only the type is needed; everything else falls back to the defaults.
        let minimal = try JSONDecoder().decode(FeatureKind.self, from: Data(#"{"type": "hole"}"#.utf8))
        #expect(minimal == .hole(Hole(face: nil)))
        guard case .hole(let h) = minimal else { return }
        #expect(h.diameter == 5 && h.depth == 10 && h.tipAngle == 118 && h.holeType == .simple && h.extent == .distance)
    }
}
