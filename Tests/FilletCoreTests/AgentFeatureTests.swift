import FilletKernel
import Foundation
import Testing

@testable import FilletCore

/// Loft, scale, move about a centre and body colours (the features agents model characters with).
@Suite("Loft, scale and body colours")
struct AgentFeatureTests {
    let sphere = UUID()

    func sphereDocument(_ more: [Feature]) -> Document {
        var doc = Document()
        doc.features = [Feature(id: sphere, name: "Ball", .primitive(Primitive(kind: .sphere, plane: .standard(.xy, offset: 20),
                                                                                dimensions: [20])))] + more
        return doc
    }

    @Test func scaleSquashesAboutItsCenter() async throws {
        let scale = Feature(name: "Squash", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr(2, 1, "0.5"),
                                                          center: Vec3Expr(0, 0, 20))))
        let model = await ModelEvaluator().evaluate(sphereDocument([scale]))
        #expect(model.status[scale.id] == .ok)
        let b = try #require(model.bodies.first?.shape.bounds)
        #expect(abs(b.min.x + 20) < 0.05 && abs(b.max.x - 20) < 0.05)
        #expect(abs(b.max.y - 10) < 0.05)
        #expect(abs(b.min.z - 15) < 0.05 && abs(b.max.z - 25) < 0.05)
        let volume = try #require(model.bodies.first?.shape.volume)
        #expect(abs(volume - 4.0 / 3 * .pi * 1000) < 5)  // 2 × 1 × 0.5 keeps the volume
    }

    @Test func scaleAlongTurnedAxes() async throws {
        // Z turned 90° about X points along −Y: halving "Z" halves the ball's depth instead.
        let scale = Feature(name: "Squash", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr(1, 1, "0.5"),
                                                          center: Vec3Expr(0, 0, 20),
                                                          orientation: .init(axis: Vec3Expr(1, 0, 0), angle: 90))))
        let model = await ModelEvaluator().evaluate(sphereDocument([scale]))
        #expect(model.status[scale.id] == .ok)
        let b = try #require(model.bodies.first?.shape.bounds)
        #expect(abs(b.max.x - 10) < 0.05 && abs(b.max.y - 5) < 0.05 && abs(b.max.z - 30) < 0.05)
        // 45° about X: the squash runs diagonally, so the ball is no longer symmetric in Y and Z alone.
        let tilted = Feature(id: scale.id, name: "Squash", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr(1, 1, "0.5"),
                                                                         center: Vec3Expr(0, 0, 20),
                                                                         orientation: .init(axis: Vec3Expr(1, 0, 0), angle: 45))))
        let model2 = await ModelEvaluator().evaluate(sphereDocument([tilted]))
        let body = try #require(model2.bodies.first)
        #expect(body.shape.isValid)
        #expect(abs(body.shape.volume - 4.0 / 3 * .pi * 500) < 5)
        let t = try #require(body.shape.bounds)
        // An ellipsoid with semi-axes 10 and 5 turned 45°: its extent along Y and Z is √((100 + 25) / 2).
        #expect(abs(t.max.y - (62.5).squareRoot()) < 0.1)
        let zero = Feature(name: "Bad", .scale(Scale(bodies: [BodyRef(sphere)], orientation: .init(axis: .zero, angle: 10))))
        #expect(await ModelEvaluator().evaluate(sphereDocument([zero])).error(for: zero.id)?.contains("axis") == true)
    }

    /// Without a turn, the translation stays c·(1 − f) bit for bit: c − f·c is the same maths but
    /// rounds differently (20.3 × 0.3 vs 20.3 − 0.7 × 20.3), which moved every scaled body of
    /// existing designs by an ulp and changed the bench's mesh and face-info digests.
    @Test func unturnedScaleKeepsItsTranslation() async throws {
        let scale = Feature(name: "Squash", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr("0.7", 1, "0.7"),
                                                          center: Vec3Expr("20.3", 0, "20.3"))))
        let model = await ModelEvaluator().evaluate(sphereDocument([scale]))
        let scaled = try #require(model.bodies.first?.shape)
        let ball = try #require(await ModelEvaluator().evaluate(sphereDocument([])).bodies.first?.shape)
        let t = 20.3 * (1 - 0.7)
        #expect(t != 20.3 - 0.7 * 20.3)
        let expected = try ball.transformed(Transform(matrix: [0.7, 0, 0, t, 0, 1, 0, 0, 0, 0, 0.7, t]))
        #expect(scaled.brepString() == expected.brepString())
    }

    @Test func scaleRefusesZero() async {
        let scale = Feature(name: "Flat", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr(1, 1, 0))))
        let model = await ModelEvaluator().evaluate(sphereDocument([scale]))
        #expect(model.error(for: scale.id) != nil)
    }

    @Test func moveRotatesAboutItsCenter() async throws {
        // A 90° turn about Z through the ball's own centre leaves it in place.
        let move = Feature(name: "Turn", .move(Move(bodies: [BodyRef(sphere)], rotationAxis: .z, rotationAngle: 90,
                                                    rotationCenter: Vec3Expr(30, 0, 0))))
        let model = await ModelEvaluator().evaluate(sphereDocument([move]))
        let b = try #require(model.bodies.first?.shape.bounds)
        // Rotating about (30, 0) carries the centre from (0, 0) to (30, −30).
        #expect(abs((b.min.x + b.max.x) / 2 - 30) < 0.05)
        #expect(abs((b.min.y + b.max.y) / 2 + 30) < 0.05)
    }

    @Test func loftThroughCirclesToAPoint() async throws {
        let loft = Feature(name: "Horn", .loft(Loft(sections: [
            .init(center: Vec3Expr(0, 0, 0), width: 20),
            .init(center: Vec3Expr(0, 0, 15), width: 12, height: 8),
            .init(center: Vec3Expr(0, 0, 30), width: 0),
        ])))
        var doc = Document()
        doc.features = [loft]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[loft.id] == .ok)
        let body = try #require(model.bodies.first)
        #expect(body.shape.isValid)
        #expect(body.shape.volume > 1000)
        let b = try #require(body.shape.bounds)
        #expect(abs(b.max.z - 30) < 0.1)
    }

    @Test func loftRefusesAPointInTheMiddle() async {
        let loft = Feature(name: "Bad", .loft(Loft(sections: [
            .init(center: Vec3Expr(0, 0, 0), width: 20), .init(center: Vec3Expr(0, 0, 10), width: 0),
            .init(center: Vec3Expr(0, 0, 20), width: 10),
        ])))
        var doc = Document()
        doc.features = [loft]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.error(for: loft.id)?.contains("first or last") == true)
    }

    @Test func newFeaturesAndColorsRoundTrip() throws {
        var doc = sphereDocument([
            Feature(name: "Squash", .scale(Scale(bodies: [BodyRef(sphere)], factors: Vec3Expr(1, 1, "0.8")))),
            Feature(name: "Horn", .loft(Loft(sections: [.init(center: .zero, width: 5), .init(center: Vec3Expr(0, 0, 5), width: 0)]))),
            Feature(name: "Turn", .move(Move(bodies: [BodyRef(sphere)], rotationAngle: 10, rotationCenter: Vec3Expr(1, 2, 3)))),
        ])
        doc.bodyColors = [BodyRef(sphere): "#43A047"]
        let decoded = try Document(data: try doc.encoded())
        #expect(decoded == doc)
        // Files without colours or centres stay as they were.
        let plain = String(decoding: try Document().encoded(), as: UTF8.self)
        #expect(!plain.contains("bodyColors"))
        let moveJSON = String(decoding: try JSONEncoder().encode(Move(bodies: [])), as: UTF8.self)
        #expect(!moveJSON.contains("rotationCenter"))
        let scaleJSON = String(decoding: try JSONEncoder().encode(Scale(bodies: [])), as: UTF8.self)
        #expect(!scaleJSON.contains("orientation"))
        let turned = Scale(bodies: [], orientation: .init(axis: Vec3Expr(0, 0, 1), angle: "tilt"))
        #expect(try JSONDecoder().decode(Scale.self, from: try JSONEncoder().encode(turned)) == turned)
        // Older files (no orientation) still open.
        let old = #"{"bodies":[],"factors":{"x":"1","y":"1","z":"0.5"},"center":{"x":"0","y":"0","z":"0"}}"#
        #expect(try JSONDecoder().decode(Scale.self, from: Data(old.utf8)).orientation == nil)
    }
}
