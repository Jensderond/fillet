import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

@Suite("Camera framing")
struct FramingTests {
    static let viewSize = CGSize(width: 1000, height: 700)
    static let body = Bounds3(min: Vec3(0, 0, 0), max: Vec3(80, 30, 12))

    static let cameras: [Camera] = [
        Camera(target: Vec3(200, -40, 0), distance: 900),  // iso, far away and off to the side
        Camera(target: .zero, distance: 20, yaw: 0, pitch: .pi / 2),  // top, much too close
        Camera(target: Vec3(-50, 10, 5), distance: 300, yaw: -2.1, pitch: 0.3, projection: .orthographic),
        Camera(target: .zero, distance: 300, yaw: 0, pitch: 0),  // front
    ]

    static let insets: [ViewportInsets] = [
        .zero,
        ViewportInsets(top: 120, leading: 0, bottom: 16, trailing: 0),  // sketch bar
        ViewportInsets(top: 24, leading: 252, bottom: 16, trailing: 0),  // floating browser
    ]

    @Test(arguments: cameras, insets)
    func centresContentInTheUnobstructedRect(camera: Camera, insets: ViewportInsets) throws {
        let framed = camera.framing(Self.body, viewSize: Self.viewSize, insets: insets)
        let box = try #require(framed.screenRect(of: Self.body, viewSize: Self.viewSize))
        let safe = insets.rect(in: Self.viewSize)
        #expect(abs(box.midX - safe.midX) < 1.5)
        #expect(abs(box.midY - safe.midY) < 1.5)
        #expect(framed.frames(Self.body, viewSize: Self.viewSize, insets: insets, tolerance: 0.01))
    }

    @Test(arguments: cameras)
    func fillsTheViewUpToTheMargin(camera: Camera) throws {
        let framed = camera.framing(Self.body, viewSize: Self.viewSize, margin: 1.25)
        let box = try #require(framed.screenRect(of: Self.body, viewSize: Self.viewSize))
        // The limiting dimension uses 1 / margin of the view (the 0.5 mm padding adds a hair).
        let fill = max(box.width / Self.viewSize.width, box.height / Self.viewSize.height)
        #expect(abs(fill - 1 / 1.25) < 0.03)
    }

    @Test(arguments: cameras)
    func keepsTheViewDirectionAndProjection(camera: Camera) {
        let framed = camera.framing(Self.body, viewSize: Self.viewSize)
        #expect(framed.yaw == camera.yaw && framed.pitch == camera.pitch)
        #expect(framed.projection == camera.projection && framed.fovDegrees == camera.fovDegrees)
    }

    @Test func framesFlatSketchGeometryHeadOn() throws {
        // A sketch on the bed, looked at from above: zero thickness must still give a finite fit.
        let sketch = Bounds3(min: Vec3(-50, -50, 0), max: Vec3(50, 50, 0))
        let top = Camera(target: .zero, distance: 260, yaw: 0, pitch: .pi / 2)
        let framed = top.framing(sketch, viewSize: Self.viewSize, insets: ViewportInsets(top: 120))
        #expect(framed.distance.isFinite && framed.distance > 10)
        #expect(framed.frames(sketch, viewSize: Self.viewSize, insets: ViewportInsets(top: 120), tolerance: 0.01))
    }

    @Test func detectsContentThatNoLongerFits() {
        let framed = Camera.default.framing(Self.body, viewSize: Self.viewSize)
        #expect(framed.frames(Self.body, viewSize: Self.viewSize))
        // The inspector column takes 320 pt: the same camera now overflows the narrower view.
        let narrow = CGSize(width: 680, height: 700)
        #expect(!framed.frames(Self.body, viewSize: narrow))
        #expect(framed.framing(Self.body, viewSize: narrow).frames(Self.body, viewSize: narrow))
    }

    @Test func insetsNeverSwallowTheView() {
        let r = ViewportInsets(top: 900, leading: 2000, bottom: 0, trailing: 0).rect(in: CGSize(width: 400, height: 300))
        #expect(abs(r.width - 160) < 1e-9 && abs(r.height - 120) < 1e-9)
        #expect(ViewportInsets.zero.rect(in: CGSize(width: 400, height: 300)) == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}
