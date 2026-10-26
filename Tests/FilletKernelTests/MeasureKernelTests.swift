import Foundation
import Testing
@testable import FilletKernel

/// The kernel queries behind the Measure tool, against analytic values on a box and a cylinder.
@Suite("Measure (kernel)")
struct MeasureKernelTests {
    @Test func boxVertices() throws {
        let box = try cube(10, at: Vec3(1, 2, 3))
        #expect(box.vertexCount == 8)
        let points = (0..<8).compactMap { box.vertexPoint($0) }
        #expect(points.count == 8)
        for p in points {
            #expect([1.0, 11].contains { abs(p.x - $0) < 1e-9 })
            #expect([2.0, 12].contains { abs(p.y - $0) < 1e-9 })
            #expect([3.0, 13].contains { abs(p.z - $0) < 1e-9 })
        }
        #expect(Set(points.map { "\($0)" }).count == 8)
        #expect(box.vertexPoint(8) == nil && box.vertexPoint(-1) == nil)
        // The mesh carries the same points, in the same order, for picking.
        let mesh = try box.tessellate()
        #expect(mesh.brepVertices.count == 8)
        for (i, p) in points.enumerated() { #expect(Vec3(mesh.brepVertices[i]).distance(to: p) < 1e-5) }
    }

    @Test func vertexDistances() throws {
        let box = try cube(10)
        let corner = try #require((0..<8).first { box.vertexPoint($0)?.distance(to: .zero) ?? 1 < 1e-9 })
        let far = try #require((0..<8).first { box.vertexPoint($0)?.distance(to: Vec3(10, 10, 10)) ?? 1 < 1e-9 })
        let d = try #require(try box.vertex(corner).distance(to: box.vertex(far)))
        #expect(close(d.distance, 10 * 3.0.squareRoot()))
        // A vertex to the opposite face: straight across.
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        let toTop = try #require(try box.vertex(corner).distance(to: box.face(top)))
        #expect(close(toTop.distance, 10))
        #expect(toTop.pointB.distance(to: Vec3(0, 0, 10)) < 1e-9)
    }

    @Test func faceRadius() throws {
        let c = try Shape.cylinder(base: .xy, radius: 4, height: 10)
        let side = try #require(faceIndex(c) { $0.surface == .cylinder })
        let cap = try #require(faceIndex(c) { $0.surface == .plane })
        #expect(close(try #require(c.faceRadius(side)), 4))
        #expect(c.faceRadius(cap) == nil)
        let s = try Shape.sphere(center: .zero, radius: 7)
        #expect(close(try #require(s.faceRadius(0)), 7))
    }

    @Test func anglesBetweenFaces() throws {
        let box = try cube(10)
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        let bottom = try #require(faceIndex(box) { $0.normal.z < -0.99 })
        let side = try #require(faceIndex(box) { $0.normal.x > 0.99 })
        #expect(close(try box.face(top).angle(to: box.face(side)), .pi / 2))
        #expect(close(try box.face(top).angle(to: box.face(bottom)), .pi))
        // A 45° chamfer face against the top it was cut from.
        let chamfered = try box.chamfered(edges: [edgeIndex(box, from: Vec3(10, 0, 10), to: Vec3(10, 10, 10))], distance: 2)
        let slope = try #require(faceIndex(chamfered) { abs($0.normal.x - $0.normal.z) < 1e-6 && $0.normal.x > 0.5 })
        let newTop = try #require(faceIndex(chamfered) { $0.normal.z > 0.99 })
        #expect(close(try chamfered.face(slope).angle(to: chamfered.face(newTop)), .pi / 4))
    }

    @Test func anglesWithEdges() throws {
        let box = try cube(10)
        let x = try edgeIndex(box, from: .zero, to: Vec3(10, 0, 0))
        let y = try edgeIndex(box, from: .zero, to: Vec3(0, 10, 0))
        let z = try edgeIndex(box, from: .zero, to: Vec3(0, 0, 10))
        let xTop = try edgeIndex(box, from: Vec3(0, 0, 10), to: Vec3(10, 0, 10))
        #expect(close(try box.edge(x).angle(to: box.edge(y)), .pi / 2))
        #expect(close(try box.edge(x).angle(to: box.edge(xTop)), 0, abs: 1e-9))
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        // Line and plane: an edge lying in the plane is at 0°, one standing on it at 90°.
        #expect(close(try box.edge(x).angle(to: box.face(top)), 0, abs: 1e-9))
        #expect(close(try box.face(top).angle(to: box.edge(z)), .pi / 2))
        // The chamfer's sloped face against an edge running up the side: 45°.
        let chamfered = try box.chamfered(edges: [edgeIndex(box, from: Vec3(10, 0, 10), to: Vec3(10, 10, 10))], distance: 2)
        let slope = try #require(faceIndex(chamfered) { abs($0.normal.x - $0.normal.z) < 1e-6 && $0.normal.x > 0.5 })
        let upright = try edgeIndex(chamfered, from: Vec3(0, 0, 0), to: Vec3(0, 0, 10))
        #expect(close(try chamfered.face(slope).angle(to: chamfered.edge(upright)), .pi / 4))
    }

    @Test func anglesNeedFlatFacesOrStraightEdges() throws {
        let c = try Shape.cylinder(base: .xy, radius: 4, height: 10)
        let side = try #require(faceIndex(c) { $0.surface == .cylinder })
        let cap = try #require(faceIndex(c) { $0.surface == .plane })
        let circle = try #require((0..<c.edgeCount).first { c.edgeInfo($0).curve == .circle })
        #expect(throws: KernelError.self) { try c.face(side).angle(to: c.face(cap)) }
        #expect(throws: KernelError.self) { try c.edge(circle).angle(to: c.face(cap)) }
        #expect(throws: KernelError.self) { try c.angle(to: c.face(cap)) }
    }

    private func edgeIndex(_ shape: Shape, from a: Vec3, to b: Vec3) throws -> Int {
        try #require((0..<shape.edgeCount).first { i in
            let e = shape.edgeInfo(i)
            return (e.start.distance(to: a) < 1e-9 && e.end.distance(to: b) < 1e-9)
                || (e.start.distance(to: b) < 1e-9 && e.end.distance(to: a) < 1e-9)
        })
    }
}
