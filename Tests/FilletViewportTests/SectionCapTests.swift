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
                        curves: SectionCurves? = nil, size: Int = 200, scale: CGFloat = 1) throws -> [SIMD3<Int>] {
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: mesh)], handles: handles, showsGroundGrid: false)
        scene.section = section
        scene.sectionCurves = curves
        return try render(scene, camera: camera, size: size, scale: scale)
    }

    private func render(_ scene: ViewportScene, camera: Camera, size: Int = 200, scale: CGFloat = 1) throws -> [SIMD3<Int>] {
        let image = try #require(renderer.snapshot(scene: scene, camera: camera, size: CGSize(width: size, height: size), scale: scale))
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
        // Hairlines darker than the fill along a row across the cap (on a 2× screen), about as
        // many lines per point whether the cut is seen from close or far: the spacing steps by
        // powers of two, so never more than twice as many.
        func perPoint(_ distance: Double) throws -> Double {
            let px = try render(DemoMeshes.cube(size: 20), section: cutX, camera: right(distance), size: 300, scale: 2)
            let row = (0..<600).map { px[300 * 600 + $0] }.filter(isRed)
            let lum = row.map { $0.x + $0.y + $0.z }
            let fill = lum.sorted()[lum.count * 3 / 4]
            let dark = lum.map { $0 < fill - 40 }
            let lines = zip(dark, dark.dropFirst()).filter { !$0 && $1 }.count
            #expect(row.count > 40 && lines >= 5, "\(row.count) red px, \(lines) lines")
            return Double(lines) / Double(row.count) * 2
        }
        let near = try perPoint(40), far = try perPoint(120)
        #expect(Double(max(near, far)) / Double(min(near, far)) < 2.2, "\(near) \(far) lines a point")
        // About one every 3.5 to 7 points across them, so 5 to 10 along a row at 45°.
        #expect(near > 1 / 10.5 && near < 1 / 4.6 && far > 1 / 10.5 && far < 1 / 4.6, "\(near) \(far) lines a point")
    }

    @Test func nothingShowsOfTheCapFromTheKeptSide() throws {
        let left = Camera(target: .zero, distance: 70, projection: .orthographic).viewing(.left)
        let plain = try render(DemoMeshes.cube(size: 20), section: nil, camera: left)
        let cut = try render(DemoMeshes.cube(size: 20), section: cutX, camera: left)
        #expect(cut.filter(isRed).isEmpty)
        // Only the rim changes: the cut's outline, right behind the silhouette, peeks round it.
        let corner = try #require(left.project(Vec3(-10, 10, 10), viewSize: CGSize(width: 200, height: 200)))
        let half = abs(Double(corner.x) - 100)
        let changed = (0..<200 * 200).filter { i in
            let r = Double(max(abs(i % 200 - 100), abs(i / 200 - 100)))
            return abs(r - half) > 2.5 && difference(plain[i], cut[i]) > 60
        }.count
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
        // The exact lines are only drawn round a cap, never over it: one off the cube's side.
        let line = Int(try #require(cam.project(Vec3(0, 13, 0), viewSize: size)).x.rounded())
        // Rows (of the cap's middle) where column x of `a` is inked darker than in `b`.
        func darker(_ a: [SIMD3<Int>], than b: [SIMD3<Int>], column x: Int) -> Int {
            (70..<130).filter { y in (x - 1...x + 1).contains { c in
                let p = a[y * 200 + c], q = b[y * 200 + c]
                return (q.x + q.y + q.z) - (p.x + p.y + p.z) > 60
            } }.count
        }
        let lines = SectionCurves.Lines(version: 0, lines: [[SIMD3(0, 13, -8), SIMD3(0, 13, 8)]])
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

    /// A 0.8 mm wall cut across, seen straight at the cut (about 5 px wide on a 2× screen): the
    /// outline runs round the cap, not over it, so the cap keeps its whole width.
    @Test func outlineLeavesAThinWallsCapWhole() throws {
        let wall = DemoMeshes.box(min: SIMD3(-10, -0.4, -10), max: SIMD3(10, 0.4, 10))
        let cam = Camera(target: .zero, distance: 70, projection: .orthographic).viewing(.right)
        let px = try render(wall, section: cutX, camera: cam, scale: 2)
        let size = CGSize(width: 200, height: 200)
        let a = try #require(cam.project(Vec3(0, -0.4, 0), viewSize: size)), b = try #require(cam.project(Vec3(0, 0.4, 0), viewSize: size))
        let width = abs(b.x - a.x) * 2
        let reds = (100..<300).map { y in (0..<400).filter { isRed(px[y * 400 + $0]) }.count }
        let median = reds.sorted()[reds.count / 2]
        #expect(width > 4 && Double(median) >= Double(width) - 1.5, "\(median) red px across a \(width) px wall")
    }

    /// Bodies inside one another, all in the default colour, cap in different colours.
    @Test func nestedBodiesCapInTheirOwnColours() throws {
        let outer = SceneBody(id: UUID(), mesh: hollowCube())
        let inner = SceneBody(id: UUID(), mesh: DemoMeshes.cube(size: 9.6))
        var scene = ViewportScene(bodies: [outer, inner], showsGroundGrid: false)
        scene.section = cutX
        let px = try render(scene, camera: right(), scale: 1)
        let cam = right(), size = CGSize(width: 200, height: 200)
        let scale = Double(abs(try #require(cam.project(Vec3(0, 10, 10), viewSize: size)).x - 100)) / 10
        func average(_ r0: Double, _ r1: Double) -> SIMD3<Double> {
            let ps = (0..<200 * 200).filter { i in
                let r = Double(max(abs(i % 200 - 100), abs(i / 200 - 100))) / scale
                return r > r0 && r < r1
            }.map { px[$0] }
            let sum = ps.reduce(SIMD3<Int>.zero, &+)
            return SIMD3(Double(sum.x), Double(sum.y), Double(sum.z)) / Double(max(ps.count, 1))
        }
        let wall = average(6, 9), core = average(0.5, 4)
        #expect(wall.x > wall.z + 30, "the outer body's cap is red: \(wall)")
        #expect(core.z > core.x + 10, "the inner body's is slate blue: \(core)")
    }

    /// Section only: the caps and nothing else of the body.
    @Test func sectionOnlyDrawsJustTheCaps() throws {
        let cam = Camera(target: .zero, distance: 90, yaw: 0.9, pitch: 0.4)
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: hollowCube())], showsGroundGrid: false)
        scene.section = cutX
        let empty = try render(ViewportScene(showsGroundGrid: false), camera: cam)
        let cut = try render(scene, camera: cam)
        scene.sectionOnly = true
        let only = try render(scene, camera: cam)
        let body = zip(empty, cut).filter { difference($0, $1) > 40 && !isRed($1) }.count
        let leftOver = zip(empty, only).filter { difference($0, $1) > 40 && !isRed($1) }.count
        #expect(body > 2000 && only.filter(isRed).count > 1500)
        // Only the caps' anti-aliased rims are left of the rest.
        #expect(leftOver < body / 8, "\(leftOver) of \(body) body pixels still drawn, \(only.filter(isRed).count) red")
    }

    /// A section drawing: the cap flat (no light on it), no ground grid, and what's left of the
    /// body as lines on the background.
    @Test func sectionDrawingIsFlatLinesAndNoGround() throws {
        let cam = Camera(target: .zero, distance: 90, yaw: 0.9, pitch: 0.4)
        var scene = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: true)
        scene.section = cutX
        scene.sectionDrawing = true
        let drawing = try render(scene, camera: cam, size: 300)
        let empty = try render(ViewportScene(showsGroundGrid: false), camera: cam, size: 300)
        // The faces left of the cube are the background now: only lines and the cap differ.
        let other = zip(empty, drawing).filter { difference($0, $1) > 40 && !isRed($1) }.count
        #expect(other < 1500, "\(other) pixels of faces or grid")
        // The cap's fill (the light pixels, past the hatch) is one flat colour.
        let reds = drawing.filter(isRed).map { $0.x + $0.y + $0.z }.sorted()
        #expect(reds.count > 2000)
        let fill = reds[(reds.count * 3 / 5)...]
        #expect(fill.last! - fill.first! < 24, "cap fill spread \(fill.last! - fill.first!)")
    }

    /// What a section cuts away casts no shadow on the ground: a block standing on it, its +x half
    /// cut away, darkens the ground on the -x side only.
    @Test func shadowIsOfWhatIsLeft() throws {
        let block = DemoMeshes.box(min: SIMD3(-15, -5, 0), max: SIMD3(15, 5, 10))
        let cam = Camera(target: Vec3(0, 0, 0), distance: 160, yaw: 0, pitch: 1.45, projection: .orthographic)
        func darkened(_ section: SectionPlane?) throws -> (left: Int, right: Int) {
            var lit = ViewportScene(bodies: [SceneBody(id: sectionBodyID, mesh: block)], showsGroundGrid: true)
            lit.section = section
            let ground = try render(ViewportScene(showsGroundGrid: true), camera: cam, size: 300)
            let px = try render(lit, camera: cam, size: 300)
            let size = CGSize(width: 300, height: 300)
            // Rows above and below the block, where only the shadow lands.
            let top = Int(try #require(cam.project(Vec3(0, 6.5, 0), viewSize: size)).y.rounded())
            let x0 = Int(try #require(cam.project(Vec3(-12, 0, 0), viewSize: size)).x.rounded())
            let x1 = Int(try #require(cam.project(Vec3(12, 0, 0), viewSize: size)).x.rounded())
            func dark(_ x: Int) -> Bool { difference(ground[top * 300 + x], px[top * 300 + x]) > 6 }
            return ((min(x0, x1)..<150).filter(dark).count, (151..<max(x0, x1)).filter(dark).count)
        }
        let whole = try darkened(nil), cut = try darkened(cutX)
        #expect(whole.left > 10 && whole.right > 10, "the whole block's shadow: \(whole)")
        #expect(cut.left > 10 && cut.right < whole.right / 3, "the cut block's: \(cut)")
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

