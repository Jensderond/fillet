import FilletKernel
import Foundation
import simd

/// Checks that a triangle mesh is a closed, consistently oriented, manifold surface: what a
/// slicer needs to print it without repairs.
public struct MeshCheck: Sendable, CustomStringConvertible {
    public var vertices = 0
    public var triangles = 0
    /// Edges used by one triangle only (holes).
    public var openEdges = 0
    /// Edges shared by more than two triangles.
    public var nonManifoldEdges = 0
    /// Edges whose two triangles run the same way along them (a flipped neighbour).
    public var flippedEdges = 0
    /// Triangles with (nearly) no area or repeated corners.
    public var degenerateTriangles = 0
    /// Pairs of non-neighbouring triangles that cross (sampled check, see ``check(_:selfIntersections:)``).
    public var intersectingPairs = 0
    /// Whether the self-intersection test ran.
    public var checkedIntersections = false
    /// Enclosed volume, mm³ (negative: the surface faces inward).
    public var volume = 0.0
    public var boundsMin = SIMD3<Double>.zero
    public var boundsMax = SIMD3<Double>.zero

    public var isWatertight: Bool { openEdges == 0 && nonManifoldEdges == 0 && flippedEdges == 0 }
    public var passes: Bool { isWatertight && degenerateTriangles == 0 && intersectingPairs == 0 && volume > 0 }

    /// One line: "PASS watertight manifold, 120384 triangles, …" or "FAIL 12 open edges, …".
    public var description: String {
        var problems: [String] = []
        if openEdges > 0 { problems.append("\(openEdges) open edges") }
        if nonManifoldEdges > 0 { problems.append("\(nonManifoldEdges) non-manifold edges") }
        if flippedEdges > 0 { problems.append("\(flippedEdges) flipped edges") }
        if degenerateTriangles > 0 { problems.append("\(degenerateTriangles) degenerate triangles") }
        if intersectingPairs > 0 { problems.append("\(intersectingPairs) self-intersecting triangle pairs") }
        if volume <= 0 { problems.append("volume \(String(format: "%.1f", volume)) mm³ (inside out?)") }
        let size = boundsMax - boundsMin
        let facts = "\(triangles) triangles, \(vertices) vertices, volume \(String(format: "%.1f", volume)) mm³, size "
            + String(format: "%.2f × %.2f × %.2f mm", size.x, size.y, size.z)
            + (checkedIntersections ? "" : ", self-intersections not checked")
        return problems.isEmpty ? "PASS watertight manifold, \(facts)" : "FAIL \(problems.joined(separator: ", ")); \(facts)"
    }

    /// Checks `mesh` after welding its vertices by exact position (as the 3MF writer does).
    /// `selfIntersections` runs the (slower) crossing-triangle test.
    public static func check(_ mesh: Mesh, selfIntersections: Bool = true) -> MeshCheck {
        let welded = WorkMesh(welding: mesh)
        return check(points: welded.points, triangles: welded.triangles, droppedDegenerate: degenerateCount(mesh),
                     selfIntersections: selfIntersections)
    }

    /// Triangles of `mesh` whose corners weld together (dropped when welding).
    private static func degenerateCount(_ mesh: Mesh) -> Int {
        var n = 0
        for t in 0..<(mesh.indices.count / 3) {
            let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            if a == b || b == c || a == c { n += 1 }
        }
        return n
    }

    static func check(points: [SIMD3<Double>], triangles: [SIMD3<Int32>], droppedDegenerate: Int = 0,
                      selfIntersections: Bool) -> MeshCheck {
        var r = MeshCheck()
        r.vertices = points.count
        r.triangles = triangles.count + droppedDegenerate
        r.degenerateTriangles = droppedDegenerate
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if points.isEmpty { lo = .zero; hi = .zero }
        r.boundsMin = lo
        r.boundsMax = hi
        let scale = max(simd_length(hi - lo), 1e-9)

        // Directed edge counts: each undirected edge must appear exactly once in each direction.
        var forward: [UInt64: Int32] = [:], backward: [UInt64: Int32] = [:]
        forward.reserveCapacity(triangles.count * 3 / 2)
        backward.reserveCapacity(triangles.count * 3 / 2)
        var volume = 0.0
        for tri in triangles {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            volume += simd_dot(a, simd_cross(b, c)) / 6
            if simd_length(simd_cross(b - a, c - a)) < 1e-12 * scale * scale { r.degenerateTriangles += 1 }
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                let k = WorkMesh.key(p, q)
                if p < q { forward[k, default: 0] += 1 } else { backward[k, default: 0] += 1 }
            }
        }
        r.volume = volume
        let keys = Set(forward.keys).union(backward.keys)
        for k in keys {
            let f = Int(forward[k] ?? 0), b = Int(backward[k] ?? 0)
            switch (f, b) {
            case (1, 1): break
            case _ where f + b == 1: r.openEdges += 1
            case _ where f + b > 2: r.nonManifoldEdges += 1
            default: r.flippedEdges += 1  // (2, 0) or (0, 2)
            }
        }
        if selfIntersections {
            r.checkedIntersections = true
            r.intersectingPairs = crossingPairs(points: points, triangles: triangles)
        }
        return r
    }

    /// Pairs of triangles sharing no vertex that intersect, found through a uniform grid.
    static func crossingPairs(points: [SIMD3<Double>], triangles: [SIMD3<Int32>], limit: Int = 10_000) -> Int {
        guard !triangles.isEmpty else { return 0 }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        // About two triangles per cell on average, by the mean triangle size.
        var meanEdge = 0.0
        let sample = stride(from: 0, to: triangles.count, by: max(1, triangles.count / 2000))
        var sampled = 0
        for t in sample {
            let tri = triangles[t]
            meanEdge += simd_distance(points[Int(tri.x)], points[Int(tri.y)])
            sampled += 1
        }
        meanEdge /= Double(max(sampled, 1))
        let cell = max(meanEdge * 2, simd_length(hi - lo) / 400, 1e-6)
        func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>(((p - lo) / cell).rounded(.down)) }
        func pack(_ c: SIMD3<Int32>) -> UInt64 {
            UInt64(UInt32(bitPattern: c.x) & 0x1FFFFF) << 42 | UInt64(UInt32(bitPattern: c.y) & 0x1FFFFF) << 21
                | UInt64(UInt32(bitPattern: c.z) & 0x1FFFFF)
        }
        var grid: [UInt64: [Int32]] = [:]
        for (t, tri) in triangles.enumerated() {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let c0 = cellOf(simd_min(simd_min(a, b), c)), c1 = cellOf(simd_max(simd_max(a, b), c))
            guard (c1.x - c0.x + 1) * (c1.y - c0.y + 1) * (c1.z - c0.z + 1) <= 512 else { continue }
            for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z { grid[pack(SIMD3(x, y, z)), default: []].append(Int32(t)) } } }
        }
        var pairs = Set<UInt64>()
        var boxes: [(SIMD3<Double>, SIMD3<Double>)] = []
        boxes.reserveCapacity(triangles.count)
        for tri in triangles {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            boxes.append((simd_min(simd_min(a, b), c), simd_max(simd_max(a, b), c)))
        }
        for (_, list) in grid where list.count > 1 {
            for i in 0..<list.count {
                let s = Int(list[i])
                let ta = triangles[s], ba = boxes[s]
                for j in (i + 1)..<list.count {
                    let t = Int(list[j])
                    let tb = triangles[t], bb = boxes[t]
                    guard all(ba.0 .<= bb.1), all(bb.0 .<= ba.1) else { continue }
                    if ta.x == tb.x || ta.x == tb.y || ta.x == tb.z || ta.y == tb.x || ta.y == tb.y || ta.y == tb.z
                        || ta.z == tb.x || ta.z == tb.y || ta.z == tb.z { continue }
                    guard trianglesIntersect(points[Int(ta.x)], points[Int(ta.y)], points[Int(ta.z)],
                                             points[Int(tb.x)], points[Int(tb.y)], points[Int(tb.z)]) else { continue }
                    if pairs.insert(WorkMesh.key(Int32(s), Int32(t))).inserted, pairs.count >= limit { return pairs.count }
                }
            }
        }
        return pairs.count
    }

    /// Whether two triangles cross (edge-against-triangle tests both ways).
    static func trianglesIntersect(_ a0: SIMD3<Double>, _ a1: SIMD3<Double>, _ a2: SIMD3<Double>,
                                   _ b0: SIMD3<Double>, _ b1: SIMD3<Double>, _ b2: SIMD3<Double>) -> Bool {
        func segmentHits(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ v0: SIMD3<Double>, _ v1: SIMD3<Double>, _ v2: SIMD3<Double>) -> Bool {
            let e1 = v1 - v0, e2 = v2 - v0, d = q - p
            let h = simd_cross(d, e2)
            let det = simd_dot(e1, h)
            let scale = simd_length(e1) * simd_length(e2) * simd_length(d)
            guard abs(det) > 1e-9 * scale else { return false }
            let f = 1 / det
            let s = p - v0
            let u = f * simd_dot(s, h)
            guard u > 1e-9, u < 1 - 1e-9 else { return false }
            let qv = simd_cross(s, e1)
            let v = f * simd_dot(d, qv)
            guard v > 1e-9, u + v < 1 - 1e-9 else { return false }
            let t = f * simd_dot(e2, qv)
            return t > 1e-9 && t < 1 - 1e-9
        }
        return segmentHits(a0, a1, b0, b1, b2) || segmentHits(a1, a2, b0, b1, b2) || segmentHits(a2, a0, b0, b1, b2)
            || segmentHits(b0, b1, a0, a1, a2) || segmentHits(b1, b2, a0, a1, a2) || segmentHits(b2, b0, a0, a1, a2)
    }
}
