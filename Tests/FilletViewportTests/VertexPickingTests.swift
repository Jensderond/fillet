import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

/// Picking B-rep vertices (Measure): a corner wins over the edges meeting there, only when it's
/// asked for and visible.
@Suite("Vertex picking")
struct VertexPickingTests {
    private let size = CGSize(width: 800, height: 600)
    private let id = UUID()
    private let cam = Camera(target: .zero, distance: 120, yaw: 0.5, pitch: 0.45)

    /// A real kernel cube (20 mm, centred on the origin), so the mesh carries its vertices.
    private func scene() throws -> (ViewportScene, Shape) {
        let shape = try Shape.box(corner: Vec3(-10, -10, -10), size: Vec3(20, 20, 20))
        return (ViewportScene(bodies: [SceneBody(id: id, mesh: try shape.tessellate())]), shape)
    }

    private func index(_ shape: Shape, _ p: Vec3) throws -> Int {
        let i = (0..<shape.vertexCount).first { shape.vertexPoint($0).map { $0.distance(to: p) < 1e-9 } ?? false }
        return try #require(i)
    }

    @Test func cornerBeatsItsEdges() throws {
        let (scene, shape) = try scene()
        let corner = Vec3(10, -10, 10)  // front-right-top, facing the camera
        let at = try #require(cam.project(corner, viewSize: size))
        let hit = try #require(ViewportPicker().pick(scene: scene, camera: cam, at: CGPoint(x: at.x + 3, y: at.y + 2), viewSize: size,
                                                     filter: [.faces, .edges, .vertices]))
        #expect(hit.target == .vertex(body: id, index: try index(shape, corner)))
        #expect(hit.point.distance(to: corner) < 1e-4)
        #expect(hit.target.bodyID == id)
        // Without `.vertices` the same spot picks an edge, as before.
        let edge = try #require(ViewportPicker().pick(scene: scene, camera: cam, at: CGPoint(x: at.x + 3, y: at.y + 2), viewSize: size,
                                                      filter: [.faces, .edges]))
        if case .edge = edge.target {} else { Issue.record("expected an edge, got \(edge.target)") }
    }

    @Test func midEdgeIsNotAVertex() throws {
        let (scene, _) = try scene()
        let at = try #require(cam.project(Vec3(0, -10, 10), viewSize: size))
        let hit = try #require(ViewportPicker().pick(scene: scene, camera: cam, at: at, viewSize: size, filter: [.faces, .edges, .vertices]))
        if case .edge = hit.target {} else { Issue.record("expected an edge, got \(hit.target)") }
    }

    @Test func hiddenCornerIsNotPicked() throws {
        let (scene, shape) = try scene()
        let hidden = Vec3(-10, 10, -10)  // back-left-bottom, behind the cube
        let at = try #require(cam.project(hidden, viewSize: size))
        let hit = ViewportPicker().pick(scene: scene, camera: cam, at: at, viewSize: size, filter: [.faces, .edges, .vertices])
        #expect(hit?.target != .vertex(body: id, index: try index(shape, hidden)))
    }
}
