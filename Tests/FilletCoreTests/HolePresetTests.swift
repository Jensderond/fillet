import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Hole presets")
struct HolePresetTests {
    let sketchID = UUID(), extrudeID = UUID()

    /// A 40 × 20 × 10 block centred on the origin.
    func blockDocument() -> Document {
        var doc = Document()
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(Sketch(plane: .xy, shapes: [
                SketchShape(.rectangle(anchor: .center, position: .origin, width: 40, height: 20, angle: 0)),
            ]))),
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(
                sketch: sketchID, regions: [RegionRef(x: 1, y: 1)], distance: 10))),
        ]
        return doc
    }

    func sized(_ preset: HolePreset, _ doc: Document) throws -> HoleSpec {
        var hole = Hole(face: nil)
        var doc = doc
        doc.apply(preset, to: &hole)
        return try hole.spec(using: doc.parameterTable.evaluator)
    }

    @Test func sizesForAnM3() throws {
        let doc = blockDocument()
        let clear = try sized(HolePreset(.m3, .clearance), doc)
        #expect(abs(clear.diameter - 3.6) < 1e-9)  // 3.4 (ISO 273 normal) + 0.2 clearance
        #expect(clear.head == .simple)

        let cbore = try sized(HolePreset(.m3, .counterbore), doc)
        #expect(cbore.head == .counterbore(diameter: 6.7, depth: 3))
        let csk = try sized(HolePreset(.m3, .countersink), doc)
        if case .countersink(let d, let angle) = csk.head {
            #expect(abs(d - 6.92) < 1e-9 && abs(angle - .pi / 2) < 1e-9)
        } else {
            Issue.record("not a countersink")
        }

        // Grip fits leave the clearance out.
        #expect(try sized(HolePreset(.m3, .tap), doc).diameter == 2.7)
        let insert = try sized(HolePreset(.m3, .insert), doc)
        #expect(insert.diameter == 4 && insert.depth == 6.7)
    }

    @Test func smallSizesFollowTheirSources() throws {
        let doc = blockDocument()
        // ISO 10642 dk (theoretical) for M2 and M2.5, plus 0.2 clearance.
        for (size, dk) in [(ScrewSize.m2, 4.7), (.m2_5, 5.88)] {
            let csk = try sized(HolePreset(size, .countersink), doc)
            if case .countersink(let d, _) = csk.head {
                #expect(abs(d - (dk + 0.2)) < 1e-9, "\(size)")
            } else {
                Issue.record("not a countersink")
            }
        }
        // Inserts: hole diameter and depth (length + 1). M2.5 is Ø4.0 in both makers' sheets.
        for (size, hole, depth) in [(ScrewSize.m2, 3.2, 5.0), (.m2_5, 4.0, 6.7), (.m4, 5.6, 9.1), (.m5, 6.4, 10.5), (.m6, 8.0, 13.7)] {
            let insert = try sized(HolePreset(size, .insert), doc)
            #expect(abs(insert.diameter - hole) < 1e-9 && abs((insert.depth ?? 0) - depth) < 1e-9, "\(size)")
        }
    }

    @Test func everyPresetEvaluates() throws {
        let doc = blockDocument()
        #expect(HolePreset.all.count == ScrewSize.allCases.count * HoleFit.allCases.count)
        for preset in HolePreset.all {
            let spec = try sized(preset, doc)
            #expect(spec.diameter > 1.5 && spec.diameter < 9, "\(preset)")
            #expect(HolePreset(id: preset.id) == preset)
        }
        // Bigger screws, bigger holes.
        let clearances = try ScrewSize.allCases.map { try sized(HolePreset($0, .clearance), doc).diameter }
        #expect(clearances == clearances.sorted())
    }

    @Test func clearanceIsAddedOnceAndTunesEveryClearanceHole() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let model = await ev.evaluate(doc)
        let body = try #require(model.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.normal.z > 0.99 })
        let face = try #require(model.faceRef(body: body.ref, face: top))

        var through = Hole(face: face, centers: [Point2Expr(-10, 0)], extent: .throughAll, anchor: .world)
        doc.apply(HolePreset(.m3, .clearance), to: &through)
        var insert = Hole(face: face, centers: [Point2Expr(10, 0)], anchor: .world)
        doc.apply(HolePreset(.m3, .insert), to: &insert)
        #expect(doc.parameters.filter { $0.name == "clearance" }.count == 1)
        #expect(doc.parameterTable.values["clearance"]?.value == 0.2)
        let holeA = UUID(), holeB = UUID()
        doc.features += [Feature(id: holeA, name: "Screw", .hole(through)), Feature(id: holeB, name: "Insert", .hole(insert))]

        func wallDiameters(_ m: EvaluatedModel) throws -> [Double] {
            try #require(m.bodies.first).shape.faceInfos.filter { $0.surface == .cylinder }
                .map { ($0.boundsMax.y - $0.boundsMin.y).rounded(toPlaces: 3) }.sorted()
        }
        let first = await ev.evaluate(doc)
        #expect(first.status[holeA] == .ok && first.status[holeB] == .ok)
        #expect(try wallDiameters(first) == [3.6, 4])

        // One value for the printer: the clearance hole follows, the insert hole doesn't.
        let i = try #require(doc.parameters.firstIndex { $0.name == "clearance" })
        doc.parameters[i].expression = "0.3"
        #expect(try wallDiameters(await ev.evaluate(doc)) == [3.7, 4])

        // A design that already has a clearance keeps its own.
        var other = Hole(face: nil)
        doc.apply(HolePreset(.m4, .counterbore), to: &other)
        #expect(doc.parameters.filter { $0.name == "clearance" }.map(\.expression) == ["0.3"])
    }

    @Test func remembersThePresetAndNoticesEdits() throws {
        var hole = Hole(face: nil)
        #expect(hole.presetTitle == nil)
        HolePreset(.m3, .clearance).apply(to: &hole)
        #expect(hole.presetTitle == "M3 clearance")
        hole.diameter = "3.4+clearance"  // spaces don't count
        #expect(hole.presetTitle == "M3 clearance")
        hole.diameter = 3.5
        #expect(hole.presetTitle == "M3 clearance (edited)")
        // Sizes the preset doesn't set (here the depth) are the user's to change.
        HolePreset(.m3, .clearance).apply(to: &hole)
        hole.depth = 25
        #expect(hole.presetTitle == "M3 clearance")

        // Saved as its id; one this version doesn't know reads as no preset, sizes untouched.
        let data = try JSONEncoder().encode(FeatureKind.hole(hole))
        #expect(String(decoding: data, as: UTF8.self).contains(#""preset":"m3-clearance""#))
        #expect(try JSONDecoder().decode(FeatureKind.self, from: data) == .hole(hole))
        let unknown = try JSONDecoder().decode(FeatureKind.self, from: Data(#"{"type": "hole", "preset": "m42-clearance", "diameter": "7"}"#.utf8))
        guard case .hole(let h) = unknown else { Issue.record("not a hole"); return }
        #expect(h.preset == nil && h.diameter == "7")
        #expect(HolePreset(id: "M2.5 insert") == HolePreset(.m2_5, .insert))
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10, Double(n))
        return (self * f).rounded() / f
    }
}
