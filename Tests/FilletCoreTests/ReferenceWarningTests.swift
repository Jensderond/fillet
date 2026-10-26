import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Reference warnings")
struct ReferenceWarningTests {
    let sketchID = UUID(), extrudeID = UUID(), slotSketchID = UUID(), slotID = UUID()
    let holeID = UUID(), faceSketchID = UUID()

    /// A 40 × 20 × 10 block with its corner at the origin.
    func blockDocument() -> Document {
        var doc = Document()
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(Sketch(plane: .xy, shapes: [
                SketchShape(.rectangle(anchor: .corner, position: .origin, width: 40, height: 20, angle: 0)),
            ]))),
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(
                sketch: sketchID, regions: [RegionRef(x: 1, y: 1)], distance: 10))),
        ]
        return doc
    }

    /// A 2 mm slot across the middle of the top, which splits the top face into two equal halves.
    var slot: [Feature] {
        [
            Feature(id: slotSketchID, name: "Slot sketch", .sketch(Sketch(plane: .standard(.xy, offset: 10), shapes: [
                SketchShape(.rectangle(anchor: .corner, position: Point2Expr(19, -1), width: 2, height: 22, angle: 0)),
            ]))),
            Feature(id: slotID, name: "Slot", .extrude(Extrude(
                sketch: slotSketchID, regions: [RegionRef(x: 20, y: 10)], distance: -5, operation: .cut))),
        ]
    }

    @Test func aSplitFaceWarnsTheStepsThatUseIt() async throws {
        var doc = blockDocument()
        let ev = ModelEvaluator()
        let block = await ev.evaluate(doc)
        let body = try #require(block.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.normal.z > 0.99 })
        let topRef = try #require(block.faceRef(body: body.ref, face: top))
        let plane = try #require(body.shape.facePlane(top, anchor: .world))
        doc.features += [
            Feature(id: holeID, name: "Hole", .hole(Hole(
                face: topRef, centers: [Point2Expr(5, 10)], diameter: 3, depth: 3, anchor: .world))),
            Feature(id: faceSketchID, name: "Sketch on top", .sketch(Sketch(
                plane: .face(topRef, fallback: plane, anchor: .world),
                shapes: [SketchShape(.circle(center: Point2Expr(35, 10), diameter: 4))]))),
        ]

        // Picked on the whole top face: clear matches, no warnings.
        let clear = await ev.evaluate(doc)
        #expect(clear.status[holeID] == .ok && clear.status[faceSketchID] == .ok)
        #expect(clear.ambiguousReferences(for: holeID).isEmpty)
        #expect(try clear.referenceWarning(for: #require(doc.feature(holeID))) == nil)
        #expect(try clear.referenceWarning(for: #require(doc.feature(faceSketchID))) == nil)

        // A slot added before them splits that face in two: both halves match equally well. The
        // steps still work, so it's a warning on them rather than a failure.
        doc.features.insert(contentsOf: slot, at: 2)
        let split = await ev.evaluate(doc)
        #expect(split.status[holeID] == .ok && split.status[faceSketchID] == .ok)
        #expect(split.ambiguousReferences(for: holeID) == [0])
        #expect(split.ambiguousReferences(for: faceSketchID) == [0])
        let warning = try split.referenceWarning(for: #require(doc.feature(holeID)))
        #expect(warning == "Its face matched ambiguously after a change — check it")
        #expect(try split.referenceWarning(for: #require(doc.feature(faceSketchID))) != nil)
        #expect(split.error(for: holeID) == nil)
    }

    @Test func numbersTheAmbiguousEdgesOfAFillet() throws {
        var model = EvaluatedModel(parameters: ParameterTable([]))
        let fillet = Feature(name: "Fillet", .fillet(EdgeFeature(body: BodyRef(extrudeID), edges: [], size: 1)))
        let clear = ReferenceMatch(index: 0, score: 0, isAmbiguous: false)
        let vague = ReferenceMatch(index: 1, score: 0.4, isAmbiguous: true)
        model.status[fillet.id] = .ok
        model.references[fillet.id] = [ResolvedReference(clear, offset: 0), nil, ResolvedReference(vague, offset: 3)]
        #expect(model.referenceWarning(for: fillet) == "Edge 3 matched ambiguously after a change — check it")
        model.references[fillet.id]?[0] = ResolvedReference(vague, offset: 3)
        #expect(model.referenceWarning(for: fillet) == "Edges 1 and 3 matched ambiguously after a change — check them")
        // A failed step shows its error instead.
        model.status[fillet.id] = .failed("Radius too big")
        #expect(model.referenceWarning(for: fillet) == nil)
    }
}
