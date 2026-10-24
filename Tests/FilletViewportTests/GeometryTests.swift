import CoreGraphics
import Foundation
import simd
import Testing
import FilletKernel
@testable import FilletViewport

@Suite("Line expansion")
struct LineExpansionTests {
    let vp = SIMD2<Float>(800, 600)

    @Test func horizontalSegmentExpandsVertically() throws {
        // Clip space with w = 1: x from -0.5 to 0.5 → 200 px … 600 px.
        let q = try #require(LineExpansion.quad(a: [-0.5, 0, 0.5, 1], b: [0.5, 0, 0.5, 1], widthPixels: 4, viewport: vp))
        #expect(q.count == 4)
        // Half width 2 px + 1 px AA margin = 3 px → 3 / 300 in NDC y.
        let dy = Float(3) / 300
        #expect(abs(q[0].y + dy) < 1e-6 && abs(q[1].y - dy) < 1e-6)
        #expect(abs(q[2].y + dy) < 1e-6 && abs(q[3].y - dy) < 1e-6)
        // Square caps extend half the width (2 px / 2 = 1 px = 1/400 NDC x) beyond the ends.
        #expect(abs(q[0].x - (-0.5 - 1 / 400)) < 1e-6)
        #expect(abs(q[3].x - (0.5 + 1 / 400)) < 1e-6)
        // Depth untouched.
        #expect(q.allSatisfy { $0.z == 0.5 })
    }

    @Test func widthIsConstantInPixelsUnderPerspective() throws {
        // Same NDC segment with w = 4 must give the same pixel offsets after the divide.
        let q = try #require(LineExpansion.quad(a: [-2, 0, 1, 4], b: [2, 0, 1, 4], widthPixels: 2, viewport: vp))
        let ndcY = q.map { $0.y / $0.w }
        #expect(abs(abs(ndcY[0]) - 2.0 / 300) < 1e-6)
        #expect(abs(abs(ndcY[1]) - 2.0 / 300) < 1e-6)
    }

    @Test func segmentBehindNearPlaneIsDropped() {
        #expect(LineExpansion.quad(a: [0, 0, -1, 1], b: [1, 0, -0.5, 1], widthPixels: 2, viewport: vp) == nil)
    }

    @Test func segmentCrossingNearPlaneIsClipped() throws {
        let q = try #require(LineExpansion.quad(a: [0, 0, -1, 1], b: [0, 1, 1, 1], widthPixels: 2, viewport: vp))
        // The clipped end lies on z = 0.
        #expect(abs(q[0].z) < 1e-6 && abs(q[1].z) < 1e-6)
    }
}

@Suite("Meshes")
struct MeshTests {
    func faceCount(_ m: Mesh) -> Int { Set(m.triangleFaces).count }

    /// Signed volume via the divergence theorem; positive for outward winding.
    func volume(_ m: Mesh) -> Double {
        var v = 0.0
        for t in 0..<m.triangleCount {
            let a = SIMD3<Double>(m.positions[Int(m.indices[3 * t])]), b = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 1])]),
                c = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 2])])
            v += simd_dot(a, simd_cross(b, c)) / 6
        }
        return v
    }

    @Test func cube() {
        let m = DemoMeshes.cube(size: 20)
        #expect(faceCount(m) == 6 && m.edges.count == 12 && m.triangleCount == 12)
        #expect(abs(volume(m) - 8000) < 1e-3)
    }

    @Test func cylinder() {
        let m = DemoMeshes.cylinder(radius: 10, height: 20, segments: 256)
        #expect(faceCount(m) == 3 && m.edges.count == 2)
        #expect(abs(volume(m) - .pi * 100 * 20) / (.pi * 100 * 20) < 0.001)
    }

    @Test func roundedBox() {
        let m = DemoMeshes.roundedBox(min: [0, 0, 0], max: [40, 30, 20], radius: 4, segments: 16)
        #expect(faceCount(m) == 26 && m.edges.count == 48)
        // Box minus the material removed by rounding: (1 - π/4) r² per unit edge length, sphere corners.
        let r = 4.0
        let edges = 4 * (32.0 + 22 + 12)
        let expected = 40.0 * 30 * 20 - (1 - .pi / 4) * r * r * edges - (8 * r * r * r - 4.0 / 3 * .pi * r * r * r)
        #expect(abs(volume(m) - expected) / expected < 0.002)
    }

    @Test func plateWithHole() {
        let m = DemoMeshes.plateWithHole(min: [0, 0, 0], max: [40, 30, 5], holeCenter: [15, 15], holeRadius: 5, segments: 256)
        #expect(faceCount(m) == 7 && m.edges.count == 14)
        let expected = 40.0 * 30 * 5 - .pi * 25 * 5
        #expect(abs(volume(m) - expected) / expected < 0.001)
    }

    @Test func extrusionAndTransforms() {
        let l = DemoMeshes.lBracket(width: 40, height: 30, thickness: 6, depth: 24)
        #expect(faceCount(l) == 8 && l.edges.count == 18)
        let area = 40.0 * 6 + 6 * 24
        #expect(abs(volume(l) - area * 24) < 1e-2)
        let b = l.bounds!
        #expect(b.min.z > -1e-4 && abs(b.max.z - 30) < 1e-4 && abs(b.max.y - 24) < 1e-4)
        let merged = DemoMeshes.merged([DemoMeshes.cube(), DemoMeshes.cube(center: [50, 0, 0])])
        #expect(faceCount(merged) == 12 && merged.edges.count == 24)
        #expect(merged.triangleFaces.max() == 11)
    }

    @Test func earClipping() {
        let poly: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 1], [1, 1], [1, 3], [0, 3]]
        let tris = DemoMeshes.earClip(poly)
        #expect(tris.count == 12)
    }

    @Test func gpuVerticesAreSplitPerFace() {
        // Two triangles of different faces sharing an edge (vertices 1 and 2).
        let m = Mesh(positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0]], normals: [], indices: [0, 1, 2, 1, 3, 2],
                     triangleFaces: [0, 1], edges: [])
        let g = GPUBody.build(m)
        #expect(g.vertices.count == 6)
        #expect(g.indices.count == 6)
        for t in 0..<2 {
            for k in 0..<3 { #expect(g.vertices[Int(g.indices[3 * t + k])].face == UInt32(t)) }
        }
        // Flat normals are generated when the mesh has none.
        #expect(abs(g.vertices[0].nz) > 0.99)
        // Meshes without shared vertices are uploaded as-is.
        let cube = DemoMeshes.cube()
        #expect(GPUBody.build(cube).vertices.count == cube.positions.count)
    }

    @Test func lineSegmentsCarryCumulativeLength() {
        let segs = GPUBody.segments([[[0, 0, 0], [3, 4, 0], [3, 4, 2]], [[0, 0, 0], [1, 0, 0]]])
        #expect(segs.count == 3)
        #expect(segs[1].dist == 5 && segs[1].id == 0)
        #expect(segs[2].dist == 0 && segs[2].id == 1)
    }

    @Test func gpuStructLayouts() {
        #expect(MemoryLayout<GPUMeshVertex>.stride == 28)
        #expect(MemoryLayout<GPULineSeg>.stride == 32)
        #expect(MemoryLayout<LineStyle>.stride == 32)
        #expect(MemoryLayout<LineDraw>.stride == 64 + 6 * 32 + 16)
        #expect(MemoryLayout<MeshDraw>.stride == 112)
        #expect(MemoryLayout<FrameUniforms>.stride == 3 * 64 + 15 * 16)
        #expect(MemoryLayout<GridDraw>.stride == 12 * 16)
        #expect(MemoryLayout<PointDraw>.stride == 5 * 48)
        #expect(MemoryLayout<HullDraw>.stride == 32)
    }
}

@MainActor
@Suite("Renderer", .serialized)
struct RendererTests {
    let renderer: ViewportRenderer
    init() throws { renderer = try ViewportRenderer() }

    func pixel(_ image: CGImage, x: Int, y: Int) -> SIMD3<Int> {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return SIMD3(Int(px[0]), Int(px[1]), Int(px[2]))
    }

    @Test func selectedFaceIsTintedBlue() throws {
        let id = UUID()
        var scene = ViewportScene(bodies: [SceneBody(id: id, mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: false)
        let cam = Camera(target: .zero, distance: 80).viewing(.front)
        let plain = try #require(renderer.snapshot(scene: scene, camera: cam, size: CGSize(width: 100, height: 100), scale: 1))
        scene.selection = [.face(body: id, index: 2)]
        let selected = try #require(renderer.snapshot(scene: scene, camera: cam, size: CGSize(width: 100, height: 100), scale: 1))
        let a = pixel(plain, x: 50, y: 50), b = pixel(selected, x: 50, y: 50)
        #expect(abs(a.x - a.z) < 20)       // neutral grey
        #expect(b.z > b.x + 40)            // blue
    }

    @Test func overhangTintSkipsBedFaces() throws {
        let floating = UUID(), onBed = UUID()
        let cam = Camera(target: Vec3(0, 0, 10), distance: 150).viewing(.bottom)
        var scene = ViewportScene(bodies: [
            SceneBody(id: floating, mesh: DemoMeshes.box(min: [-30, -10, 10], max: [-10, 10, 30])),
            SceneBody(id: onBed, mesh: DemoMeshes.box(min: [10, -10, 0], max: [30, 10, 20])),
        ], showsGroundGrid: false)
        scene.overhang = OverhangStyle(thresholdDegrees: 45)
        let img = try #require(renderer.snapshot(scene: scene, camera: cam, size: CGSize(width: 200, height: 200), scale: 1))
        // Seen from below, +X is still to the right.
        let f = pixel(img, x: 100 - Int(20 * 200 / (2 * 150 * tan(15 * Double.pi / 180))), y: 100)
        let b = pixel(img, x: 100 + Int(20 * 200 / (2 * 150 * tan(15 * Double.pi / 180))), y: 100)
        #expect(f.x > f.z + 60)            // red-orange overhang
        #expect(abs(b.x - b.z) < 25)       // bottom face on the bed stays neutral
    }

    @Test func meshUploadsAreCached() throws {
        let id = UUID()
        var body = SceneBody(id: id, mesh: DemoMeshes.cube())
        renderer.update(scene: ViewportScene(bodies: [body]))
        renderer.prepare()
        let first = try #require(renderer.gpuBodyIdentity(id))
        var scene = ViewportScene(bodies: [body])
        scene.selection = [.face(body: id, index: 0)]
        renderer.update(scene: scene)
        renderer.prepare()
        #expect(renderer.gpuBodyIdentity(id) == first)
        body.version = 1
        renderer.update(scene: ViewportScene(bodies: [body]))
        renderer.prepare()
        #expect(renderer.gpuBodyIdentity(id) != first)
        renderer.update(scene: ViewportScene())
        renderer.prepare()
        #expect(renderer.gpuBodyIdentity(id) == nil)
    }
}
