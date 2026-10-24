import CoreGraphics
import Foundation
import simd
import Testing
import FilletKernel
@testable import FilletViewport

private let viewSize = CGSize(width: 800, height: 600)

private func distance(_ p: Vec3, toRay r: Ray) -> Double {
    let t = (p - r.origin).dot(r.direction)
    return (r.point(at: t) - p).length
}

private func approx(_ a: Vec3, _ b: Vec3, _ eps: Double = 1e-9) -> Bool { a.distance(to: b) < eps }

@Suite("Camera")
struct CameraTests {
    static let cameras: [Camera] = [
        Camera(target: Vec3(5, -3, 2), distance: 250, yaw: 0.7, pitch: 0.4),
        Camera(target: .zero, distance: 80, yaw: -2.1, pitch: -0.3, projection: .orthographic),
        Camera(target: Vec3(10, 10, 10), distance: 40, yaw: 0, pitch: .pi / 2),
        Camera(target: .zero, distance: 300, yaw: .pi, pitch: -.pi / 2, projection: .orthographic, fovDegrees: 45),
    ]

    @Test(arguments: cameras)
    func projectRayRoundTrip(camera: Camera) throws {
        let points = [Vec3(0, 0, 0), Vec3(12, -7, 3), Vec3(-20, 15, 8), camera.target + camera.right * 10]
        for p in points {
            let s = try #require(camera.project(p, viewSize: viewSize))
            let r = camera.ray(at: s, viewSize: viewSize)
            #expect(distance(p, toRay: r) < 1e-6 * max(camera.distance, 1))
        }
    }

    @Test(arguments: cameras)
    func targetProjectsToCenter(camera: Camera) throws {
        let s = try #require(camera.project(camera.target, viewSize: viewSize))
        #expect(abs(s.x - 400) < 1e-6 && abs(s.y - 300) < 1e-6)
        let r = camera.ray(at: CGPoint(x: 400, y: 300), viewSize: viewSize)
        #expect(approx(r.direction, camera.forward))
    }

    @Test(arguments: cameras)
    func basisIsOrthonormalAndRightHanded(camera: Camera) {
        let r = camera.right, u = camera.up, b = camera.back
        #expect(abs(r.length - 1) < 1e-12 && abs(u.length - 1) < 1e-12 && abs(b.length - 1) < 1e-12)
        #expect(abs(r.dot(u)) < 1e-12 && abs(r.dot(b)) < 1e-12 && abs(u.dot(b)) < 1e-12)
        #expect(approx(r.cross(u), b))
    }

    @Test(arguments: cameras)
    func matricesMatchProject(camera: Camera) throws {
        let aspect = Double(viewSize.width / viewSize.height)
        let m = camera.projectionMatrixD(aspect: aspect, bounds: Bounds3(min: Vec3(-50, -50, -50), max: Vec3(50, 50, 50)))
            * camera.viewMatrixD
        for p in [Vec3(3, 4, 5), Vec3(-10, 2, -1)] {
            let c = m * SIMD4(p.x, p.y, p.z, 1)
            let ndc = SIMD2(c.x / c.w, c.y / c.w)
            let s = try #require(camera.project(p, viewSize: viewSize))
            #expect(abs((ndc.x + 1) * 0.5 * 800 - Double(s.x)) < 1e-6)
            #expect(abs((1 - ndc.y) * 0.5 * 600 - Double(s.y)) < 1e-6)
            #expect(c.z / c.w >= 0 && c.z / c.w <= 1)
        }
    }

    @Test func standardViews() {
        var c = Camera(target: .zero, distance: 100)
        c.setView(.front)
        #expect(approx(c.eye, Vec3(0, -100, 0)))
        #expect(approx(c.right, .unitX) && approx(c.up, .unitZ))
        c.setView(.right)
        #expect(approx(c.eye, Vec3(100, 0, 0)))
        #expect(approx(c.right, .unitY))
        c.setView(.top)
        #expect(approx(c.eye, Vec3(0, 0, 100)))
        #expect(approx(c.right, .unitX) && approx(c.up, .unitY))
        c.setView(.bottom)
        #expect(approx(c.eye, Vec3(0, 0, -100)))
        c.setView(.iso)
        let d = c.back
        #expect(abs(d.x - 1 / 3.0.squareRoot()) < 1e-9 && abs(d.y + 1 / 3.0.squareRoot()) < 1e-9 && abs(d.z - 1 / 3.0.squareRoot()) < 1e-9)
    }

    @Test func fitShowsWholeBounds() throws {
        let b = Bounds3(min: Vec3(-30, 10, 0), max: Vec3(70, 40, 25))
        for proj in Camera.Projection.allCases {
            for yaw in stride(from: -3.0, to: 3.0, by: 0.9) {
                var c = Camera(yaw: yaw, pitch: 0.4, projection: proj)
                c.fit(bounds: b, aspect: 800 / 600)
                #expect(approx(c.target, b.center))
                for i in 0..<8 {
                    let p = Vec3(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z)
                    let s = try #require(c.project(p, viewSize: viewSize))
                    #expect(s.x >= 0 && s.x <= 800 && s.y >= 0 && s.y <= 600)
                }
            }
        }
    }

    @Test func orbitAroundPivotKeepsPivotOnScreen() throws {
        var c = Camera(target: Vec3(0, 0, 0), distance: 200, yaw: 0.3, pitch: 0.2)
        let pivot = Vec3(20, 5, 10)
        let before = try #require(c.project(pivot, viewSize: viewSize))
        c.orbit(drag: CGSize(width: 60, height: -25), pivot: pivot)
        let after = try #require(c.project(pivot, viewSize: viewSize))
        #expect(abs(before.x - after.x) < 1e-6 && abs(before.y - after.y) < 1e-6)
        #expect(abs(c.distance - 200) < 1e-12)
    }

    @Test func pitchIsClamped() {
        var c = Camera(pitch: 1.4)
        c.orbit(deltaYaw: 0, deltaPitch: 1)
        #expect(c.pitch == .pi / 2)
        c.orbit(deltaYaw: 0, deltaPitch: -5)
        #expect(c.pitch == -.pi / 2)
    }

    @Test(arguments: Camera.Projection.allCases)
    func zoomKeepsAnchorOnScreen(projection: Camera.Projection) throws {
        var c = Camera(distance: 200, yaw: 0.5, pitch: 0.3, projection: projection)
        let loc = CGPoint(x: 600, y: 150)
        let anchor = try #require(c.ray(at: loc, viewSize: viewSize).intersect(Plane(origin: c.target, normal: c.back, xDir: c.right)))
        c.zoom(factor: 0.5, at: loc, viewSize: viewSize)
        #expect(abs(c.distance - 100) < 1e-9)
        let s = try #require(c.project(anchor, viewSize: viewSize))
        #expect(abs(s.x - loc.x) < 1e-6 && abs(s.y - loc.y) < 1e-6)
    }

    @Test(arguments: Camera.Projection.allCases)
    func panFollowsDrag(projection: Camera.Projection) throws {
        var c = Camera(distance: 150, yaw: 1.0, pitch: 0.5, projection: projection)
        let p = c.target
        let before = try #require(c.project(p, viewSize: viewSize))
        c.pan(translation: CGSize(width: 40, height: -30), viewSize: viewSize)
        let after = try #require(c.project(p, viewSize: viewSize))
        #expect(abs(after.x - before.x - 40) < 1e-6 && abs(after.y - before.y + 30) < 1e-6)
    }

    @Test func lookingAtPlanes() {
        let base = Camera(distance: 120)
        for plane in [Plane.xy, Plane.xz, Plane.yz, Plane.xy.flipped(), Plane(origin: Vec3(1, 2, 3), normal: Vec3(1, 1, 1), xDir: .unitX)] {
            let c = base.looking(at: plane)
            #expect(approx(c.forward, -plane.normal, 1e-9))
            #expect(approx(c.target, plane.origin))
        }
        let top = base.looking(at: .xy)
        #expect(approx(top.right, .unitX) && approx(top.up, .unitY))
        let front = base.looking(at: .xz)
        #expect(approx(front.right, .unitX) && approx(front.up, .unitZ))
        let under = base.looking(at: Plane.xy.flipped())
        #expect(approx(under.right, Plane.xy.flipped().xDir) && approx(under.up, Plane.xy.flipped().yDir))
    }

    @Test func interpolationEndpointsAndShortestYaw() {
        let a = Camera(target: .zero, distance: 100, yaw: 3.0, pitch: 0.1)
        let b = Camera(target: Vec3(10, 0, 0), distance: 400, yaw: -3.0, pitch: 0.5)
        #expect(Camera.interpolate(a, b, t: 0).isApproximatelyEqual(to: a))
        #expect(Camera.interpolate(a, b, t: 1).isApproximatelyEqual(to: b))
        let mid = Camera.interpolate(a, b, t: 0.5)
        // Shortest path between 3.0 and -3.0 crosses ±π.
        #expect(abs(abs(mid.yaw) - .pi) < 1e-9)
        #expect(abs(mid.distance - 200) < 1e-9)
    }

    @Test func codableRoundTrip() throws {
        let c = Camera(target: Vec3(1, 2, 3), distance: 42, yaw: 0.25, pitch: -0.5, projection: .orthographic, fovDegrees: 40)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Camera.self, from: data) == c)
    }
}
