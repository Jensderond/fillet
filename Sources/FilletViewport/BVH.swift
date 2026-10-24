import Foundation
import simd
import FilletKernel

/// Bounding volume hierarchy over a mesh's triangles for CPU ray casts.
/// Immutable after construction.
public final class TriangleBVH: @unchecked Sendable {
    struct Node {
        var lo: SIMD3<Float>
        var hi: SIMD3<Float>
        /// Leaf: first entry in `order`. Inner: index of the left child.
        var a: Int32
        /// Leaf: triangle count (> 0). Inner: -(index of the right child) - 1.
        var b: Int32
    }

    /// Result of a ray cast.
    public struct Hit: Sendable {
        /// Distance along the ray.
        public var t: Double
        /// Triangle index (into `mesh.indices` / 3).
        public var triangle: Int
        /// Barycentric weights of the 2nd and 3rd vertex.
        public var u: Double
        public var v: Double
    }

    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    private var nodes: [Node] = []
    private var order: [Int32] = []
    private var depth = 0

    /// Number of nodes (exposed for tests).
    public var nodeCount: Int { nodes.count }
    /// Depth of the tree (exposed for tests).
    public var maxDepth: Int { depth }

    public init(mesh: Mesh, leafSize: Int = 4) {
        positions = mesh.positions
        indices = mesh.indices
        let triCount = mesh.indices.count / 3
        guard triCount > 0 else { return }
        var b = Builder(triCount: triCount, leafSize: max(leafSize, 1))
        for t in 0..<triCount {
            let p0 = positions[Int(indices[3 * t])], p1 = positions[Int(indices[3 * t + 1])], p2 = positions[Int(indices[3 * t + 2])]
            b.tlo[t] = simd_min(p0, simd_min(p1, p2))
            b.thi[t] = simd_max(p0, simd_max(p1, p2))
            b.centroids[t] = (p0 + p1 + p2) / 3
        }
        _ = b.build(0, triCount, level: 1)
        nodes = b.nodes
        order = b.order
        depth = b.depth
    }

    private struct Builder {
        var centroids: [SIMD3<Float>]
        var tlo: [SIMD3<Float>]
        var thi: [SIMD3<Float>]
        var order: [Int32]
        var nodes: [Node] = []
        var depth = 0
        let leafSize: Int

        init(triCount: Int, leafSize: Int) {
            centroids = .init(repeating: .zero, count: triCount)
            tlo = centroids
            thi = centroids
            order = (0..<Int32(triCount)).map { $0 }
            self.leafSize = leafSize
            nodes.reserveCapacity(2 * triCount / leafSize + 2)
        }

        mutating func build(_ start: Int, _ end: Int, level: Int) -> Int32 {
            depth = max(depth, level)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            var clo = lo, chi = hi
            for i in start..<end {
                let t = Int(order[i])
                lo = simd_min(lo, tlo[t]); hi = simd_max(hi, thi[t])
                clo = simd_min(clo, centroids[t]); chi = simd_max(chi, centroids[t])
            }
            let index = Int32(nodes.count)
            let n = end - start
            let ext = chi - clo
            if n <= leafSize || simd_reduce_max(ext) <= 0 {
                nodes.append(Node(lo: lo, hi: hi, a: Int32(start), b: Int32(n)))
                return index
            }
            nodes.append(Node(lo: lo, hi: hi, a: 0, b: 0))
            let axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2)
            let c = centroids
            order[start..<end].sort { c[Int($0)][axis] < c[Int($1)][axis] }
            let mid = start + n / 2
            let left = build(start, mid, level: level + 1)
            let right = build(mid, end, level: level + 1)
            nodes[Int(index)].a = left
            nodes[Int(index)].b = -right - 1
            return index
        }
    }

    /// Nearest intersection of the ray with any triangle (two-sided), or nil.
    public func intersect(origin: SIMD3<Double>, direction: SIMD3<Double>, maxT: Double = .infinity) -> Hit? {
        guard !nodes.isEmpty else { return nil }
        let of = SIMD3<Float>(origin)
        let df = SIMD3<Float>(direction)
        let inv = SIMD3<Float>(1 / df.x, 1 / df.y, 1 / df.z)
        var best: Hit?
        var bestT = maxT
        var stack: [Int32] = [0]
        stack.reserveCapacity(64)
        while let ni = stack.popLast() {
            let node = nodes[Int(ni)]
            guard let tn = slab(node.lo, node.hi, of, inv), Double(tn) <= bestT else { continue }
            if node.b > 0 {
                for i in Int(node.a)..<Int(node.a + node.b) {
                    let t = Int(order[i])
                    if let h = triangle(t, origin, direction), h.t < bestT {
                        bestT = h.t
                        best = h
                    }
                }
            } else {
                stack.append(-node.b - 1)
                stack.append(node.a)
            }
        }
        return best
    }

    /// Ray/box slab test with a small relative tolerance. Returns the entry distance.
    @inline(__always) private func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ o: SIMD3<Float>, _ inv: SIMD3<Float>) -> Float? {
        var tmin: Float = 0, tmax: Float = .greatestFiniteMagnitude
        let pad = (hi - lo) * 1e-4 + 1e-4
        for k in 0..<3 {
            let l = lo[k] - pad[k], h = hi[k] + pad[k]
            if inv[k].isInfinite {
                if o[k] < l || o[k] > h { return nil }
                continue
            }
            var t0 = (l - o[k]) * inv[k], t1 = (h - o[k]) * inv[k]
            if t0 > t1 { swap(&t0, &t1) }
            tmin = max(tmin, t0)
            tmax = min(tmax, t1)
            if tmin > tmax { return nil }
        }
        return tmin
    }

    /// Möller–Trumbore in double precision, two-sided.
    @inline(__always) func triangle(_ t: Int, _ o: SIMD3<Double>, _ d: SIMD3<Double>) -> Hit? {
        let a = SIMD3<Double>(positions[Int(indices[3 * t])])
        let b = SIMD3<Double>(positions[Int(indices[3 * t + 1])])
        let c = SIMD3<Double>(positions[Int(indices[3 * t + 2])])
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-14 else { return nil }
        let invDet = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * invDet
        guard u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * invDet
        guard v >= -1e-9, u + v <= 1 + 1e-9 else { return nil }
        let tt = simd_dot(e2, q) * invDet
        guard tt >= 0 else { return nil }
        return Hit(t: tt, triangle: t, u: u, v: v)
    }

    /// Brute-force reference (tests).
    public func intersectBruteForce(origin: SIMD3<Double>, direction: SIMD3<Double>) -> Hit? {
        var best: Hit?
        for t in 0..<(indices.count / 3) {
            if let h = triangle(t, origin, direction), h.t < (best?.t ?? .infinity) { best = h }
        }
        return best
    }
}
