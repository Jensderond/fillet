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
        Camera(target: Vec3(3, 1, -2), distance: 120, yaw: 1.2, pitch: 0.5, roll: 0.9),
        Camera(target: .zero, distance: 90, yaw: 0, pitch: 0, roll: -.pi / 2, projection: .orthographic),
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

    /// Every direction of the view cube: 6 faces, 12 edges, 8 corners.
    static let cubeDirections: [Vec3] = {
        var out: [Vec3] = []
        for x in [-1.0, 0, 1] { for y in [-1.0, 0, 1] { for z in [-1.0, 0, 1] where !(x == 0 && y == 0 && z == 0) { out.append(Vec3(x, y, z)) } } }
        return out
    }()

    @Test func cubeHas26Directions() {
        #expect(Self.cubeDirections.count == 26)
    }

    @Test(arguments: cubeDirections)
    func viewAnglesLookFromTheDirection(d: Vec3) {
        let a = Camera.viewAngles(lookingFrom: d, currentYaw: 0.3)
        let c = Camera(yaw: a.yaw, pitch: a.pitch)
        #expect(c.back.dot(d.normalized) > 1 - 1e-9)
    }

    @Test func viewAnglesOfTheFacesAreTheStandardViews() {
        let faces: [(Vec3, Camera.StandardView)] = [
            (Vec3(0, -1, 0), .front), (Vec3(0, 1, 0), .back), (Vec3(1, 0, 0), .right),
            (Vec3(-1, 0, 0), .left), (Vec3(0, 0, 1), .top), (Vec3(0, 0, -1), .bottom),
        ]
        for (d, view) in faces {
            let a = Camera.viewAngles(lookingFrom: d, currentYaw: 0)
            #expect(a.yaw == view.angles.yaw, "yaw of \(view)")
            #expect(a.pitch == view.angles.pitch, "pitch of \(view)")
        }
        // A face is the same wherever the camera is looking from now (but up / down).
        for yaw in [-2.0, 0.7, 3.0] {
            for (d, view) in faces where d.z == 0 {
                let a = Camera.viewAngles(lookingFrom: d, currentYaw: yaw)
                #expect(a.yaw == view.angles.yaw && a.pitch == 0)
            }
        }
    }

    @Test func viewAnglesOfTheCornerIsTheIsoView() {
        let a = Camera.viewAngles(lookingFrom: Vec3(1, -1, 1), currentYaw: 0)
        #expect(abs(a.yaw - Camera.StandardView.iso.angles.yaw) < 1e-12)
        #expect(abs(a.pitch - Camera.StandardView.iso.angles.pitch) < 1e-12)
    }

    @Test func viewAnglesStraightUpOrDownKeepTheNearestQuarterTurn() {
        let cases: [(current: Double, yaw: Double)] = [
            (0.2, 0), (1.4, .pi / 2), (-1.4, -.pi / 2), (3.0, .pi), (-3.0, -.pi), (-2.9, -.pi), (2.9, .pi),
        ]
        for (current, yaw) in cases {
            for (z, pitch) in [(1.0, Double.pi / 2), (-1.0, -Double.pi / 2)] {
                let a = Camera.viewAngles(lookingFrom: Vec3(0, 0, z), currentYaw: current)
                #expect(a.yaw == yaw, "yaw from \(current)")
                #expect(a.pitch == pitch)
                // The animation takes the short way there.
                let from = Camera(yaw: current, pitch: 0.3)
                let to = Camera(yaw: a.yaw, pitch: a.pitch)
                #expect(abs(Camera.wrapAngle(to.yaw - from.yaw)) <= .pi / 4 + 0.2)
            }
        }
    }
}

// MARK: Roll

@Suite("Camera roll")
struct CameraRollTests {
    private static let quarter = Double.pi / 2

    /// Screen position of `p` relative to the view centre, y up.
    private func screen(_ p: Vec3, _ c: Camera) throws -> (x: Double, y: Double) {
        let s = try #require(c.project(p, viewSize: viewSize))
        return (Double(s.x) - 400, 300 - Double(s.y))
    }

    @Test(arguments: [0.4, quarter, -quarter, .pi, -2.5])
    func rollTurnsThePictureAnticlockwise(roll: Double) throws {
        for projection in Camera.Projection.allCases {
            let upright = Camera(target: Vec3(2, -1, 4), distance: 150, yaw: 0.6, pitch: 0.35, projection: projection)
            var rolled = upright
            rolled.roll = roll
            // Still an orthonormal, right-handed frame with the same view direction.
            #expect(approx(rolled.back, upright.back))
            #expect(abs(rolled.up.length - 1) < 1e-12 && abs(rolled.right.length - 1) < 1e-12)
            #expect(abs(rolled.up.dot(rolled.back)) < 1e-12 && approx(rolled.right.cross(rolled.up), rolled.back))
            for p in [Vec3(10, 3, -2), Vec3(-6, 12, 9), Vec3(2, -1, 4)] {
                let a = try screen(p, upright), b = try screen(p, rolled)
                let x = a.x * cos(roll) - a.y * sin(roll), y = a.x * sin(roll) + a.y * cos(roll)
                #expect(abs(b.x - x) < 1e-6 && abs(b.y - y) < 1e-6)
            }
            // The view matrix agrees with the basis.
            let v = rolled.viewMatrixD
            #expect(abs(v.columns.0.y - rolled.up.x) < 1e-12 && abs(v.columns.2.y - rolled.up.z) < 1e-12)
        }
    }

    @Test func rollingFrontClockwiseTurnsUpToTheRight() {
        let front = Camera().viewing(.front)
        let cw = front.rolled(clockwise: true)
        #expect(cw.roll == -Self.quarter)
        #expect(approx(cw.right, .unitZ) && approx(cw.up, -Vec3.unitX) && approx(cw.back, front.back))
        let ccw = front.rolled(clockwise: false)
        #expect(ccw.roll == Self.quarter)
        #expect(approx(ccw.right, -Vec3.unitZ) && approx(ccw.up, .unitX))
    }

    @Test(arguments: [Camera.StandardView.front, .back, .left, .right, .top, .bottom])
    func quarterTurnsAreExactAndComeRoundAgain(view: Camera.StandardView) {
        let start = Camera(distance: 200).viewing(view)
        var c = start
        for _ in 0..<4 {
            let next = c.rolled(clockwise: true)
            // A quarter turn clockwise: old screen-up becomes screen-right, old right becomes down.
            #expect(approx(next.right, c.up, 1e-12) && approx(next.up, -c.right, 1e-12))
            #expect(approx(next.back, c.back, 1e-12) && next.target == c.target && next.distance == c.distance)
            // Exact multiples of 90°, so the views stay exactly square.
            for a in [next.yaw, next.roll] { #expect(a == Camera.snapped(a)) }
            c = next
        }
        #expect(c.isApproximatelyEqual(to: start, tolerance: 1e-12))
        #expect(start.rolled(clockwise: true).rolled(clockwise: false).isApproximatelyEqual(to: start, tolerance: 1e-12))
    }

    /// Looking straight down or up a turn of the picture is a turn of yaw: the roll stays 0, so an
    /// orbit from there starts upright.
    @Test func topAndBottomRollByYaw() {
        for view in [Camera.StandardView.top, .bottom] {
            let c = Camera().viewing(view)
            for clockwise in [true, false] {
                let r = c.rolled(clockwise: clockwise)
                #expect(r.roll == 0 && r.pitch == c.pitch)
                #expect(approx(r.up, clockwise ? -c.right : c.right, 1e-12))
            }
        }
    }

    @Test func interpolationTakesTheShortWayRound() {
        let a = Camera(yaw: 0, pitch: 0, roll: .pi)
        let b = Camera(yaw: 0, pitch: 0, roll: -Self.quarter)
        for i in 0...10 {
            let c = Camera.interpolate(a, b, t: Double(i) / 10)
            // Never further than the 90° between them (no 270° spin the other way).
            #expect(abs(Camera.wrapAngle(c.roll - a.roll)) <= Self.quarter + 1e-12)
            #expect(abs(Camera.wrapAngle(c.roll - b.roll)) <= Self.quarter + 1e-12)
        }
        #expect(Camera.interpolate(a, b, t: 1).isApproximatelyEqual(to: b))
        let mid = Camera.interpolate(Camera(roll: 3.0), Camera(roll: -3.0), t: 0.5)
        #expect(abs(abs(mid.roll) - .pi) < 1e-9)
        #expect(!Camera(roll: 0.1).isApproximatelyEqual(to: Camera()))
    }

    @Test func codableKeepsRollAndOldDocumentsDecodeUpright() throws {
        let c = Camera(target: Vec3(1, 2, 3), distance: 42, yaw: 0.25, pitch: -0.5, roll: -Self.quarter,
                       projection: .orthographic, fovDegrees: 40)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Camera.self, from: data) == c)
        // A camera saved before roll existed has no "roll" key.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["roll"] != nil)
        json["roll"] = nil
        let old = try JSONDecoder().decode(Camera.self, from: JSONSerialization.data(withJSONObject: json))
        var expected = c
        expected.roll = 0
        #expect(old == expected)
    }

    /// Orbiting keeps the roll and reads the drag in screen directions: the near side of the model
    /// follows the pointer whichever way the picture is turned.
    @Test(arguments: [0, quarter, .pi, -quarter, 0.7])
    func orbitFollowsTheDragOnScreen(roll: Double) throws {
        let start = Camera(target: .zero, distance: 200, yaw: 0.3, pitch: 0.2, roll: roll)
        let near = start.target + start.back * 40
        let p0 = try #require(start.project(near, viewSize: viewSize))
        for (dx, dy) in [(3.0, 0.0), (-3.0, 0.0), (0.0, 3.0), (0.0, -3.0)] {
            var c = start
            c.orbit(drag: CGSize(width: dx, height: dy))
            #expect(c.roll == roll)
            let p1 = try #require(c.project(near, viewSize: viewSize))
            let mx = Double(p1.x - p0.x), my = Double(p1.y - p0.y)
            let cosine = (mx * dx + my * dy) / (hypot(mx, my) * 3)
            #expect(cosine > 0.95, "drag (\(dx), \(dy)) at roll \(roll) moved (\(mx), \(my))")
        }
    }

    @Test func newViewDirectionsAreUpright() {
        let rolled = Camera(yaw: 0, pitch: 0, roll: Self.quarter)
        #expect(rolled.viewing(.right).roll == 0)
        #expect(rolled.looking(at: Plane.xy).roll == 0)
        var turned = rolled
        turned.orbit(deltaYaw: 0.2, deltaPitch: 0.1, pivot: Vec3(5, 0, 0))
        #expect(turned.roll == Self.quarter)
    }
}
