import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

@MainActor
@Suite("Visual styles", .serialized)
struct VisualStyleTests {
    let renderer: ViewportRenderer

    init() throws { renderer = try ViewportRenderer() }

    private func render(_ style: VisualStyle, camera: Camera, size: Int = 160) throws -> [SIMD3<Int>] {
        var scene = ViewportScene(bodies: [SceneBody(id: UUID(), mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: false)
        scene.visualStyle = style
        let image = try #require(renderer.snapshot(scene: scene, camera: camera, size: CGSize(width: size, height: size), scale: 1))
        return pixels(image)
    }

    private var front: Camera { Camera(target: .zero, distance: 80).viewing(.front) }
    private var corner: Camera { Camera(target: .zero, distance: 80, yaw: 0.6, pitch: 0.5) }

    @Test func wireframeLeavesFacesOpen() throws {
        let shaded = try render(.shadedWithEdges, camera: front)
        let wire = try render(.wireframe, camera: front)
        // Off centre: the origin's axis marker runs right from the centre, and shows through open faces.
        let centre = 64 * 160 + 64, background = 64 * 160
        #expect(distance(wire[centre], wire[background]) < 12)
        #expect(distance(shaded[centre], shaded[background]) > 30)
    }

    @Test func xrayShowsTheBackgroundThroughFaces() throws {
        let shaded = try render(.shadedWithEdges, camera: front)
        let xray = try render(.xray, camera: front)
        let centre = 64 * 160 + 64, background = 64 * 160
        let toBackground = distance(xray[centre], xray[background])
        #expect(toBackground > 4)
        #expect(toBackground < distance(shaded[centre], shaded[background]))
    }

    @Test func hiddenLineFacesArePaper() throws {
        let img = try render(.hiddenLine, camera: front)
        let c = img[64 * 160 + 64]
        #expect(c.x > 245 && c.y > 245 && c.z > 245)
    }

    @Test func hiddenEdgesAddLinesAndShadedDropsThem() throws {
        func ink(_ px: [SIMD3<Int>]) -> Int { px.filter { $0.x + $0.y + $0.z < 3 * 75 }.count }
        let shaded = try render(.shaded, camera: corner)
        let edges = try render(.shadedWithEdges, camera: corner)
        let hidden = try render(.shadedWithHiddenEdges, camera: corner)
        let drawing = try render(.hiddenLine, camera: corner)
        #expect(ink(shaded) < ink(edges) / 4)
        // Where turning hidden edges on changes the picture is where they run…
        let hiddenRuns = edges.indices.filter { distance(edges[$0], hidden[$0]) > 40 }
        #expect(hiddenRuns.count > 60)
        // …and the line drawing leaves those places paper. (Away from visible lines: a dash under
        // one darkens its anti-aliased fringe a little.)
        let clear = hiddenRuns.filter { i in
            (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in
                let j = i + dy * 160 + dx
                return !edges.indices.contains(j) || edges[j].x + edges[j].y + edges[j].z > 3 * 120
            } }
        }
        #expect(clear.count > 40)
        #expect(clear.allSatisfy { drawing[$0].x > 240 && drawing[$0].y > 240 && drawing[$0].z > 240 })
    }

    @Test(arguments: [VisualStyle.wireframe, .xray, .hiddenLine])
    func pickedFaceShowsWithoutLitFaces(_ style: VisualStyle) throws {
        let id = UUID()
        var scene = ViewportScene(bodies: [SceneBody(id: id, mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: false)
        scene.visualStyle = style
        let plain = pixels(try #require(renderer.snapshot(scene: scene, camera: front, size: CGSize(width: 160, height: 160), scale: 1)))
        scene.selection = [.face(body: id, index: 2)]
        let picked = pixels(try #require(renderer.snapshot(scene: scene, camera: front, size: CGSize(width: 160, height: 160), scale: 1)))
        let a = plain[64 * 160 + 64], b = picked[64 * 160 + 64]
        #expect(b.z > b.x + 40)              // blue
        #expect(b.z - b.x > a.z - a.x + 30)  // and clearly bluer than before
    }

    @Test func pickedEdgeShowsInShaded() throws {
        let id = UUID()
        var scene = ViewportScene(bodies: [SceneBody(id: id, mesh: DemoMeshes.cube(size: 20))], showsGroundGrid: false)
        scene.visualStyle = .shaded
        let image = { pixels(try #require(self.renderer.snapshot(scene: scene, camera: self.corner,
                                                                 size: CGSize(width: 160, height: 160), scale: 1))) }
        let plain = try image()
        scene.selection = Set((0..<12).map { PickTarget.edge(body: id, index: $0) })
        let picked = try image()
        let blue = { (px: [SIMD3<Int>]) in px.filter { $0.z > $0.x + 80 }.count }
        #expect(blue(picked) > blue(plain) + 100)
    }

    /// Every style on the showcase scene, light and dark, for looking at.
    @Test(arguments: VisualStyle.allCases)
    func showcase(_ style: VisualStyle) throws {
        var scene = SampleScenes.showcase(selection: true)
        scene.visualStyle = style
        var cam = Camera(yaw: 0.55, pitch: 0.5)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560)
        for appearance in ViewportAppearance.allCases {
            let image = try #require(renderer.snapshot(scene: scene, camera: cam, size: CGSize(width: 800, height: 560), scale: 2,
                                                       appearance: appearance))
            let url = try writePNG(image, name: "viewport-style-\(style.rawValue)-\(appearance.rawValue)")
            print("snapshot: \(url.path)")
            #expect(nonBackgroundFraction(image) > 0.05)
        }
    }
}

private func pixels(_ image: CGImage) -> [SIMD3<Int>] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<(w * h)).map { SIMD3(Int(data[$0 * 4]), Int(data[$0 * 4 + 1]), Int(data[$0 * 4 + 2])) }
}

private func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
    abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)
}
