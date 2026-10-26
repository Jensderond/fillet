import FilletKernel
import Foundation
import Testing

@testable import FilletCore

/// A small design: sketch with a rectangle → extrude → fillet of one edge.
func sampleDocument() -> Document {
    let sketchID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let extrudeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let filletID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let rectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let body = BodyRef(extrudeID)
    let edge = EdgeRef(
        body: body,
        signature: EdgeSignature(
            curve: .line, start: Vec3(0, 0, 10), mid: Vec3(20, 0, 10), end: Vec3(40, 0, 10), tangent: .unitX, length: 40,
            radius: 0))
    return Document(
        name: "Holder",
        parameters: [Parameter(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, name: "width", expression: "40 mm")],
        features: [
            Feature(
                id: sketchID, name: "Sketch 1",
                .sketch(
                    Sketch(
                        plane: .xy,
                        shapes: [
                            SketchShape(
                                id: rectID,
                                .rectangle(anchor: .corner, position: .origin, width: "width", height: 20, angle: 0))
                        ]))),
            Feature(
                id: extrudeID, name: "Extrude 1",
                .extrude(Extrude(sketch: sketchID, regions: [RegionRef(x: 20, y: 10)], distance: 10))),
            Feature(id: filletID, name: "Fillet 1", .fillet(EdgeFeature(body: body, edges: [edge], size: 2))),
        ])
}

/// One of every feature kind, for round-trip coverage.
func everyFeatureKind() -> [FeatureKind] {
    let b = BodyRef(UUID())
    let face = FaceRef(
        body: b,
        signature: FaceSignature(surface: .plane, centroid: Vec3(1, 2, 3), normal: .unitZ, area: 4, extent: Vec3(2, 2, 0)))
    let edge = EdgeRef(
        body: b,
        signature: EdgeSignature(curve: .circle, start: .zero, mid: .unitX, end: .zero, tangent: .unitY, length: 6.28, radius: 1))
    let line = UUID()
    return [
        .sketch(
            Sketch(
                plane: .face(face, fallback: .xy),
                shapes: [
                    SketchShape(id: line, construction: true, .line(a: .origin, b: Point2Expr(0, 10))),
                    SketchShape(.polyline(vertices: [PolylineVertex(0, 0), PolylineVertex(5, 0, bulge: "1 mm"), PolylineVertex(5, 5)], closed: true)),
                    SketchShape(.rectangle(anchor: .center, position: Point2Expr(1, 1), width: 4, height: 3, angle: "15 deg")),
                    SketchShape(.circle(center: .origin, diameter: 6)),
                    SketchShape(.arc(start: Point2Expr(1, 0), through: Point2Expr(0, 1), end: Point2Expr(-1, 0))),
                    SketchShape(.polygon(center: .origin, sides: 6, radius: 3, inscribed: false, angle: 0)),
                    SketchShape(.slot(a: .origin, b: Point2Expr(10, 0), width: 3)),
                    SketchShape(.spline(points: [.origin, Point2Expr(1, 2), Point2Expr(3, 1)])),
                    SketchShape(.point(Point2Expr(2, 2))),
                ])),
        .extrude(Extrude(sketch: UUID(), regions: [RegionRef(x: 1, y: 2)], distance: "h", back: 3, symmetric: true, taper: 2, operation: .cut, targets: [b])),
        .revolve(Revolve(sketch: UUID(), regions: [], axis: .sketchLine(line), angle: 180, operation: .join, targets: [b])),
        .revolve(Revolve(sketch: UUID(), regions: [], axis: .y)),
        .fillet(EdgeFeature(body: b, edges: [edge], size: 1)),
        .chamfer(EdgeFeature(body: b, edges: [edge], size: "0.5")),
        .shell(Shell(body: b, removeFaces: [face], thickness: 1.2)),
        .primitive(Primitive(kind: .cylinder, plane: .standard(.xz, offset: "5"), position: Point2Expr(1, 1), dimensions: [10, 20])),
        .combine(Combine(target: b, tools: [BodyRef(UUID())], operation: .intersect, keepTools: true)),
        .move(Move(bodies: [b], translation: Vec3Expr(1, 2, 3), rotationAxis: .edge(edge), rotationAngle: 90)),
        .mirror(Mirror(bodies: [b], plane: .standard(.yz, offset: 0), merge: false)),
        .pattern(Pattern(bodies: [b], layout: .linear(direction: .x, count: 3, spacing: 10))),
        .pattern(Pattern(bodies: [b], layout: .circular(axis: .z, count: 6, angle: 360))),
        .pattern(Pattern(features: [UUID(), UUID()], layout: .linear(direction: .edge(edge), count: "n", spacing: 5))),
        .importedSTEP(ImportedSTEP(name: "bracket.step", brep: "DBRep_DrawableShape ...")),
        .layFlat(LayFlat(body: b, face: face)),
        .hole(Hole(face: face, centers: [Point2Expr(1, 2), Point2Expr("w/2", 0)], diameter: "d", extent: .throughAll)),
        .hole(Hole(face: face, holeType: .counterbore, tipAngle: 0, counterboreDiameter: 8, counterboreDepth: "2 mm")),
        .hole(Hole(face: nil, holeType: .countersink, countersinkAngle: 82)),
        .pressPull(PressPull(body: b, faces: [face], distance: "-lift")),
    ]
}

@Suite("Document coding")
struct DocumentCodingTests {
    @Test func newDocumentDefaults() {
        let d = Document()
        #expect(d.name == nil)
        #expect(d.printer == "bambu-a1-mini")
        #expect(d.printerPreset == .bambuA1Mini)
        #expect(d.parameters.isEmpty && d.features.isEmpty)
        #expect(d.rollbackIndex == nil)
        #expect(d.formatVersion == Document.currentFormatVersion)
        #expect(d.units == .mm)
    }

    @Test func roundTripsEveryFeatureKind() throws {
        var doc = Document(name: "All")
        for (i, k) in everyFeatureKind().enumerated() { doc.features.append(Feature(name: "F\(i)", k)) }
        doc.printer = PrinterPreset.customID
        doc.customBedSize = SIMD3(100, 120, 90)
        let data = try doc.encoded()
        let back = try Document(data: data)
        #expect(back == doc)
        #expect(back.printerPreset.bedSize == SIMD3(100, 120, 90))
        // Encoding is stable.
        #expect(try back.encoded() == data)
    }

    @Test func jsonIsCleanAndTagged() throws {
        let data = try sampleDocument().encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""type" : "extrude""#))
        #expect(json.contains(#""type" : "rectangle""#))
        #expect(json.contains(#""type" : "standard""#))
        #expect(json.contains(#""width" : "width""#))
        #expect(!json.contains("_0"))
        #expect(json.contains(#""formatVersion" : 1"#))
        // Sorted keys: "features" before "formatVersion" before "name".
        let f = try #require(json.range(of: "\"features\""))
        let v = try #require(json.range(of: "\"formatVersion\""))
        #expect(f.lowerBound < v.lowerBound)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        let kind = try #require(features[1]["kind"] as? [String: Any])
        #expect(kind["type"] as? String == "extrude")
        #expect(kind["distance"] as? String == "10")
        #expect(kind["operation"] as? String == "newBody")
        #expect(kind["sketch"] as? String == "00000000-0000-0000-0000-000000000001")
    }

    @Test func toleratesUnknownFieldsAndMissingOptionalOnes() throws {
        let json = """
            {
              "formatVersion": 1,
              "futureSetting": {"nested": [1, 2, 3]},
              "features": [
                {
                  "id": "00000000-0000-0000-0000-000000000001",
                  "kind": {
                    "type": "sketch",
                    "plane": {"type": "standard", "plane": "xz"},
                    "shapes": [
                      {"id": "00000000-0000-0000-0000-000000000002",
                       "kind": {"type": "rectangle", "position": {"x": 0, "y": "1"}, "width": 10, "height": "5", "glow": true}}
                    ],
                    "color": "red"
                  }
                }
              ]
            }
            """
        let doc = try Document(data: Data(json.utf8))
        #expect(doc.printer == PrinterPreset.default.id)
        #expect(doc.features.count == 1)
        #expect(doc.features[0].name == "sketch")
        #expect(doc.features[0].suppressed == false)
        guard case .sketch(let sketch) = doc.features[0].kind else {
            Issue.record("not a sketch")
            return
        }
        #expect(sketch.plane == .standard(.xz, offset: 0))
        #expect(sketch.shapes[0].construction == false)
        #expect(
            sketch.shapes[0].kind
                == .rectangle(anchor: .corner, position: Point2Expr(0, 1), width: 10, height: 5, angle: 0))
    }

    @Test func preservesUnknownFeatureTypes() throws {
        let json = """
            {"formatVersion": 1, "features": [
              {"id": "00000000-0000-0000-0000-000000000009", "name": "Thread", "suppressed": false,
               "kind": {"type": "thread", "pitch": "1.5", "starts": 2, "flags": [true, null]}}
            ]}
            """
        let doc = try Document(data: Data(json.utf8))
        guard case .unknown(let type, let fields) = doc.features[0].kind else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "thread")
        #expect(fields["pitch"] == .string("1.5"))
        #expect(fields["starts"] == .number(2))
        #expect(fields["flags"] == .array([.bool(true), .null]))
        let again = try Document(data: try doc.encoded())
        #expect(again == doc)
        #expect(String(decoding: try doc.encoded(), as: UTF8.self).contains(#""type" : "thread""#))
    }

    @Test func signaturesUseTypeNames() throws {
        let json = String(decoding: try sampleDocument().encoded(), as: UTF8.self)
        #expect(json.contains(#""curve" : "line""#))
        #expect(json.contains(#""point" : {"#) == false)  // regions are {"x", "y"}
        let sig = try JSONDecoder().decode(
            FaceSignature.self,
            from: Data(#"{"surface": 1, "centroid": {"x":0,"y":0,"z":0}, "normal": {"x":0,"y":0,"z":1}, "area": 3}"#.utf8))
        #expect(sig.surface == .cylinder)
        #expect(sig.extent == .zero)
        let named = try JSONDecoder().decode(
            FaceSignature.self, from: try JSONEncoder().encode(FaceSignature(surface: .torus, centroid: .zero, normal: .unitZ, area: 1, extent: .zero)))
        #expect(named.surface == .torus)
    }

    /// Body patterns saved before feature patterns existed still read, and still write the same keys.
    @Test func bodyPatternsKeepTheirOldForm() throws {
        let body = "00000000-0000-0000-0000-000000000001"
        let json = """
            {"type": "pattern", "bodies": ["\(body)"],
             "layout": {"type": "linear", "direction": {"type": "x"}, "count": 3, "spacing": "10"}}
            """
        let kind = try JSONDecoder().decode(FeatureKind.self, from: Data(json.utf8))
        let expected = Pattern(bodies: [BodyRef(UUID(uuidString: body)!)], layout: .linear(direction: .x, count: 3, spacing: 10))
        #expect(kind == .pattern(expected))
        let written = String(decoding: try JSONEncoder().encode(kind), as: UTF8.self)
        #expect(!written.contains("objects") && !written.contains("features"))

        let features = FeatureKind.pattern(Pattern(features: [UUID()], layout: .circular(axis: .z, count: 4, angle: 360)))
        let encoded = String(decoding: try JSONEncoder().encode(features), as: UTF8.self)
        #expect(encoded.contains(#""objects":"features""#))
        #expect(try JSONDecoder().decode(FeatureKind.self, from: Data(encoded.utf8)) == features)
    }

    @Test func rejectsNewerFormat() {
        #expect(throws: DocumentError.newerFormat(99)) {
            try Document(data: Data(#"{"formatVersion": 99}"#.utf8))
        }
        #expect(throws: (any Error).self) { try Document(data: Data("not json".utf8)) }
    }

    @Test func activeFeaturesRespectRollbackAndSuppression() {
        var doc = sampleDocument()
        #expect(doc.activeFeatures.count == 3)
        doc.features[1].suppressed = true
        #expect(doc.activeFeatures.map(\.name) == ["Sketch 1", "Fillet 1"])
        doc.rollbackIndex = 1
        #expect(doc.activeFeatures.map(\.name) == ["Sketch 1"])
    }
}
