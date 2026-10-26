import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Hidden bodies")
struct HiddenBodiesTests {
    let base = UUID(), helper = UUID()

    func twoBodies() -> Document {
        var doc = Document()
        doc.features = [
            Feature(id: base, name: "Base", .primitive(Primitive(kind: .box, position: .origin, dimensions: [20, 20, 5]))),
            Feature(id: helper, name: "Helper", .primitive(Primitive(kind: .box, position: Point2Expr(40, 0), dimensions: [5, 5, 5]))),
        ]
        return doc
    }

    @Test func roundTripThroughTheFile() throws {
        var doc = twoBodies()
        doc.hiddenBodies = [BodyRef(helper)]
        let data = try doc.encoded()
        let loaded = try Document(data: data)
        #expect(loaded.hiddenBodies == [BodyRef(helper)])
        #expect(loaded == doc)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["hiddenBodies"] as? [String] == [helper.uuidString])
    }

    @Test func olderFilesHaveNothingHidden() throws {
        let doc = twoBodies()
        // Nothing hidden writes no key, so the file reads exactly as before in older versions.
        let data = try doc.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("hiddenBodies"))
        #expect(try Document(data: data).hiddenBodies.isEmpty)
    }

    @Test func bodiesWhoseStepIsGoneAreDropped() throws {
        var doc = twoBodies()
        let gone = BodyRef(UUID())
        doc.hiddenBodies = [BodyRef(helper), gone]
        #expect(try Document(data: doc.encoded()).hiddenBodies == [BodyRef(helper)])

        // Deleting the step forgets its body's visibility.
        _ = try doc.deleteFeature(helper)
        #expect(doc.hiddenBodies.isEmpty)
    }

    @Test func extraBodiesOfAStepCount() throws {
        var doc = twoBodies()
        // A pattern's copies and split bodies get ids derived from their step's.
        let copy = ModelEvaluator.derivedRef(helper, 2)
        #expect(copy != BodyRef(helper) && copy.isMade(by: helper) && !copy.isMade(by: base))
        doc.hiddenBodies = [copy]
        #expect(try Document(data: doc.encoded()).hiddenBodies == [copy])
    }

    @Test func visibilityDoesNotChangeTheModel() async throws {
        var doc = twoBodies()
        let ev = ModelEvaluator()
        let shown = await ev.evaluate(doc)
        doc.hiddenBodies = [BodyRef(helper)]
        let hidden = await ev.evaluate(doc)
        #expect(hidden.bodies.map(\.ref) == shown.bodies.map(\.ref))
    }
}
