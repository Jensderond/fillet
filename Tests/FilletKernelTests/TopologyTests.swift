import Foundation
import Testing
import simd
@testable import FilletKernel

@Suite("Topology & analysis")
struct TopologyTests {
    @Test func boxFacesAndEdges() throws {
        let box = try cube(10)
        #expect(box.faceCount == 6)
        #expect(box.edgeCount == 12)
        let center = Vec3(5, 5, 5)
        for i in 0..<6 {
            let f = box.faceInfo(i)
            #expect(f.surface == .plane)
            #expect(close(f.area, 100))
            #expect(close(f.normal.length, 1, rel: 1e-9))
            // Outward: the normal points away from the box centre.
            #expect(close(f.normal.dot((f.centroid - center).normalized), 1, rel: 1e-9))
            #expect(f.boundsMin.x >= -1e-6 && f.boundsMax.x <= 10 + 1e-6)
        }
        for i in 0..<12 {
            let e = box.edgeInfo(i)
            #expect(e.curve == .line)
            #expect(close(e.length, 10))
            #expect(e.radius == 0)
            #expect(e.mid.distance(to: (e.start + e.end) / 2) < 1e-9)
            #expect(close(abs(e.tangentAtMid.dot((e.end - e.start).normalized)), 1, rel: 1e-9))
        }
        #expect(box.faceInfos.count == 6 && box.edgeInfos.count == 12)
    }

    @Test func cylinderFacesAndEdges() throws {
        let c = try Shape.cylinder(base: .xy, radius: 4, height: 10)
        #expect(c.faceCount == 3)
        #expect(c.edgeCount == 3)
        let types = (0..<3).map { c.faceInfo($0).surface }
        #expect(types.filter { $0 == .plane }.count == 2)
        #expect(types.filter { $0 == .cylinder }.count == 1)
        let side = try #require(faceIndex(c) { $0.surface == .cylinder })
        #expect(close(c.faceInfo(side).area, 2 * .pi * 4 * 10, rel: 1e-9))
        let n = c.faceInfo(side).normal
        #expect(close(n.length, 1, rel: 1e-9) && abs(n.z) < 1e-9)
        let circles = (0..<3).map { c.edgeInfo($0) }.filter { $0.curve == .circle }
        #expect(circles.count == 2)
        for e in circles {
            #expect(close(e.radius, 4))
            #expect(close(e.length, 8 * .pi, rel: 1e-9))
        }
        #expect(c.facePlane(side) == nil)
    }

    @Test func facePlanesAreOutward() throws {
        let box = try cube(10, at: Vec3(-5, -5, 0))
        for i in 0..<box.faceCount {
            let plane = try #require(box.facePlane(i))
            let info = box.faceInfo(i)
            #expect(plane.origin.distance(to: info.centroid) < 1e-9)
            #expect(close(plane.normal.dot(info.normal), 1, rel: 1e-9))
            #expect(plane.normal.dot(plane.origin - Vec3(0, 0, 5)) > 0)
            #expect(abs(plane.xDir.dot(plane.normal)) < 1e-9)
            // xDir is along an axis (box edges).
            let x = plane.xDir
            #expect(close(max(abs(x.x), abs(x.y), abs(x.z)), 1, rel: 1e-9))
        }
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        let tp = try #require(box.facePlane(top))
        #expect(close(tp.origin.z, 10, abs: 1e-9))
        #expect(close(tp.normal.z, 1, rel: 1e-12))
    }

    @Test func facePlaneXDirFollowsLongestEdge() throws {
        let slab = try Shape.box(corner: .zero, size: Vec3(4, 30, 2))
        let top = try #require(faceIndex(slab) { $0.normal.z > 0.99 })
        let plane = try #require(slab.facePlane(top))
        #expect(close(abs(plane.xDir.y), 1, rel: 1e-9))
        // A face plane can be used as a sketch plane: sketching on the top and extruding grows upward.
        let region = try SketchRegions(plane: plane, segments: [.circle(center: p(0, 0), radius: 1)])
        let boss = try region.profile(indices: [0]).extruded(along: plane.normal, distance: 3)
        #expect(close(try #require(boss.bounds).max.z, 5, abs: 1e-6))
    }

    @Test func invalidIndicesAreRejected() throws {
        let box = try cube(10)
        #expect(box.faceInfoIfValid(6) == nil)
        #expect(box.faceInfoIfValid(-1) == nil)
        #expect(box.edgeInfoIfValid(12) == nil)
        #expect(box.faceInfo(99).surface == .other)
        #expect(box.edgeInfo(99).length == 0)
        #expect(box.facePlane(99) == nil)
        #expect(box.facePlane(-3) == nil)
        expectKernelError("does not exist") { _ = try box.face(6) }
        expectKernelError("does not exist") { _ = try box.edge(-1) }
        // The same once the lookups are answered from the cached tables.
        _ = (box.faceInfos, box.edgeInfos)
        #expect(box.faceInfoIfValid(6) == nil && box.faceInfoIfValid(-1) == nil)
        #expect(box.edgeInfoIfValid(12) == nil && box.edgeInfoIfValid(-1) == nil)
        #expect(box.faceInfo(99).surface == .other && box.edgeInfo(99).length == 0)
        #expect(!box.isSeamEdge(12) && !box.isSeamEdge(-1))
    }

    @Test func seamsAndDegenerateEdges() throws {
        #expect(try cube(10).seamEdges == Array(repeating: false, count: 12))
        // A cylinder's closing line is a seam; its two circles are not.
        let c = try Shape.cylinder(base: .xy, radius: 4, height: 10)
        let circles = (0..<c.edgeCount).filter { c.edgeInfo($0).curve == .circle }
        #expect(circles.count == 2)
        #expect((0..<c.edgeCount).filter(c.isSeamEdge) == (0..<c.edgeCount).filter { !circles.contains($0) })
        // A sphere has only a seam and two degenerate pole edges.
        let s = try Shape.sphere(center: .zero, radius: 5)
        #expect(s.edgeCount > 0 && s.seamEdges.allSatisfy { $0 })
    }

    @Test func cachedInfosMatchSingleQueries() async throws {
        let part = try cube(10).cut(by: Shape.cylinder(base: .xy, radius: 3, height: 10))
        // Per-index answers come from the kernel until the whole table is built…
        let faces = (0..<part.faceCount).map(part.faceInfo)
        let edges = (0..<part.edgeCount).map(part.edgeInfo)
        // …which several threads may ask for at once.
        let tables = await withTaskGroup(of: ([FaceInfo], [EdgeInfo], [Bool]).self) { group in
            for _ in 0..<8 { group.addTask { (part.faceInfos, part.edgeInfos, part.seamEdges) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (f, e, seams) in tables {
            #expect(f == faces && e == edges)
            #expect(seams.count == part.edgeCount)
        }
        #expect((0..<part.faceCount).map(part.faceInfo) == faces)
        #expect((0..<part.edgeCount).map(part.edgeInfo) == edges)
    }

    @Test func volumeAndAreaMatchSerialIntegration() throws {
        // `volume` and `surfaceArea` integrate the faces in parallel and add them up in face
        // order. That must give the same double as BRepGProp's own serial loop, which
        // `massProperties(precision: 1)` runs (precision 1 is OCCT's default-precision path).
        let squash = Transform(matrix: [1.5, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0.7, 0])
        let squashed = try Shape.sphere(center: .zero, radius: 8).transformed(squash)  // B-spline faces
        let part = try cube(10).filleted(edges: [0], radius: 2).cut(by: Shape.cylinder(base: .xy, radius: 3, height: 10))
        let blob = try part.fused(with: squashed)
        let shapes = [
            squashed, part, blob,
            try Shape.compound([blob, squashed.translated(by: Vec3(40, 0, 0))]),
            try Shape.compound([part, part]),  // a shared solid: OCCT integrates per solid
            try part.face(0),  // one face
        ]
        for shape in shapes {
            let serial = try #require(shape.massProperties(precision: 1))
            #expect(shape.volume.bitPattern == serial.volume.bitPattern)
            #expect(shape.surfaceArea.bitPattern == serial.area.bitPattern)
        }
        #expect(blob.faceCount > 2 && part.faceCount > 2)  // the parallel path
    }

    @Test func subshapes() throws {
        let box = try cube(10)
        let face = try box.face(0)
        #expect(face.faceCount == 1 && close(face.surfaceArea, 100))
        #expect(face.volume == 0 || abs(face.volume) < 1e-9)
        let edge = try box.edge(0)
        #expect(edge.edgeCount == 1 && edge.faceCount == 0)
    }

    @Test func distance() throws {
        let a = try cube(10)
        let b = try cube(10, at: Vec3(15, 0, 0))
        let d = try #require(a.distance(to: b))
        #expect(close(d.distance, 5, rel: 1e-9))
        #expect(close(d.pointA.x, 10, abs: 1e-9) && close(d.pointB.x, 15, abs: 1e-9))
        let s = try Shape.sphere(center: Vec3(5, 5, 30), radius: 5)
        #expect(close(try #require(a.distance(to: s)).distance, 15, rel: 1e-6))
        // Distance from a face to a vertex-like small sphere along the normal.
        let top = try a.face(try #require(faceIndex(a) { $0.normal.z > 0.99 }))
        #expect(close(try #require(top.distance(to: s)).distance, 15, rel: 1e-6))
        #expect(close(try #require(a.distance(to: a)).distance, 0, abs: 1e-9))
    }

    @Test func validity() throws {
        #expect(try cube(10).isValid)
        #expect(try Shape.compound([]).isValid == false)
        // An open shell (a single face) is not closed geometry when part of a shell... a lone face is fine.
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10))
        #expect(try r.face(0).isValid)
    }

    @Test func brepStringRoundTrip() throws {
        let original = try cube(10).filleted(edges: [0], radius: 2)
        let text = original.brepString()
        #expect(text.contains("CASCADE Topology"))
        let restored = try Shape.fromBRep(text)
        #expect(close(restored.volume, original.volume, rel: 1e-9))
        #expect(restored.faceCount == original.faceCount)
        #expect(restored.edgeCount == original.edgeCount)
        // Indices survive the round trip (same MapShapes order).
        for i in 0..<original.faceCount {
            #expect(restored.faceInfo(i).centroid.distance(to: original.faceInfo(i).centroid) < 1e-9)
        }
        expectKernelError { _ = try Shape.fromBRep("") }
        expectKernelError { _ = try Shape.fromBRep("this is not a brep") }
    }
}
