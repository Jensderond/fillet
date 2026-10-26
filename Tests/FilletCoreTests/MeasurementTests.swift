import FilletKernel
import Foundation
import Testing

@testable import FilletCore

/// Measure's results against analytic values on a box and a cylinder.
@Suite("Measure")
struct MeasurementTests {
    private func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    private func face(_ s: Shape, _ p: (FaceInfo) -> Bool) throws -> Int {
        let i = s.faceInfos.firstIndex(where: p)
        return try #require(i)
    }

    private func edge(_ s: Shape, _ p: (EdgeInfo) -> Bool) throws -> Int {
        let i = s.edgeInfos.firstIndex(where: p)
        return try #require(i)
    }

    @Test func singleItems() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(30, 20, 10))
        let body = try #require(Measure.item(box, .body))
        #expect(near(body.volume, 6000) && body.size == Vec3(30, 20, 10))

        let top = try face(box) { $0.normal.z > 0.99 }
        let f = try #require(Measure.item(box, .face(top)))
        #expect(f.surface == .plane && near(f.area, 600) && f.radius == nil)

        let long = try edge(box) { abs($0.length - 30) < 1e-9 }
        let e = try #require(Measure.item(box, .edge(long)))
        #expect(e.curve == .line && near(e.length, 30) && e.radius == nil)

        let v = try #require(Measure.item(box, .vertex(0)))
        let p = try #require(v.position)
        #expect([0.0, 30].contains(p.x) && [0.0, 20].contains(p.y) && [0.0, 10].contains(p.z))

        #expect(Measure.item(box, .face(99)) == nil && Measure.item(box, .edge(-1)) == nil && Measure.item(box, .vertex(8)) == nil)
    }

    @Test func cylinderRadii() throws {
        let c = try Shape.cylinder(base: .xy, radius: 6, height: 15)
        let side = try face(c) { $0.surface == .cylinder }
        let f = try #require(Measure.item(c, .face(side)))
        #expect(near(f.radius, 6) && near(f.area, 2 * .pi * 6 * 15))
        let rim = try edge(c) { $0.curve == .circle }
        let e = try #require(Measure.item(c, .edge(rim)))
        #expect(near(e.radius, 6) && near(e.length, 12 * .pi))
        let body = try #require(Measure.item(c, .body))
        #expect(near(body.volume, .pi * 36 * 15, 1e-3))
        #expect(near(body.size?.x, 12) && near(body.size?.z, 15))
    }

    @Test func distanceAndAngleBetweenFaces() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(30, 20, 10))
        let top = try face(box) { $0.normal.z > 0.99 }
        let bottom = try face(box) { $0.normal.z < -0.99 }
        let side = try face(box) { $0.normal.x > 0.99 }
        let across = try #require(Measure.pair((box, .face(top)), (box, .face(bottom))))
        #expect(near(across.distance, 10) && near(abs(across.delta.z), 10) && near(across.delta.x, 0) && near(across.angle, .pi))
        let adjacent = try #require(Measure.pair((box, .face(top)), (box, .face(side))))
        #expect(near(adjacent.distance, 0) && near(adjacent.angle, .pi / 2))
    }

    @Test func distanceBetweenBodiesAndVertices() throws {
        let a = try Shape.box(corner: .zero, size: Vec3(10, 10, 10))
        let b = try Shape.box(corner: Vec3(15, 3, 4), size: Vec3(5, 5, 5))
        let d = try #require(Measure.pair((a, .body), (b, .body)))
        #expect(near(d.distance, 5) && near(d.delta.x, 5) && near(d.delta.y, 0) && near(d.delta.z, 0))
        #expect(near(d.pointA.x, 10) && near(d.pointB.x, 15))
        #expect(d.angle == nil)

        // Corner to corner across the gap: (15,3,4) − (10,10,10).
        let ia = try #require((0..<a.vertexCount).first { a.vertexPoint($0) == Vec3(10, 10, 10) })
        let ib = try #require((0..<b.vertexCount).first { b.vertexPoint($0) == Vec3(15, 3, 4) })
        let v = try #require(Measure.pair((a, .vertex(ia)), (b, .vertex(ib))))
        #expect(near(v.distance, (25.0 + 49 + 36).squareRoot()))
        #expect(near(v.delta.x, 5) && near(v.delta.y, -7) && near(v.delta.z, -6))
    }

    @Test func edgeAndCylinder() throws {
        // A line edge and a cylinder's side: distance to the surface, no angle (the face is round).
        let c = try Shape.cylinder(base: Plane(origin: Vec3(50, 0, 0), normal: .unitZ, xDir: .unitX), radius: 5, height: 10)
        let box = try Shape.box(corner: .zero, size: Vec3(10, 10, 10))
        let edgeX10 = try edge(box) { abs($0.start.x - 10) < 1e-9 && abs($0.end.x - 10) < 1e-9 && abs($0.tangentAtMid.z) > 0.99 && abs($0.start.y) < 1e-9 }
        let side = try face(c) { $0.surface == .cylinder }
        let d = try #require(Measure.pair((box, .edge(edgeX10)), (c, .face(side))))
        #expect(near(d.distance, 35) && d.angle == nil)
    }
}
