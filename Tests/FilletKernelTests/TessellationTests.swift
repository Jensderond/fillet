import Foundation
import Testing
import Synchronization
import simd
@testable import FilletKernel

/// Welds vertices by position and checks every solid is closed and consistently oriented:
/// each directed edge (a→b) must be matched by exactly one (b→a).
func checkWatertight(_ mesh: Mesh, sourceLocation: SourceLocation = #_sourceLocation) {
    var ids = [SIMD3<Int64>: UInt32]()
    var weld = [UInt32](repeating: 0, count: mesh.positions.count)
    for (i, p) in mesh.positions.enumerated() {
        let key = SIMD3<Int64>(Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded()), Int64((p.z * 1e4).rounded()))
        if let id = ids[key] { weld[i] = id } else {
            let id = UInt32(ids.count)
            ids[key] = id
            weld[i] = id
        }
    }
    struct DirectedEdge: Hashable { let a, b: UInt32 }
    var counts = [DirectedEdge: Int]()
    for t in stride(from: 0, to: mesh.indices.count, by: 3) {
        let v = [weld[Int(mesh.indices[t])], weld[Int(mesh.indices[t + 1])], weld[Int(mesh.indices[t + 2])]]
        if v[0] == v[1] || v[1] == v[2] || v[0] == v[2] { continue }  // degenerate after welding
        for k in 0..<3 { counts[DirectedEdge(a: v[k], b: v[(k + 1) % 3]), default: 0] += 1 }
    }
    var bad = 0
    for (e, n) in counts where n != 1 || counts[DirectedEdge(a: e.b, b: e.a)] != 1 { bad += 1 }
    #expect(bad == 0, "\(bad) non-manifold or open directed edges", sourceLocation: sourceLocation)
}

/// Signed volume of the triangle mesh (positive when triangles wind counter-clockwise outward).
func meshVolume(_ mesh: Mesh) -> Double {
    var v = 0.0
    for t in stride(from: 0, to: mesh.indices.count, by: 3) {
        let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[t])])
        let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 1])])
        let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 2])])
        v += simd_dot(a, simd_cross(b, c)) / 6
    }
    return v
}

func checkMeshInvariants(_ shape: Shape, _ mesh: Mesh, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(mesh.positions.count == mesh.normals.count, sourceLocation: sourceLocation)
    #expect(mesh.indices.count == 3 * mesh.triangleFaces.count, sourceLocation: sourceLocation)
    #expect(mesh.edges.count == shape.edgeCount, sourceLocation: sourceLocation)
    #expect(mesh.indices.allSatisfy { Int($0) < mesh.positions.count }, sourceLocation: sourceLocation)
    #expect(mesh.triangleFaces.allSatisfy { $0 >= 0 && Int($0) < shape.faceCount }, sourceLocation: sourceLocation)
    #expect(Set(mesh.triangleFaces).count == shape.faceCount, "every face has triangles", sourceLocation: sourceLocation)
    #expect(mesh.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-4 }, sourceLocation: sourceLocation)
    // Vertex normals agree with the triangle winding.
    var disagree = 0
    for t in stride(from: 0, to: mesh.indices.count, by: 3) {
        let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
        let n = simd_cross(mesh.positions[ib] - mesh.positions[ia], mesh.positions[ic] - mesh.positions[ia])
        if simd_length(n) < 1e-6 { continue }  // sliver triangle: winding is numerically meaningless
        if simd_dot(n, mesh.normals[ia] + mesh.normals[ib] + mesh.normals[ic]) <= 0 { disagree += 1 }
    }
    #expect(disagree == 0, "\(disagree) triangles wind against their normals", sourceLocation: sourceLocation)
    // Vertices are not shared between faces.
    var owner = [UInt32: Int32]()
    var shared = 0
    for (t, f) in mesh.triangleFaces.enumerated() {
        for k in 0..<3 {
            let v = mesh.indices[3 * t + k]
            if let o = owner[v], o != f { shared += 1 } else { owner[v] = f }
        }
    }
    #expect(shared == 0, sourceLocation: sourceLocation)
}

@Suite("Tessellation")
struct TessellationTests {
    @Test func box() throws {
        let box = try cube(10)
        let mesh = try box.tessellate()
        checkMeshInvariants(box, mesh)
        checkWatertight(mesh)
        #expect(mesh.triangleCount == 12)
        #expect(mesh.positions.count == 24)
        #expect(close(meshVolume(mesh), 1000, rel: 1e-5))
        for e in mesh.edges { #expect(e.count == 2) }
        // Flat faces: every vertex normal equals its face normal.
        for (t, f) in mesh.triangleFaces.enumerated() {
            let n = box.faceInfo(Int(f)).normal.float
            #expect(simd_distance(mesh.normals[Int(mesh.indices[3 * t])], n) < 1e-5)
        }
    }

    @Test func cylinderSeamHasEmptyPolyline() throws {
        let c = try Shape.cylinder(base: .xy, radius: 5, height: 10)
        let mesh = try c.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)
        checkMeshInvariants(c, mesh)
        checkWatertight(mesh)
        #expect(close(meshVolume(mesh), .pi * 250, rel: 0.01))
        for i in 0..<c.edgeCount {
            let info = c.edgeInfo(i)
            if info.curve == .line {
                #expect(mesh.edges[i].isEmpty)
            } else {
                #expect(mesh.edges[i].count > 10)
                for p in mesh.edges[i] { #expect(abs(simd_length(SIMD2(p.x, p.y)) - 5) < 1e-4) }
            }
        }
        // Smooth normals on the side: radial.
        let side = try #require(faceIndex(c) { $0.surface == .cylinder })
        for (t, f) in mesh.triangleFaces.enumerated() where Int(f) == side {
            let i = Int(mesh.indices[3 * t])
            let radial = simd_normalize(SIMD3<Float>(mesh.positions[i].x, mesh.positions[i].y, 0))
            #expect(simd_distance(mesh.normals[i], radial) < 1e-3)
        }
    }

    @Test func complexSolidsAreWatertight() throws {
        let shapes: [Shape] = [
            try Shape.sphere(center: .zero, radius: 5),
            try Shape.torus(base: .xy, majorRadius: 10, minorRadius: 3),
            try Shape.cone(base: .xy, radius1: 5, radius2: 0, height: 5),
            try cube(10).filleted(edges: Array(0..<12), radius: 2),
            try cube(10).cut(by: try Shape.cylinder(base: Plane(origin: Vec3(5, 5, -1), normal: .unitZ, xDir: .unitX), radius: 3, height: 12)),
            try cube(10).shelled(removing: [0], thickness: 1),
        ]
        for s in shapes {
            let mesh = try s.tessellate(linearDeflection: 0.05, angularDeflection: 0.3)
            checkMeshInvariants(s, mesh)
            checkWatertight(mesh)
            #expect(close(meshVolume(mesh), s.volume, rel: 0.02))
        }
    }

    @Test func reversedFacesWindOutward() throws {
        // Mirroring and cutting produce REVERSED faces; mesh volume must stay positive.
        let m = try cube(10, at: Vec3(1, 0, 0)).cut(by: try Shape.sphere(center: Vec3(1, 0, 0), radius: 4)).mirrored(across: .yz)
        let mesh = try m.tessellate()
        checkMeshInvariants(m, mesh)
        checkWatertight(mesh)
        #expect(close(meshVolume(mesh), m.volume, rel: 0.02))
    }

    @Test func multipleSolids() throws {
        let c = try Shape.compound([try cube(10), try Shape.sphere(center: Vec3(30, 0, 0), radius: 4)])
        let mesh = try c.tessellate()
        checkMeshInvariants(c, mesh)
        checkWatertight(mesh)
    }

    @Test func tessellationErrors() throws {
        let box = try cube(10)
        expectKernelError { _ = try box.tessellate(linearDeflection: 0) }
        expectKernelError { _ = try box.tessellate(linearDeflection: -.infinity) }
        let empty = try Shape.compound([]).tessellate()
        #expect(empty.triangleCount == 0 && empty.edges.isEmpty)
    }

    @Test func tessellatingDoesNotChangeTheShape() throws {
        let box = try cube(10).filleted(edges: [0, 1], radius: 2)
        let coarse = try box.tessellate(linearDeflection: 1, angularDeflection: 1)
        let fine = try box.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)
        #expect(fine.triangleCount > coarse.triangleCount)
        let coarseAgain = try box.tessellate(linearDeflection: 1, angularDeflection: 1)
        #expect(coarseAgain.triangleCount == coarse.triangleCount)
    }

    @Test func serialAndParallelMeshesAreIdentical() throws {
        // The evaluator meshes all but the largest body on one thread each, several at once.
        let part = try cube(10).filleted(edges: Array(0..<12), radius: 2)
            .cut(by: try Shape.sphere(center: Vec3(10, 10, 10), radius: 4))
        let parallel = try part.tessellate(linearDeflection: 0.02, angularDeflection: 0.2, parallel: true)
        let meshes = Mutex<[Mesh]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let m = try? part.copy().tessellate(linearDeflection: 0.02, angularDeflection: 0.2, parallel: false)
            meshes.withLock { $0.append(m ?? .empty) }
        }
        for serial in meshes.withLock({ $0 }) {
            #expect(serial.positions == parallel.positions && serial.normals == parallel.normals)
            #expect(serial.indices == parallel.indices && serial.triangleFaces == parallel.triangleFaces)
            #expect(serial.edges == parallel.edges)
        }
    }

    @Test func performanceFilletedBoxWithHoles() throws {
        var part = try Shape.box(corner: .zero, size: Vec3(60, 40, 10))
        for (x, y) in [(10.0, 10.0), (50.0, 10.0), (10.0, 30.0), (50.0, 30.0), (30.0, 20.0)] {
            let hole = try Shape.cylinder(base: Plane(origin: Vec3(x, y, -1), normal: .unitZ, xDir: .unitX), radius: 3, height: 12)
            part = try part.cut(by: hole)
        }
        let vertical = (0..<part.edgeCount).filter {
            let e = part.edgeInfo($0)
            let onCorner = [0.0, 60.0].contains(e.mid.x.rounded()) && [0.0, 40.0].contains(e.mid.y.rounded())
            return e.curve == .line && abs(e.tangentAtMid.z) > 0.99 && onCorner
        }
        #expect(vertical.count == 4)
        part = try part.filleted(edges: vertical, radius: 4)
        _ = try part.tessellate()  // warm-up
        let clock = ContinuousClock()
        var mesh = Mesh.empty
        let elapsed = try clock.measure { mesh = try part.tessellate() }
        checkMeshInvariants(part, mesh)
        checkWatertight(mesh)
        #expect(elapsed < .milliseconds(100), "tessellation took \(elapsed)")
    }

    @Test func concurrentUseOfDistinctShapes() async throws {
        let base = try cube(10)
        try await withThrowingTaskGroup(of: Double.self) { group in
            for i in 0..<8 {
                let copy = try base.copy()
                group.addTask {
                    let f = try copy.filleted(edges: [i % 12], radius: 1)
                    let mesh = try f.tessellate()
                    return meshVolume(mesh)
                }
            }
            for try await v in group { #expect(v > 990 && v < 1000) }
        }
    }
}
