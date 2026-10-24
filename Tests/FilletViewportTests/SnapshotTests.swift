import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import FilletKernel
@testable import FilletViewport

/// Example scenes shared by the snapshot tests.
enum SampleScenes {
    static let ids = DemoMeshes.showcaseScene().bodies.map(\.id)

    static func showcase(selection: Bool) -> ViewportScene {
        var s = DemoMeshes.showcaseScene()
        if selection {
            s.selection = [.face(body: ids[1], index: 1), .edge(body: ids[0], index: 30)]
            s.hover = .face(body: ids[0], index: 1)
        }
        return s
    }

    static func overhang() -> ViewportScene {
        var s = ViewportScene(plate: BuildPlate(name: "A1 mini", size: [180, 180, 180]))
        s.bodies = [
            SceneBody(id: ids[0], mesh: DemoMeshes.tShape(center: [0, 20], width: 44, stem: 10, barThickness: 7, height: 34, depth: 16),
                      color: ViewportColor(hex: 0xE8B04A)),
            SceneBody(id: ids[1], mesh: DemoMeshes.sphere(center: [48, 4, 14], radius: 14)),
            SceneBody(id: ids[2], mesh: DemoMeshes.roundedBox(min: [-70, -10, 0], max: [-36, 18, 22], radius: 6)),
        ]
        s.overhang = OverhangStyle(thresholdDegrees: 45)
        return s
    }

    static func sketch() -> ViewportScene {
        var s = ViewportScene(plate: BuildPlate(name: "A1 mini", size: [180, 180, 180]))
        let plate = SceneBody(id: ids[1], mesh: DemoMeshes.plateWithHole(min: [-40, -30, 0], max: [40, 30, 8],
                                                                         holeCenter: [-15, 0], holeRadius: 9))
        s.bodies = [plate]
        let plane = Plane.xy.offset(by: 8)
        let rect = UUID(), circle = UUID(), cons = UUID(), slot = UUID()
        let r: [SIMD2<Double>] = [[5, -20], [32, -20], [32, 20], [5, 20]]
        let circlePts = (0...64).map { i -> SIMD2<Double> in
            let a = Double(i) / 64 * 2 * .pi
            return SIMD2(18.5 + 7 * cos(a), 0 + 7 * sin(a))
        }
        s.sketch = SketchOverlay(
            plane: plane,
            curves: [
                SketchCurve(shapeID: rect, points: r, closed: true),
                SketchCurve(shapeID: circle, points: circlePts),
                SketchCurve(shapeID: cons, points: [[-40, 0], [40, 0]], style: .construction),
                SketchCurve(shapeID: slot, points: [[-30, 22], [-5, 22]], style: .preview),
            ],
            points: r.enumerated().map { SketchPoint(shapeID: rect, index: $0.offset, position: $0.element) }
                + [SketchPoint(shapeID: circle, index: 0, position: [18.5, 0]),
                   SketchPoint(shapeID: slot, index: 0, position: [-30, 22], style: .snap)],
            regions: [
                SketchRegion(index: 0, triangles: ringTriangles(rect: r, center: [18.5, 0], radius: 7), selected: true),
                SketchRegion(index: 1, triangles: discTriangles(center: [18.5, 0], radius: 7), hover: true),
            ],
            grid: SketchGrid(spacing: 5, majorEvery: 5, extent: 120))
        s.selection = [.sketchShape(circle)]
        return s
    }

    static func extrudePreview() -> ViewportScene {
        var s = ViewportScene(plate: BuildPlate(name: "A1 mini", size: [180, 180, 180]))
        let base = DemoMeshes.roundedBox(min: [-40, -25, 0], max: [40, 25, 10], radius: 3)
        s.bodies = [SceneBody(id: ids[0], mesh: base)]
        let boss = DemoMeshes.cylinder(base: [0, 0, 10], radius: 14, height: 22)
        let cut = DemoMeshes.box(min: [22, -12, 4], max: [34, 12, 10.5])
        s.previews = [SceneBody(id: ids[1], mesh: boss, color: .previewAdd),
                      SceneBody(id: ids[2], mesh: cut, color: .previewCut)]
        s.handles = [Handle(id: "distance", origin: Vec3(0, 0, 10), direction: .unitZ, value: 22)]
        s.measures = [MeasureAnnotation(id: "h", from: Vec3(18, 0, 10), to: Vec3(18, 0, 32), label: "22 mm")]
        s.sketch = SketchOverlay(plane: Plane.xy.offset(by: 10),
                                 curves: [SketchCurve(shapeID: UUID(), points: (0...64).map { i in
                                     let a = Double(i) / 64 * 2 * .pi
                                     return SIMD2(14 * cos(a), 14 * sin(a))
                                 }, style: .selected)], grid: nil)
        return s
    }

    /// Triangles between a rectangle outline and an inner circle (both sampled by angle).
    static func ringTriangles(rect r: [SIMD2<Double>], center c: SIMD2<Double>, radius: Double) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        func rectPoint(_ a: Double) -> SIMD2<Double> {
            let d = SIMD2(cos(a), sin(a))
            var t = Double.infinity
            if d.x > 1e-9 { t = min(t, (r[1].x - c.x) / d.x) }
            if d.x < -1e-9 { t = min(t, (r[0].x - c.x) / d.x) }
            if d.y > 1e-9 { t = min(t, (r[2].y - c.y) / d.y) }
            if d.y < -1e-9 { t = min(t, (r[0].y - c.y) / d.y) }
            return c + d * t
        }
        var angles = (0..<64).map { Double($0) / 64 * 2 * .pi }
        for p in r {
            var a = atan2(p.y - c.y, p.x - c.x)
            if a < 0 { a += 2 * .pi }
            angles.append(a)
        }
        angles.sort()
        for i in 0..<angles.count {
            let a0 = angles[i], a1 = angles[(i + 1) % angles.count]
            let h0 = c + SIMD2(cos(a0), sin(a0)) * radius, h1 = c + SIMD2(cos(a1), sin(a1)) * radius
            let q0 = rectPoint(a0), q1 = rectPoint(a1)
            out += [h0, q0, q1, h0, q1, h1]
        }
        return out
    }

    static func discTriangles(center c: SIMD2<Double>, radius: Double) -> [SIMD2<Double>] {
        (0..<64).flatMap { i -> [SIMD2<Double>] in
            let a0 = Double(i) / 64 * 2 * .pi, a1 = Double(i + 1) / 64 * 2 * .pi
            return [c, c + SIMD2(cos(a0), sin(a0)) * radius, c + SIMD2(cos(a1), sin(a1)) * radius]
        }
    }
}

func writePNG(_ image: CGImage, name: String) throws -> URL {
    var dirs = [FileManager.default.temporaryDirectory.appendingPathComponent("fillet-viewport-snapshots")]
    if let extra = ProcessInfo.processInfo.environment["FILLET_SCREENSHOTS_DIR"] { dirs.append(URL(fileURLWithPath: extra)) }
    var first: URL?
    for dir in dirs {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        first = first ?? url
    }
    return first!
}

/// Fraction of pixels that differ noticeably from the left-most pixel of their row
/// (the background is a vertical gradient).
func nonBackgroundFraction(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var differing = 0, total = 0
    for y in stride(from: 0, to: h, by: 2) {
        let bi = (y * w) * 4
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 4
            let d = abs(Int(data[i]) - Int(data[bi])) + abs(Int(data[i + 1]) - Int(data[bi + 1])) + abs(Int(data[i + 2]) - Int(data[bi + 2]))
            if d > 30 { differing += 1 }
            total += 1
        }
    }
    return Double(differing) / Double(max(total, 1))
}

@MainActor
@Suite("Snapshots", .serialized)
struct SnapshotTests {
    let renderer: ViewportRenderer

    init() throws { renderer = try ViewportRenderer() }

    func render(_ scene: ViewportScene, camera: Camera, name: String, appearance: ViewportAppearance = .light,
                size: CGSize = CGSize(width: 800, height: 560)) throws -> CGImage {
        let image = try #require(renderer.snapshot(scene: scene, camera: camera, size: size, scale: 2, appearance: appearance))
        let url = try writePNG(image, name: name)
        print("snapshot: \(url.path)")
        return image
    }

    @Test func showcaseLight() throws {
        let scene = SampleScenes.showcase(selection: true)
        var cam = Camera(yaw: 0.55, pitch: 0.5)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560)
        let img = try render(scene, camera: cam, name: "viewport-showcase-light")
        #expect(img.width == 1600 && img.height == 1120)
        #expect(nonBackgroundFraction(img) > 0.1)
    }

    @Test func showcaseDarkOverhang() throws {
        let scene = SampleScenes.overhang()
        var cam = Camera(yaw: 0.3, pitch: -0.04)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560, margin: 0.8)
        let img = try render(scene, camera: cam, name: "viewport-overhang-dark", appearance: .dark)
        #expect(nonBackgroundFraction(img) > 0.1)
    }

    @Test func sketchMode() throws {
        let scene = SampleScenes.sketch()
        var cam = Camera(yaw: 0, pitch: .pi / 2 - 0.35)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560, margin: 0.95)
        cam.target = Vec3(0, 0, 8)
        let img = try render(scene, camera: cam, name: "viewport-sketch-light")
        #expect(nonBackgroundFraction(img) > 0.1)
    }

    @Test func extrudePreview() throws {
        let scene = SampleScenes.extrudePreview()
        var cam = Camera(yaw: 0.6, pitch: 0.42)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560)
        let img = try render(scene, camera: cam, name: "viewport-extrude-preview-light")
        _ = try render(scene, camera: cam, name: "viewport-extrude-preview-dark", appearance: .dark)
        #expect(nonBackgroundFraction(img) > 0.1)
    }

    @Test func orthographicWithoutPlate() throws {
        var scene = DemoMeshes.showcaseScene()
        scene.plate = nil
        scene.bodies.append(SceneBody(id: UUID(), mesh: DemoMeshes.lBracket(origin: [60, 0], width: 40, height: 30, thickness: 6, depth: 24)))
        var cam = Camera(yaw: -0.6, pitch: 0.6, projection: .orthographic)
        cam.fit(bounds: scene.modelBounds!, aspect: 800 / 560)
        let img = try render(scene, camera: cam, name: "viewport-ortho-light")
        #expect(nonBackgroundFraction(img) > 0.1)
    }

    @Test func emptySceneIsBackgroundOnly() throws {
        let img = try #require(renderer.snapshot(scene: ViewportScene(showsGroundGrid: false), camera: .default,
                                                 size: CGSize(width: 64, height: 64), scale: 1))
        #expect(nonBackgroundFraction(img) < 0.02)
    }
}
