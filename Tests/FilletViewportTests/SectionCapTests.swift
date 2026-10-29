import CoreGraphics
import Foundation
import simd
import Testing
import FilletKernel
@testable import FilletViewport

let sectionBodyID = UUID()

/// A 20 mm box with a 10 mm cavity in the middle: the cavity's walls face into it.
func hollowCube() -> Mesh {
    var inner = DemoMeshes.cube(size: 10)
    inner.normals = inner.normals.map { -$0 }
    for t in stride(from: 0, to: inner.indices.count, by: 3) { inner.indices.swapAt(t + 1, t + 2) }
    return DemoMeshes.merged([DemoMeshes.cube(size: 20), inner])
}

/// Cut at x = 0, the +x half cut away.
let cutX = SectionPlane(origin: .zero, normal: .unitX)

@MainActor
@Suite("Section caps", .serialized)
struct SectionCapTests {
    let renderer: ViewportRenderer

    init() throws { renderer = try ViewportRenderer() }

    private func render(_ mesh: Mesh, section: SectionPlane?, camera: Camera, handles: [Handle] = [],
                        curves: SectionCurves? = nil, size: Int = 200) throws -> [SIMD3<Int>] {
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: mesh)], handles: handles, showsGroundGrid: false)
        scene.section = section
        scene.sectionCurves = curves
        let image = try #require(renderer.snapshot(scene: scene, camera: camera, size: CGSize(width: size, height: size), scale: 1))
        return pixels(image)
    }

    /// Looking at the cut from the side it cuts away (the right).
    private func right(_ distance: Double = 70) -> Camera {
        Camera(target: .zero, distance: distance, projection: .orthographic).viewing(.right)
    }

    @Test func capFillsTheCutSolidOnly() throws {
        let cam = right()
        let px = try render(hollowCube(), section: cutX, camera: cam)
        // Pixels per mm, from where the cube's corner lands.
        let corner = try #require(cam.project(Vec3(0, 10, 10), viewSize: CGSize(width: 200, height: 200)))
        let scale = Double(abs(corner.x - 100)) / 10
        // The wall (between 5 and 10 mm from the middle) is capped, the cavity isn't: through it
        // the cavity's far wall shows, lit in the body colour.
        let wall = (0..<200).flatMap { y in (0..<200).map { (x: $0, y: y) } }.filter { p in
            let r = Double(max(abs(p.x - 100), abs(p.y - 100))) / scale
            return r > 5.8 && r < 9.2
        }
        let capped = wall.filter { isRed(px[$0.y * 200 + $0.x]) }.count
        #expect(Double(capped) > Double(wall.count) * 0.9)
        // (Above the middle: the origin's axis marker runs right from it.)
        let inside = Int(4 * scale)
        let cavity = (100 - inside..<97).flatMap { y in (100 - inside..<100 + inside).map { px[y * 200 + $0] } }
        #expect(!cavity.isEmpty && cavity.filter(isRed).isEmpty)
    }

    @Test func capIsHatchedAtAnyZoom() throws {
        // Light fill and dark hatch lines along a row across the cap, about as many lines per
        // pixel whether the cut is seen from close or far.
        func crossings(_ distance: Double) throws -> Int {
            let px = try render(DemoMeshes.cube(size: 20), section: cutX, camera: right(distance), size: 300)
            let row = (60..<240).map { px[150 * 300 + $0] }
            let lum = row.map { $0.x + $0.y + $0.z }
            let mid = (lum.max()! + lum.min()!) / 2
            #expect(lum.max()! - lum.min()! > 60)
            return zip(lum, lum.dropFirst()).filter { ($0 < mid) != ($1 < mid) }.count
        }
        let near = try crossings(40), far = try crossings(120)
        #expect(near >= 8 && far >= 8)
        #expect(Double(max(near, far)) / Double(min(near, far)) < 2.2)
    }

    @Test func nothingShowsOfTheCapFromTheKeptSide() throws {
        let left = Camera(target: .zero, distance: 70, projection: .orthographic).viewing(.left)
        let plain = try render(DemoMeshes.cube(size: 20), section: nil, camera: left)
        let cut = try render(DemoMeshes.cube(size: 20), section: cutX, camera: left)
        #expect(cut.filter(isRed).isEmpty)
        // Only the faint silhouette of the cut-away right face goes.
        let changed = zip(plain, cut).filter { difference($0, $1) > 60 }.count
        #expect(changed < 40, "\(changed) of \(plain.count)")
    }

    @Test func handlesOnTheCutSideStillDraw() throws {
        let green = ViewportColor(hex: 0x00C000)
        let handle = Handle(id: "h", origin: Vec3(14, 0, 0), direction: .unitY, value: 0, color: green)
        let cam = Camera(target: .zero, distance: 90, yaw: 0.4, pitch: 0.3)
        func greenCount(_ section: SectionPlane?) throws -> Int {
            try render(DemoMeshes.cube(size: 20), section: section, camera: cam, handles: [handle])
                .filter { $0.y > $0.x + 60 && $0.y > $0.z + 60 }.count
        }
        let plain = try greenCount(nil)
        #expect(plain > 40)
        #expect(Double(try greenCount(cutX)) > Double(plain) * 0.9)
    }

    /// Without the kernel's lines the outline is sliced from the mesh (on the GPU): ink all round
    /// the cap's rim. Once lines are in for this plane they are drawn instead; lines made for
    /// another plane are not.
    @Test func outlineIsTheMeshesUntilExactLinesComeForThisPlane() throws {
        let cam = right()
        let size = CGSize(width: 200, height: 200)
        let rim = Int(try #require(cam.project(Vec3(0, 10, 0), viewSize: size)).x.rounded())
        let line = Int(try #require(cam.project(Vec3(0, 3, 0), viewSize: size)).x.rounded())
        // Rows (of the cap's middle) where column x of `a` is inked darker than in `b`.
        func darker(_ a: [SIMD3<Int>], than b: [SIMD3<Int>], column x: Int) -> Int {
            (70..<130).filter { y in (x - 1...x + 1).contains { c in
                let p = a[y * 200 + c], q = b[y * 200 + c]
                return (q.x + q.y + q.z) - (p.x + p.y + p.z) > 60
            } }.count
        }
        let lines = SectionCurves.Lines(version: 0, lines: [[SIMD3(0, 3, -8), SIMD3(0, 3, 8)]])
        let sliced = try render(DemoMeshes.cube(size: 20), section: cutX, camera: cam)
        let exact = try render(DemoMeshes.cube(size: 20), section: cutX, camera: cam,
                               curves: SectionCurves(plane: cutX, bodies: [sectionBodyID: lines]))
        let stale = try render(DemoMeshes.cube(size: 20), section: cutX, camera: cam,
                               curves: SectionCurves(plane: SectionPlane(origin: Vec3(1, 0, 0), normal: .unitX), bodies: [sectionBodyID: lines]))
        #expect(darker(sliced, than: exact, column: rim) > 55, "the mesh's outline runs down the cap's side")
        #expect(darker(exact, than: sliced, column: line) > 55, "the exact lines are drawn in its place")
        #expect(darker(stale, than: sliced, column: line) == 0 && darker(stale, than: sliced, column: rim) == 0
                && darker(sliced, than: stale, column: rim) == 0, "lines made for another plane are not")
    }

    /// A drag step moves the plane and swaps the handles without a new scene: the meshes stay
    /// uploaded and the exact lines, made for where the plane was, give way to the mesh's.
    @Test func movingTheSectionKeepsTheScene() throws {
        let lines = SectionCurves.Lines(version: 0, lines: [[SIMD3(0, 3, -8), SIMD3(0, 3, 8)]])
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: false)
        scene.section = cutX
        scene.sectionCurves = SectionCurves(plane: cutX, bodies: [sectionBodyID: lines])
        renderer.update(scene: scene)
        renderer.prepare()
        let gpu = renderer.gpuBodyIdentity(sectionBodyID)
        let updates = renderer.sceneUpdates
        let moved = SectionPlane(origin: Vec3(4, 0, 0), normal: .unitX)
        let arrow = Handle(id: "section.offset", origin: .zero, direction: .unitX, value: 4)
        renderer.updateSection(moved, handles: [arrow])
        renderer.prepare()
        #expect(renderer.sceneUpdates == updates && renderer.gpuBodyIdentity(sectionBodyID) == gpu)
        #expect(renderer.scene.section == moved && renderer.scene.handles == [arrow])
        let px = try #require(renderer.snapshot(scene: renderer.scene, camera: right(), size: CGSize(width: 200, height: 200), scale: 1))
        #expect(pixels(px).filter(isRed).count > 2000, "the cap is drawn at the moved plane")
    }

    @Test func outlineRunsAroundTheCut() {
        let segments = cutX.outline(of: DemoMeshes.cube(size: 20))
        #expect(segments.allSatisfy { abs($0.0.x) < 1e-5 && abs($0.1.x) < 1e-5 })
        let length = segments.reduce(0) { $0 + Double(simd_distance($1.0, $1.1)) }
        #expect(abs(length - 80) < 1e-3)
        #expect(SectionPlane(origin: Vec3(30, 0, 0), normal: .unitX).outline(of: DemoMeshes.cube(size: 20)).isEmpty)
    }

    @Test func capPolygonSpansTheCutThroughTheBox() {
        let box = Bounds3(min: Vec3(-10, -10, -10), max: Vec3(10, 10, 10))
        let square = cutX.polygon(through: box)
        #expect(square.count == 4)
        #expect(square.allSatisfy { abs($0.x) < 1e-9 && abs($0.y) > 10 && abs($0.z) > 10 })
        // A diagonal cut through a corner region is a hexagon at most, never past the box.
        let tilted = SectionPlane(origin: .zero, normal: Vec3(1, 1, 1)).polygon(through: box)
        #expect(tilted.count == 6)
        #expect(SectionPlane(origin: Vec3(0, 0, 50), normal: .unitZ).polygon(through: box).isEmpty)
    }

    @Test func neighbouringBodiesHatchDifferently() {
        let angles = (0..<6).map { SectionPlane.hatchAngle(index: $0) }
        for i in 0..<6 {
            for j in 0..<6 where i != j {
                #expect(abs(angles[i] - angles[j]) >= .pi / 6 - 1e-9)
            }
        }
    }
}

private func isRed(_ c: SIMD3<Int>) -> Bool { c.x > c.y + 40 && c.x > c.z + 40 }

private func difference(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
    abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)
}

private func pixels(_ image: CGImage) -> [SIMD3<Int>] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<(w * h)).map { SIMD3(Int(data[$0 * 4]), Int(data[$0 * 4 + 1]), Int(data[$0 * 4 + 2])) }
}
