import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

/// Picked edges behind the part draw faint and finely dashed; a fillet's or chamfer's edges are
/// tested against the body before it (`ViewportScene.bodiesBefore`), not the rounded result.
@MainActor
@Suite("Picked edge depth", .serialized)
struct PickedEdgeDepthTests {
    let renderer: ViewportRenderer
    let size = CGSize(width: 240, height: 180)

    init() throws { renderer = try ViewportRenderer() }

    /// A plate with rounded corners, like the selection scenario's after its first fillet.
    static func roundedRect(halfX: Float, halfY: Float, radius r: Float, segments n: Int = 8) -> [SIMD2<Float>] {
        var pts: [SIMD2<Float>] = []
        let corners: [(SIMD2<Float>, Float)] = [
            (SIMD2(halfX - r, -halfY + r), -.pi / 2), (SIMD2(halfX - r, halfY - r), 0),
            (SIMD2(-halfX + r, halfY - r), .pi / 2), (SIMD2(-halfX + r, -halfY + r), .pi),
        ]
        for (c, start) in corners {
            for k in 0...n {
                let a = start + Float(k) / Float(n) * .pi / 2
                pts.append(c + SIMD2(cos(a), sin(a)) * r)
            }
        }
        return pts
    }

    static let outline = roundedRect(halfX: 32, halfY: 16, radius: 6)
    static let height: Float = 12

    /// The bottom outline as one dashed chain (what a fillet on it shows while editing).
    static var bottomChain: EdgeHighlight {
        EdgeHighlight(points: (outline + [outline[0]]).map { Vec3(Double($0.x), Double($0.y), 0) }, dashed: true)
    }

    /// From above and in front, so the far half of the bottom outline is behind the plate.
    var camera: Camera {
        var cam = Camera(yaw: 0.35, pitch: 0.75)
        cam.fit(bounds: Bounds3(min: Vec3(-32, -16, 0), max: Vec3(32, 16, 12)), aspect: size.width / size.height)
        return cam
    }

    /// Blueness (accent over the body's grey) at the far bottom edge's middle and the near one's.
    private func blueness(_ scene: ViewportScene, palette: ViewportPalette = .light) throws -> (far: Int, near: Int) {
        let image = try #require(renderer.snapshot(scene: scene, camera: camera, size: size, scale: 1, customPalette: palette))
        let px = pixels(image)
        func blue(at p: Vec3) -> Int {
            guard let s = camera.project(p, viewSize: size) else { return 0 }
            // The most accent-like pixel in a small window: the dashes have gaps.
            var best = Int.min
            for dy in -3...3 {
                for dx in -3...3 {
                    let x = Int(s.x) + dx, y = Int(s.y) + dy
                    guard x >= 0, y >= 0, x < Int(size.width), y < Int(size.height) else { continue }
                    let c = px[y * Int(size.width) + x]
                    best = max(best, c.z - (c.x + c.y) / 2)
                }
            }
            return best
        }
        return (blue(at: Vec3(0, 16, 0)), blue(at: Vec3(0, -16, 0)))
    }

    private func body(_ id: UUID, halfX: Float) -> SceneBody {
        SceneBody(id: id, mesh: DemoMeshes.extrudedProfile(Self.roundedRect(halfX: halfX, halfY: 16, radius: 6), height: Self.height))
    }

    @Test func aPickedEdgeBehindThePartIsFainter() throws {
        let id = UUID()
        var scene = ViewportScene(bodies: [body(id, halfX: 32)], showsGroundGrid: false)
        scene.edgeHighlights = [Self.bottomChain]
        let b = try blueness(scene)
        #expect(b.near > 80)
        #expect(b.far > 10)              // still findable…
        #expect(b.far < b.near - 40)     // …but clearly behind
    }

    @Test func increaseContrastBringsHiddenPicksUp() throws {
        var scene = ViewportScene(bodies: [body(UUID(), halfX: 32)], showsGroundGrid: false)
        scene.edgeHighlights = [Self.bottomChain]
        let normal = try blueness(scene)
        let strong = try blueness(scene, palette: ViewportPalette.light.increasedContrast)
        #expect(strong.far > normal.far + 10)
        #expect(strong.far < strong.near - 20)
    }

    @Test func aFilletsEdgesTestAgainstTheBodyBeforeIt() throws {
        // What's shown is narrower than the body before the step, so it hides nothing at x = 0
        // only if the depth test used it: the far edge is behind the body before.
        let id = UUID()
        var scene = ViewportScene(bodies: [SceneBody(id: id, mesh: DemoMeshes.extrudedProfile(
            Self.roundedRect(halfX: 32, halfY: 4, radius: 3), height: 2))], showsGroundGrid: false)
        scene.edgeHighlights = [Self.bottomChain]
        let shownOnly = try blueness(scene)
        scene.bodiesBefore = [body(id, halfX: 32)]
        let before = try blueness(scene)
        #expect(shownOnly.far > before.far + 40)
        #expect(abs(shownOnly.near - before.near) < 30)
    }

    @Test func picksOnTheShownBodyStillTestAgainstIt() throws {
        // A selected (solid) edge is an edge of what's shown: the body before doesn't hide it.
        let id = UUID()
        var scene = ViewportScene(bodies: [SceneBody(id: id, mesh: DemoMeshes.extrudedProfile(
            Self.roundedRect(halfX: 32, halfY: 4, radius: 3), height: 2))], showsGroundGrid: false)
        var chain = Self.bottomChain
        chain.dashed = false
        scene.edgeHighlights = [chain]
        let shownOnly = try blueness(scene)
        scene.bodiesBefore = [body(id, halfX: 32)]
        let before = try blueness(scene)
        #expect(abs(shownOnly.far - before.far) < 20)
    }

    /// The bottom outline picked, seen from above, light and dark, for looking at.
    @Test(arguments: ViewportAppearance.allCases)
    func showcase(_ appearance: ViewportAppearance) throws {
        let id = UUID()
        var scene = ViewportScene(bodies: [body(id, halfX: 32)], plate: BuildPlate(name: "Bed", size: SIMD3(120, 120, 120)))
        scene.edgeHighlights = [Self.bottomChain]
        scene.bodiesBefore = [body(id, halfX: 32)]
        var cam = Camera(yaw: 0.35, pitch: 0.75)
        cam.fit(bounds: Bounds3(min: Vec3(-32, -16, 0), max: Vec3(32, 16, 12)), aspect: 800 / 560)
        let image = try #require(renderer.snapshot(scene: scene, camera: cam, size: CGSize(width: 800, height: 560), scale: 2,
                                                   appearance: appearance))
        print("snapshot: \(try writePNG(image, name: "viewport-picked-bottom-chain-\(appearance.rawValue)").path)")
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
