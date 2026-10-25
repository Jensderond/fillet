import CoreGraphics
import Foundation
import simd
import Testing
import FilletKernel
@testable import FilletViewport

private let viewSize = CGSize(width: 800, height: 600)
private let cubeID = UUID()

private func screen(_ p: Vec3, _ c: Camera) -> CGPoint { c.project(p, viewSize: viewSize)! }

/// The three origin planes the app offers while choosing where to sketch: the bed square and
/// two upright planes standing on it.
private func originPlanes(reach r: Double = 50) -> [ReferencePlane] {
    [ReferencePlane(id: "xy", plane: .xy, u: -r...r, v: -r...r, label: "XY"),
     ReferencePlane(id: "xz", plane: .xz, u: -r...r, v: 0...r, label: "XZ"),
     ReferencePlane(id: "yz", plane: .yz, u: -r...r, v: 0...r, label: "YZ")]
}

@Suite("Reference planes")
struct ReferencePlaneTests {
    private let iso = Camera(target: Vec3(0, 0, 10), distance: 300).viewing(.iso)
    private let filter: PickFilter = [.faces, .referencePlanes]

    @Test func eachOriginPlaneIsPickableFromTheIsometricView() {
        let scene = ViewportScene(referencePlanes: originPlanes())
        let picker = ViewportPicker()
        // A point well inside each patch, away from where the planes cross.
        let inside: [(Vec3, String)] = [(Vec3(30, -30, 0), "xy"), (Vec3(-30, 0, 30), "xz"), (Vec3(0, -30, 30), "yz")]
        for (p, id) in inside {
            let hit = picker.pick(scene: scene, camera: iso, at: screen(p, iso), viewSize: viewSize, filter: filter)
            #expect(hit?.target == .referencePlane(id), "at \(p)")
            #expect((hit?.point.distance(to: p) ?? .infinity) < 1e-6)
        }
    }

    @Test func outsideThePatchPicksNothing() {
        let scene = ViewportScene(referencePlanes: originPlanes(reach: 20))
        let p = Vec3(60, -60, 0)
        #expect(ViewportPicker().pick(scene: scene, camera: iso, at: screen(p, iso), viewSize: viewSize, filter: filter) == nil)
    }

    @Test func planesNeedTheirFilter() {
        let scene = ViewportScene(referencePlanes: originPlanes())
        let at = screen(Vec3(30, -30, 0), iso)
        #expect(ViewportPicker().pick(scene: scene, camera: iso, at: at, viewSize: viewSize, filter: .default) == nil)
        #expect(ViewportPicker().pick(scene: scene, camera: iso, at: at, viewSize: viewSize, filter: .referencePlanes)?.target
            == .referencePlane("xy"))
    }

    @Test func nearestPlaneWinsWhereTheyOverlap() throws {
        // From the front, the XZ plane (y = 0) stands in front of the far half of the bed plane.
        let cam = Camera(target: Vec3(0, 0, 10), distance: 300, yaw: 0, pitch: 0.3)
        let scene = ViewportScene(referencePlanes: originPlanes())
        let hit = try #require(ViewportPicker().pick(scene: scene, camera: cam, at: screen(Vec3(-25, 0, 20), cam),
                                                     viewSize: viewSize, filter: filter))
        #expect(hit.target == .referencePlane("xz"))
        #expect(hit.normal == Vec3(0, -1, 0))  // faces the viewer
    }

    @Test func bodyInFrontHidesThePlane() throws {
        // A 20 mm cube standing on the bed at the origin, in front of the YZ plane's lower part.
        var scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20, center: [0, 0, 10]))])
        scene.referencePlanes = originPlanes()
        let hit = try #require(ViewportPicker().pick(scene: scene, camera: iso, at: screen(Vec3(0, 0, 20), iso),
                                                     viewSize: viewSize, filter: filter))
        #expect(hit.target == .face(body: cubeID, index: 1))  // its top
    }

    @Test func faceSeenThroughAPlaneWins() throws {
        // From the front and above, the XZ plane (y = 0) rises in front of the cube's top.
        let cube = SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20, center: [0, 15, 10]))
        var scene = ViewportScene(bodies: [cube], referencePlanes: originPlanes())
        let cam = Camera(target: Vec3(0, 15, 10), distance: 300, yaw: 0.3, pitch: 0.5)
        let top = screen(Vec3(0, 15, 20), cam)
        let behindPlane = try #require(cam.ray(at: top, viewSize: viewSize).intersect(Plane.xz))
        #expect(behindPlane.z > 20)  // the ray does pass through the upright plane first
        let picker = ViewportPicker()
        #expect(picker.pick(scene: scene, camera: cam, at: top, viewSize: viewSize, filter: filter)?.target == .face(body: cubeID, index: 1))
        // A face that can't be picked gives the plane in front of it back.
        scene.pickableFaces = [cubeID: []]
        #expect(picker.pick(scene: scene, camera: cam, at: top, viewSize: viewSize, filter: filter)?.target == .referencePlane("xz"))
    }

    @Test func faceLyingInThePlaneWinsTheTie() throws {
        // The cube's bottom face is on the bed plane; seen from below, the face (not the plane) is picked.
        var scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20, center: [0, 0, 10]))])
        scene.referencePlanes = originPlanes()
        let below = Camera(target: .zero, distance: 300).viewing(.bottom)
        let hit = try #require(ViewportPicker().pick(scene: scene, camera: below, at: screen(Vec3(5, 5, 0), below),
                                                     viewSize: viewSize, filter: filter))
        #expect(hit.target == .face(body: cubeID, index: 0))
    }

    @Test func faceOutsidePickableFacesStillBlocksTheRay() {
        var scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20, center: [0, 0, 10]))])
        scene.referencePlanes = originPlanes()
        scene.pickableFaces = [cubeID: [0, 1]]  // only top and bottom, as if the sides were curved
        let picker = ViewportPicker()
        let front = Camera(target: Vec3(0, 0, 10), distance: 300).viewing(.front)
        // The front face (2) can't be picked, and it hides the XZ plane through the cube behind it.
        #expect(picker.pick(scene: scene, camera: front, at: screen(Vec3(-5, -10, 10), front), viewSize: viewSize, filter: filter) == nil)
        // The top face still can.
        #expect(picker.pick(scene: scene, camera: iso, at: screen(Vec3(0, 0, 20), iso), viewSize: viewSize, filter: filter)?.target
            == .face(body: cubeID, index: 1))
    }

    @Test func tintFollowsTheNormalAxis() {
        let planes = originPlanes()
        #expect(planes.map(\.normalAxis) == [2, 1, 0])
        let pal = ViewportPalette.light
        #expect(planes.map { pal.color(for: $0) } == [pal.axisZ, pal.axisY, pal.axisX])
        let tilted = ReferencePlane(id: "t", plane: Plane(origin: .zero, normal: Vec3(1, 0, 1), xDir: .unitY),
                                    u: -1...1, v: -1...1, label: "T")
        #expect(tilted.normalAxis == nil)
        #expect(pal.color(for: tilted) == pal.referencePlane)
    }

    @Test func boundsIncludeThePlanes() throws {
        let scene = ViewportScene(referencePlanes: originPlanes(reach: 40))
        let b = try #require(scene.bounds)
        #expect(b.min.distance(to: Vec3(-40, -40, 0)) < 1e-9)
        #expect(b.max.distance(to: Vec3(40, 40, 40)) < 1e-9)
    }

    @MainActor @Test func rendersWithPlanesAndHover() throws {
        var scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20, center: [0, 0, 10]))])
        scene.referencePlanes = originPlanes()
        scene.hover = .referencePlane("xz")
        guard let image = ViewportRenderer.snapshot(scene: scene, camera: iso, size: CGSize(width: 200, height: 150), scale: 1)
        else { return }  // no Metal device
        #expect(image.width == 200 && image.height == 150)
    }
}
