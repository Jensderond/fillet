import CoreGraphics
import Foundation
import simd
import Testing
import FilletKernel
@testable import FilletViewport

private let viewSize = CGSize(width: 800, height: 600)
private let cubeID = UUID()

/// 20 mm cube centred on the origin.
private func cubeScene() -> ViewportScene {
    ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20))])
}

private func screen(_ p: Vec3, _ c: Camera) -> CGPoint { c.project(p, viewSize: viewSize)! }

@Suite("Picking")
struct PickingTests {
    @Test func rayThroughCubeCenterHitsFrontFace() throws {
        let picker = ViewportPicker()
        let ray = Ray(origin: Vec3(0, -100, 0), direction: .unitY)
        let hit = try #require(picker.raycast(ray, bodies: cubeScene().bodies))
        #expect(hit.face == 2)  // front (-Y)
        #expect(abs(hit.distance - 90) < 1e-9)
        #expect(hit.point.distance(to: Vec3(0, -10, 0)) < 1e-9)
        #expect(hit.normal.distance(to: Vec3(0, -1, 0)) < 1e-9)
    }

    @Test func pickAtScreenCenterReturnsFace() throws {
        let cam = Camera(target: .zero, distance: 100).viewing(.front)
        let hit = try #require(ViewportPicker().pick(scene: cubeScene(), camera: cam, at: CGPoint(x: 400, y: 300),
                                                     viewSize: viewSize, filter: .default))
        #expect(hit.target == .face(body: cubeID, index: 2))
        #expect(hit.normal == Vec3(0, -1, 0))
    }

    @Test func bodyFilterReportsBody() throws {
        let cam = Camera(target: .zero, distance: 100).viewing(.top)
        let hit = try #require(ViewportPicker().pick(scene: cubeScene(), camera: cam, at: CGPoint(x: 400, y: 300),
                                                     viewSize: viewSize, filter: .bodies))
        #expect(hit.target == .body(cubeID))
    }

    @Test func missReturnsNil() {
        let cam = Camera(target: .zero, distance: 100).viewing(.front)
        #expect(ViewportPicker().pick(scene: cubeScene(), camera: cam, at: CGPoint(x: 10, y: 10), viewSize: viewSize, filter: .all) == nil)
    }

    @Test func edgePickedNearProjectedEdge() throws {
        let cam = Camera(target: .zero, distance: 120, yaw: 0.5, pitch: 0.45)
        // Top-front edge: y = -10, z = 10, from x = -10 to 10 (bottom loop is 0–3, top loop 4–7; top front edge = 4).
        let mid = screen(Vec3(0, -10, 10), cam)
        let hit = try #require(ViewportPicker().pick(scene: cubeScene(), camera: cam, at: CGPoint(x: mid.x, y: mid.y + 3),
                                                     viewSize: viewSize, filter: .default))
        #expect(hit.target == .edge(body: cubeID, index: 4))
        #expect(hit.screenDistance <= 3.5)
        #expect(hit.point.distance(to: Vec3(0, -10, 10)) < 0.5)
    }

    @Test func edgePreferredOnlyWithinTolerance() throws {
        let cam = Camera(target: .zero, distance: 120, yaw: 0.5, pitch: 0.45)
        let mid = screen(Vec3(0, -10, 10), cam)
        // 25 pt below the edge, on the front face: face wins.
        let hit = try #require(ViewportPicker().pick(scene: cubeScene(), camera: cam, at: CGPoint(x: mid.x, y: mid.y + 25),
                                                     viewSize: viewSize, filter: .default, tolerance: 5))
        #expect(hit.target == .face(body: cubeID, index: 2))
    }

    @Test func occludedEdgeIsNotPicked() throws {
        let cam = Camera(target: .zero, distance: 120, yaw: 0.5, pitch: 0.45)
        let picker = ViewportPicker()
        // Vertical back-left edge (corner x = -10, y = +10) is hidden from the front-right-top.
        let hidden = Vec3(-10, 10, -4)
        #expect(!picker.isVisible(hidden, bodies: cubeScene().bodies, camera: cam, viewSize: viewSize))
        #expect(picker.isVisible(Vec3(0, -10, 10), bodies: cubeScene().bodies, camera: cam, viewSize: viewSize))
        let hit = picker.pick(scene: cubeScene(), camera: cam, at: screen(hidden, cam), viewSize: viewSize, filter: .edges)
        #expect(hit?.target != .edge(body: cubeID, index: 11))
        // Same spot with faces enabled: the face in front is picked.
        let faceHit = try #require(picker.pick(scene: cubeScene(), camera: cam, at: screen(hidden, cam), viewSize: viewSize, filter: .default))
        if case .face = faceHit.target {} else { Issue.record("expected a face, got \(faceHit.target)") }
    }

    @Test func nearestBodyWins() throws {
        let a = UUID(), b = UUID()
        let scene = ViewportScene(bodies: [
            SceneBody(id: a, mesh: DemoMeshes.cube(size: 10, center: [0, 20, 0])),
            SceneBody(id: b, mesh: DemoMeshes.cube(size: 10, center: [0, 0, 0])),
        ])
        let hit = try #require(ViewportPicker().raycast(Ray(origin: Vec3(0, -100, 0), direction: .unitY), bodies: scene.bodies))
        #expect(hit.body == b)
        var hidden = scene
        hidden.bodies[1].visible = false
        #expect(ViewportPicker().raycast(Ray(origin: Vec3(0, -100, 0), direction: .unitY), bodies: hidden.bodies)?.body == a)
    }

    @Test func sketchPointsCurvesAndRegions() throws {
        let shape = UUID()
        let square: [SIMD2<Double>] = [[0, 0], [20, 0], [20, 20], [0, 20]]
        var scene = ViewportScene()
        scene.sketch = SketchOverlay(
            plane: .xy,
            curves: [SketchCurve(shapeID: shape, points: square, closed: true)],
            points: square.enumerated().map { SketchPoint(shapeID: shape, index: $0.offset, position: $0.element) },
            regions: [SketchRegion(index: 7, triangles: [[0, 0], [20, 0], [20, 20], [0, 0], [20, 20], [0, 20]])])
        let cam = Camera(target: Vec3(10, 10, 0), distance: 100).viewing(.top)
        let picker = ViewportPicker()
        func pick(_ uv: SIMD2<Double>, _ f: PickFilter) -> PickHit? {
            picker.pick(scene: scene, camera: cam, at: screen(Vec3(uv.x, uv.y, 0), cam), viewSize: viewSize, filter: f)
        }
        #expect(pick([20.2, 20.1], .all)?.target == .sketchPoint(shape: shape, index: 2))
        #expect(pick([10, 0.2], .all)?.target == .sketchShape(shape))
        let region = try #require(pick([10, 10], .all))
        #expect(region.target == .region(7))
        #expect(simd_distance(region.sketchPoint ?? .zero, [10, 10]) < 1e-6)
        #expect(pick([10, 10], .sketch) == nil)
        #expect(pick([30, 10], .all) == nil)
        // Snap guides and markers are feedback, never picked.
        scene.sketch?.guides = [SketchGuide(from: [20, 20], to: [50, 20])]
        scene.sketch?.markers = [SketchSnapMarker(position: [40, 20], shape: .triangle), SketchSnapMarker(position: [20, 20], shape: .circle, anchor: true)]
        #expect(pick([35, 20], .all) == nil)
        #expect(pick([40, 20], .all) == nil)
    }

    @Test func handlePickAndAxisParameter() throws {
        let h = Handle(id: "d", origin: .zero, direction: .unitZ, value: 10)
        let scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 10))], handles: [h])
        let cam = Camera(target: .zero, distance: 150).viewing(.front)
        let picker = ViewportPicker()
        let g = try #require(ViewportPicker.handleScreenGeometry(h, camera: cam, viewSize: viewSize))
        let onShaft = CGPoint(x: (g.start.x + g.tip.x) / 2, y: (g.start.y + g.tip.y) / 2)
        #expect(picker.pick(scene: scene, camera: cam, at: onShaft, viewSize: viewSize, filter: .default)?.target == .handle("d"))
        // Handles are ignored when filtered out.
        #expect(picker.pick(scene: scene, camera: cam, at: onShaft, viewSize: viewSize, filter: .faces)?.target != .handle("d"))
        // A ray through (0, 0, 25) seen from the front maps to axis parameter 25.
        let r = cam.ray(at: screen(Vec3(0, 0, 25), cam), viewSize: viewSize)
        let s = try #require(ViewportPicker.handleAxisParameter(h, ray: r))
        #expect(abs(s - 25) < 1e-6)
        // Looking along the axis gives no parameter.
        #expect(ViewportPicker.handleAxisParameter(h, ray: Ray(origin: Vec3(0, 0, 100), direction: -Vec3.unitZ)) == nil)
    }

    @Test func bvhCacheReusedUntilVersionChanges() {
        let picker = ViewportPicker()
        var body = SceneBody(id: cubeID, mesh: DemoMeshes.cube())
        let a = picker.bvh(for: body)
        #expect(picker.bvh(for: body) === a)
        body.version += 1
        #expect(picker.bvh(for: body) !== a)
        // Different geometry with the same version is caught by the fingerprint.
        let b = picker.bvh(for: body)
        body.mesh = DemoMeshes.cube(size: 30)
        #expect(picker.bvh(for: body) !== b)
    }
}

@Suite("BVH")
struct BVHTests {
    static func mesh(_ name: String) -> Mesh {
        switch name {
        case "roundedBox": DemoMeshes.roundedBox(min: [-20, -10, 0], max: [20, 10, 15], radius: 4)
        case "sphere": DemoMeshes.sphere(radius: 12)
        default: DemoMeshes.plateWithHole(min: [-10, -10, 0], max: [10, 10, 3], holeCenter: [0, 0], holeRadius: 4)
        }
    }

    @Test(arguments: ["roundedBox", "sphere", "plateWithHole"])
    func matchesBruteForce(name: String) {
        let mesh = Self.mesh(name)
        let bvh = TriangleBVH(mesh: mesh)
        #expect(bvh.nodeCount > 1)
        #expect(bvh.maxDepth < 40)
        var rng = SystemRandomNumberGenerator()
        var hits = 0
        for _ in 0..<400 {
            let o = SIMD3<Double>(Double.random(in: -60...60, using: &rng), Double.random(in: -60...60, using: &rng),
                                  Double.random(in: -60...60, using: &rng))
            let target = SIMD3<Double>(Double.random(in: -15...15, using: &rng), Double.random(in: -10...10, using: &rng),
                                       Double.random(in: 0...12, using: &rng))
            let d = simd_normalize(target - o)
            let a = bvh.intersect(origin: o, direction: d)
            let b = bvh.intersectBruteForce(origin: o, direction: d)
            #expect((a == nil) == (b == nil))
            if let a, let b {
                hits += 1
                #expect(abs(a.t - b.t) < 1e-9)
            }
        }
        #expect(hits > 50)
    }

    @Test func axisAlignedRaysHitFlatFaces() throws {
        let bvh = TriangleBVH(mesh: DemoMeshes.cube(size: 20))
        let h = try #require(bvh.intersect(origin: [0, 0, 100], direction: [0, 0, -1]))
        #expect(abs(h.t - 90) < 1e-9)
        #expect(bvh.intersect(origin: [30, 0, 100], direction: [0, 0, -1]) == nil)
    }

    @Test func emptyMesh() {
        #expect(TriangleBVH(mesh: .empty).intersect(origin: .zero, direction: [0, 0, 1]) == nil)
    }
}
