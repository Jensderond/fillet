import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Document editing")
struct DocumentEditingTests {
    let doc = sampleDocument()
    var sketch: UUID { doc.features[0].id }
    var extrude: UUID { doc.features[1].id }
    var fillet: UUID { doc.features[2].id }

    @Test func dependenciesAndDependents() {
        #expect(doc.dependencies(of: sketch).isEmpty)
        #expect(doc.dependencies(of: extrude) == [sketch])
        #expect(doc.dependencies(of: fillet) == [extrude])
        #expect(doc.dependents(of: sketch) == [extrude, fillet])
        #expect(doc.dependents(of: fillet).isEmpty)
        #expect(doc.features[1].createsBody)
        #expect(!doc.features[2].createsBody)
    }

    @Test func addFeatureAppendsOrInsertsAtMarker() {
        var d = doc
        let a = Feature(name: "A", .sketch(Sketch()))
        #expect(d.addFeature(a) == 3)
        #expect(d.rollbackIndex == nil)

        d.moveRollbackMarker(to: 1)
        let b = Feature(name: "B", .sketch(Sketch()))
        #expect(d.addFeature(b) == 1)
        #expect(d.features.map(\.name) == ["Sketch 1", "B", "Extrude 1", "Fillet 1", "A"])
        #expect(d.rollbackIndex == 2)  // the new feature is active
        #expect(d.activeFeatures.map(\.name) == ["Sketch 1", "B"])
    }

    @Test func rollbackMarkerClamps() {
        var d = doc
        d.moveRollbackMarker(to: 2)
        #expect(d.rollbackIndex == 2)
        d.moveRollbackMarker(to: 10)
        #expect(d.rollbackIndex == nil)
        d.moveRollbackMarker(to: -3)
        #expect(d.rollbackIndex == 0)
        #expect(d.activeFeatures.isEmpty)
        d.moveRollbackMarker(to: nil)
        #expect(d.activeFeatures.count == 3)
    }

    @Test func deleteReportsBrokenDependents() throws {
        var d = doc
        let result = try d.deleteFeature(extrude)
        #expect(result.removed == [extrude])
        #expect(result.brokenDependents == [fillet])
        #expect(d.features.map(\.name) == ["Sketch 1", "Fillet 1"])
        #expect(throws: DocumentEditError.featureNotFound(extrude)) { try d.deleteFeature(extrude) }
    }

    @Test func cascadingDeleteAdjustsMarker() throws {
        var d = doc
        d.addFeature(Feature(name: "Other", .sketch(Sketch())))
        d.moveRollbackMarker(to: 3)
        let result = try d.deleteFeature(sketch, cascade: true)
        #expect(result.removed == [sketch, extrude, fillet])
        #expect(result.brokenDependents.isEmpty)
        #expect(d.features.map(\.name) == ["Other"])
        #expect(d.rollbackIndex == 0)
    }

    @Test func renameAndSuppress() throws {
        var d = doc
        try d.renameFeature(extrude, to: "Base")
        try d.setSuppressed(fillet, true)
        #expect(d.feature(extrude)?.name == "Base")
        #expect(d.feature(fillet)?.suppressed == true)
        #expect(throws: DocumentEditError.self) { try d.renameFeature(UUID(), to: "x") }
    }

    @Test func reorderValidatesDependencies() throws {
        var d = doc
        let other = Feature(name: "Other", .sketch(Sketch()))
        d.addFeature(other)
        // Fillet uses the extrude: cannot move before it.
        #expect(!d.canMoveFeature(fillet, to: 1))
        #expect(throws: DocumentEditError.dependencyViolation(feature: fillet, other: extrude)) {
            try d.moveFeature(fillet, to: 0)
        }
        // Extrude is used by the fillet: cannot move after it.
        #expect(throws: DocumentEditError.self) { try d.moveFeature(extrude, to: 3) }
        // Independent sketch can go anywhere.
        try d.moveFeature(other.id, to: 0)
        #expect(d.features.map(\.name) == ["Other", "Sketch 1", "Extrude 1", "Fillet 1"])
        try d.moveFeature(other.id, to: 2)
        #expect(d.features.map(\.name) == ["Sketch 1", "Extrude 1", "Other", "Fillet 1"])
        // The fillet may move to the end.
        try d.moveFeature(fillet, to: 99)
        #expect(d.features.last?.name == "Fillet 1")
    }

    @Test func updateFeature() throws {
        var d = doc
        var f = try #require(d.feature(extrude))
        guard case .extrude(var e) = f.kind else { return }
        e.distance = "width / 2"
        f.kind = .extrude(e)
        try d.updateFeature(f)
        #expect(d.feature(extrude) == f)
    }

    @Test func sketchOnFaceDependsOnBody() {
        var d = doc
        let face = FaceRef(
            body: BodyRef(extrude),
            signature: FaceSignature(surface: .plane, centroid: Vec3(20, 10, 10), normal: .unitZ, area: 800, extent: Vec3(40, 20, 0)))
        let s = Feature(name: "Sketch 2", .sketch(Sketch(plane: .face(face, fallback: Plane.xy.offset(by: 10)))))
        d.addFeature(s)
        #expect(d.dependencies(of: s.id) == [extrude])
        #expect(d.dependents(of: sketch).contains(s.id))
    }
}
