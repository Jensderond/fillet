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
                        size: Int = 200) throws -> [SIMD3<Int>] {
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: mesh)], handles: handles, showsGroundGrid: false)
        scene.section = section
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
