import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

@Suite("Section picking")
struct SectionPickingTests {
    private let viewSize = CGSize(width: 800, height: 600)
    private func scene(_ mesh: Mesh = DemoMeshes.cube(size: 20)) -> ViewportScene {
        var s = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: mesh)])
        s.section = cutX
        return s
    }

    @Test func raysStopAtTheCapNotTheCutAwayFace() throws {
        let picker = ViewportPicker()
        let ray = Ray(origin: Vec3(100, 0, 0), direction: -Vec3.unitX)
        #expect(try #require(picker.raycast(ray, bodies: scene().bodies)).face == 5)
        picker.section = cutX
        let hit = try #require(picker.raycast(ray, bodies: scene().bodies))
        #expect(hit.onSectionCap && hit.face == -1)
        #expect(abs(hit.distance - 100) < 1e-9 && hit.normal == .unitX)
        // Through the cavity of a hollow part the ray goes on to the cavity's far wall.
        let hollow = try #require(picker.raycast(Ray(origin: Vec3(100, 0, 0), direction: -Vec3.unitX), bodies: scene(hollowCube()).bodies))
        #expect(!hollow.onSectionCap && abs(hollow.point.x + 5) < 1e-6)
        // From the kept side the ray stops at the plane: what's beyond is gone.
        let fromLeft = Ray(origin: Vec3(-100, 30, 0), direction: Vec3.unitX)
        #expect(picker.raycast(fromLeft, bodies: scene().bodies) == nil)
    }

    @Test func capPicksTheBodyButNoFace() throws {
        let cam = Camera(target: .zero, distance: 100).viewing(.right)
        let centre = CGPoint(x: 400, y: 300)
        let picker = ViewportPicker()
        #expect(picker.pick(scene: scene(), camera: cam, at: centre, viewSize: viewSize, filter: .faces) == nil)
        #expect(picker.pick(scene: scene(), camera: cam, at: centre, viewSize: viewSize, filter: .bodies)?.target == .body(sectionBodyID))
    }

    @Test func cutAwayEdgesCantBePicked() throws {
        // The right face's top edge (x = 10, z = 10) is gone; the top face's left edge isn't.
        let cam = Camera(target: .zero, distance: 120, yaw: 1.1, pitch: 0.45)
        let gone = try #require(cam.project(Vec3(10, 0, 10), viewSize: viewSize))
        let picker = ViewportPicker()
        var plain = scene()
        plain.section = nil
        let before = picker.pick(scene: plain, camera: cam, at: gone, viewSize: viewSize, filter: .edges)
        #expect(before?.target != nil)
        let after = picker.pick(scene: scene(), camera: cam, at: gone, viewSize: viewSize, filter: .edges)
        #expect(after?.target != before?.target)
        let kept = try #require(cam.project(Vec3(-10, 0, 10), viewSize: viewSize))
        #expect(picker.pick(scene: scene(), camera: cam, at: kept, viewSize: viewSize, filter: .edges)?.target
            == picker.pick(scene: plain, camera: cam, at: kept, viewSize: viewSize, filter: .edges)?.target)
    }
}
