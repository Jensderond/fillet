import Foundation
import simd

extension WorkMesh {
    /// Data-dependent edge flips after displacement: where a crease of the texture (the fold
    /// between two strands of yarn, the foot of a dot) runs across the subdivided grid, its
    /// triangles zig-zag over it and it renders as a saw-tooth. Swapping the diagonal of two
    /// neighbouring triangles to the one that bends least (the smallest sum of angles between
    /// the normals across the quad's five edges) lines the edges up along the crease instead.
    ///
    /// Only flips inside one textured face, only where the quad is convex on the undisplaced
    /// surface `base` and the new triangles don't turn over, and never onto an edge that already
    /// exists, so the mesh stays manifold, conforming and the same shape apart from the crease.
    mutating func alignCreases(base: [SIMD3<Double>], where include: (Int32) -> Bool, passes: Int = 6) {
        // Nothing to do on a mesh without such faces (a layout in space only).
        var lastFace = Int32.min, any = false
        for f in faces where f != lastFace {
            lastFace = f
            if include(f) { any = true; break }
        }
        guard any else { return }
        // The pass in which each point was last a corner of a flipped quad (-1: never). After
        // the first pass only edges of triangles with such a corner from the pass before, or
        // from earlier in this one, are tried again: every other quad is the same as when it
        // was turned down in the pass before. Its two triangles, its four neighbours, its edges
        // and whether its other diagonal exists each involve two of its corners, at least one
        // of them a corner of the triangle its edge is listed under (a, b or c below), and a
        // flip changes only triangles and edges among its own quad's corners (and only
        // touches triangles sharing two of them).
        var flipped = [Int32](repeating: -1, count: points.count)
        // Edge -> the (up to) two triangles on it, the lower index first.
        var edges = EdgeMap<SIMD2<Int32>>(capacity: 0, filler: SIMD2(-1, -1))
        // Whether some edge has more than two triangles (only the first and last are kept).
        var nonManifold = false
        for pass in 0..<passes {
            let recent = Int32(pass - 1)
            // Built once and then kept up to date flip by flip (below), except on a non-manifold
            // mesh, where it is built again for every pass as the triangles stand.
            if pass == 0 || nonManifold {
                edges = EdgeMap<SIMD2<Int32>>(capacity: triangles.count * 3 / 2, filler: SIMD2(-1, -1))
                nonManifold = false
                for t in triangles.indices {
                    let tri = triangles[t]
                    for k in 0..<3 {
                        let (slot, found) = edges.findOrInsert(Self.key(tri[k], tri[(k + 1) % 3]))
                        if found {
                            var pair = edges.values[slot]
                            if pair.y >= 0 { nonManifold = true }
                            pair.y = Int32(t)
                            edges.set(slot: slot, pair)
                        } else {
                            edges.set(slot: slot, SIMD2(Int32(t), -1))
                        }
                    }
                }
            }
            // The edges with nothing to flip whatever this pass flips first, worked out across
            // the cores (bit k of a triangle's: its k-th edge): listed under another triangle or
            // on the mesh's edge, or their quad turned down. Whether a quad flips depends on the
            // pass's flips so far only through `touched` and `created`: a flip touches every
            // triangle sharing an edge with its quad, so a quad whose two triangles are
            // untouched has the same triangles and neighbours as when the pass began (on a
            // manifold mesh: with an edge of three triangles `edges` keeps only two of them, so
            // there it is all worked out one by one, as before). So a clear bit means the quad
            // flips, as long as its triangles are still untouched when the loop below gets to it,
            // unless the triangle was skipped here (`unknown`: none of its corners was in a flip
            // of the pass before, but one may be in an earlier flip of this one).
            let unknown: UInt8 = 1 << 7
            var nothing: [UInt8] = []
            if !nonManifold {
                let mesh = self, edges = edges, flipped = flipped
                nothing = concurrentMap(triangles.count) { t in
                    let tri = mesh.triangles[t]
                    if pass > 0, flipped[Int(tri.x)] < recent, flipped[Int(tri.y)] < recent, flipped[Int(tri.z)] < recent { return unknown }
                    var bits: UInt8 = 0
                    for k in 0..<3 {
                        guard let pair = edges[Self.key(tri[k], tri[(k + 1) % 3])], Int(pair.x) == t, pair.y >= 0,
                              mesh.creaseFlip(t, Int(pair.y), edges: edges, base: base, where: include) != nil
                        else { bits |= 1 << k; continue }
                    }
                    return bits
                }
            }
            var touched = [Bool](repeating: false, count: triangles.count)
            var done: [(t1: Int32, t2: Int32, a: Int32, b: Int32, c: Int32, d: Int32)] = []
            var created = EdgeMap<Bool>(capacity: 1024, filler: true)
            // Edges in triangle order (not the dictionary's, which changes from run to run), so
            // the same design always exports the same mesh.
            let snapshot = triangles
            for (t, tri) in snapshot.enumerated() { for k in 0..<3 {
                if pass > 0, flipped[Int(tri.x)] < recent, flipped[Int(tri.y)] < recent, flipped[Int(tri.z)] < recent { break }
                if !nothing.isEmpty, nothing[t] & (1 << k) != 0 { continue }
                guard let pair = edges[Self.key(tri[k], tri[(k + 1) % 3])], Int(pair.x) == t, pair.y >= 0 else { continue }
                let t1 = Int(pair.x), t2 = Int(pair.y)
                guard !touched[t1], !touched[t2] else { continue }
                // Known to flip from the verdict above: only its corners are needed.
                let known = !nothing.isEmpty && nothing[t] & unknown == 0
                guard let (a, b, c, d) = known ? quadCorners(t1, t2) : creaseFlip(t1, t2, edges: edges, base: base, where: include),
                      !created.contains(Self.key(c, d)) else { continue }
                triangles[t1] = SIMD3(a, d, c)
                triangles[t2] = SIMD3(d, b, c)
                touched[t1] = true
                touched[t2] = true
                flipped[Int(a)] = Int32(pass)
                flipped[Int(b)] = Int32(pass)
                flipped[Int(c)] = Int32(pass)
                flipped[Int(d)] = Int32(pass)
                created.set(Self.key(c, d), true)
                // Their neighbours' entries in `edges` are stale now; they are brought up to date
                // after the pass.
                for (p, q) in [(b, c), (c, a), (a, d), (d, b)] {
                    if let e = edges[Self.key(p, q)] {
                        if e.x >= 0 { touched[Int(e.x)] = true }
                        if e.y >= 0 { touched[Int(e.y)] = true }
                    }
                }
                done.append((Int32(t1), Int32(t2), a, b, c, d))
            } }
            if done.isEmpty { return }
            guard !nonManifold, pass < passes - 1 else { continue }
            // Each flip into `edges`, which then holds what building it again would: (a, b) goes,
            // (c, d) comes in with t1 < t2, (b, c) moves from t1 to t2 and (a, d) from t2 to t1,
            // and (c, a) and (d, b) keep theirs. The mesh stays manifold (a flip never makes an
            // edge that is there already), and two flips of one pass share no edge (each would
            // have touched the other's triangles), so they don't interfere.
            func moved(_ pair: SIMD2<Int32>, from old: Int32, to new: Int32) -> SIMD2<Int32> {
                let other = pair.x == old ? pair.y : pair.x
                return other < 0 ? SIMD2(new, -1) : SIMD2(min(new, other), max(new, other))
            }
            for f in done {
                edges.remove(Self.key(f.a, f.b))
                edges.set(Self.key(f.c, f.d), SIMD2(f.t1, f.t2))
                let bc = Self.key(f.b, f.c), ad = Self.key(f.a, f.d)
                edges.set(bc, moved(edges[bc]!, from: f.t1, to: f.t2))
                edges.set(ad, moved(edges[ad]!, from: f.t2, to: f.t1))
            }
        }
    }

    /// The quad of triangles `t1` = (a, b, c) and `t2` = (b, a, d) (in their winding order), when
    /// ``alignCreases(base:where:passes:)`` would swap its diagonal for (c, d): both inside one
    /// face `include` accepts, (c, d) not an edge in `edges`, valid on `base` and displaced, and
    /// bending less. Leaves out only what the pass's earlier flips decide (touched triangles,
    /// diagonals made in this pass).
    func creaseFlip(_ t1: Int, _ t2: Int, edges: EdgeMap<SIMD2<Int32>>, base: [SIMD3<Double>],
                    where include: (Int32) -> Bool) -> (Int32, Int32, Int32, Int32)? {
        let cosLimit = cos(80.0 * .pi / 180)
        func normal(_ p: [SIMD3<Double>], _ a: Int32, _ b: Int32, _ c: Int32) -> SIMD3<Double> {
            simd_cross(p[Int(b)] - p[Int(a)], p[Int(c)] - p[Int(a)])
        }
        func angle(_ n1: SIMD3<Double>, _ n2: SIMD3<Double>) -> Double {
            let l = simd_length(n1) * simd_length(n2)
            guard l > 0 else { return .pi }
            return acos(max(-1, min(1, simd_dot(n1, n2) / l)))
        }
        guard faces[t1] == faces[t2], include(faces[t1]),
              let (a, b, c, d) = quadCorners(t1, t2),
              edges[Self.key(c, d)] == nil else { return nil }

        // Valid on the undisplaced surface: both new triangles face the same way as the old.
        let baseNormal = normal(base, a, b, c) + normal(base, b, a, d)
        let bn1 = normal(base, a, d, c), bn2 = normal(base, d, b, c)
        let baseArea = simd_length(baseNormal)
        guard baseArea > 0,
              simd_dot(bn1, baseNormal) > 0.02 * simd_length(bn1) * baseArea,
              simd_dot(bn2, baseNormal) > 0.02 * simd_length(bn2) * baseArea,
              simd_length(bn1) > 0.05 * baseArea, simd_length(bn2) > 0.05 * baseArea else { return nil }
        // And displaced, they don't turn over.
        let n1 = normal(points, a, d, c), n2 = normal(points, d, b, c)
        guard simd_dot(n1, baseNormal) > cosLimit * simd_length(n1) * baseArea,
              simd_dot(n2, baseNormal) > cosLimit * simd_length(n2) * baseArea else { return nil }

        // Bending across the diagonal and the four outer edges, before and after.
        let o1 = normal(points, a, b, c), o2 = normal(points, b, a, d)
        func outside(_ p: Int32, _ q: Int32, _ own: Int) -> SIMD3<Double>? {
            guard let e = edges[Self.key(p, q)] else { return nil }
            let other = Int(e.x) == own ? Int(e.y) : Int(e.x)
            guard other >= 0 else { return nil }
            let t = triangles[other]
            return normal(points, t.x, t.y, t.z)
        }
        let nbc = outside(b, c, t1), nca = outside(c, a, t1)
        let nad = outside(a, d, t2), ndb = outside(d, b, t2)
        var before = angle(o1, o2), after = angle(n1, n2)
        if let n = nbc { before += angle(o1, n); after += angle(n2, n) }
        if let n = nca { before += angle(o1, n); after += angle(n1, n) }
        if let n = nad { before += angle(o2, n); after += angle(n1, n) }
        if let n = ndb { before += angle(o2, n); after += angle(n2, n) }
        guard after < before - 0.05 else { return nil }
        return (a, b, c, d)
    }
}

extension WorkMesh {
    /// The corners of the quad of triangles `t1` = (a, b, c) and `t2` = (b, a, d), named in
    /// their winding order, or nil when they don't share an edge or don't make a quad.
    func quadCorners(_ t1: Int, _ t2: Int) -> (Int32, Int32, Int32, Int32)? {
        func has(_ t: SIMD3<Int32>, _ v: Int32) -> Bool { t.x == v || t.y == v || t.z == v }
        let tri1 = triangles[t1], tri2 = triangles[t2]
        var k1 = -1
        for k in 0..<3 where has(tri2, tri1[k]) && has(tri2, tri1[(k + 1) % 3]) { k1 = k }
        guard k1 >= 0 else { return nil }
        let a = tri1[k1], b = tri1[(k1 + 1) % 3], c = tri1[(k1 + 2) % 3]
        // The first corner of t2 that isn't a or b.
        let d = tri2.x != a && tri2.x != b ? tri2.x : (tri2.y != a && tri2.y != b ? tri2.y : tri2.z)
        guard d != a, d != b, d != c else { return nil }
        return (a, b, c, d)
    }

    /// Of `candidates` (vertices on an edge between textured faces whose triangles meet at more
    /// than `angle`), the ones where the faces really meet at an angle: compares each face's
    /// area-weighted normal around the vertex rather than single triangles, so a tangent seam,
    /// such as a side wall running into a rounded rim that the kernel tessellated into coarse
    /// facets, isn't mistaken for a sharp edge (and the texture isn't pinned to it in patches).
    /// Where the kernel gave each face's own normal at the vertex (``surfaceNormal(_:face:)``),
    /// those decide: near the tip of a corner blend its tessellation is all slivers, whose
    /// normals can stand 30° apart where the faces meet smoothly.
    /// `around` is the mesh's ``vertexFaces()``, when the caller has it already.
    func sharpCreaseVertices(_ candidates: Set<Int>, angle: Double, where include: (Int32) -> Bool,
                             around: VertexFaces? = nil) -> Set<Int> {
        guard !candidates.isEmpty else { return candidates }
        let cosAngle = cos(angle)
        var kernel: [Int: Bool] = [:]
        if !surfaceNormals.isEmpty {
            let around = around ?? vertexFaces()
            for v in candidates {
                // Only each face's own normal there (not the one the point falls back to).
                let normals = around.faces(of: v).filter(include).compactMap { edgeNormals[Self.pointFace(Int32(v), $0)] }
                guard normals.count > 1, normals.count == around.faces(of: v).filter(include).count,
                      !normals.contains(.zero) else { continue }
                var sharp = false
                for i in normals.indices {
                    for j in normals.indices where j > i && simd_dot(normals[i], normals[j]) < cosAngle { sharp = true }
                }
                kernel[v] = sharp
            }
        }
        var sums: [Int: [Int32: SIMD3<Double>]] = [:]
        // The candidates by vertex, to test every triangle's corners without hashing.
        var candidate = [Bool](repeating: false, count: points.count)
        for v in candidates { candidate[v] = true }
        for (t, tri) in triangles.enumerated() where include(faces[t]) {
            guard candidate[Int(tri.x)] || candidate[Int(tri.y)] || candidate[Int(tri.z)] else { continue }
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let n = simd_cross(b - a, c - a)
            for v in [tri.x, tri.y, tri.z] where candidate[Int(v)] {
                sums[Int(v), default: [:]][faces[t], default: .zero] += n
            }
        }
        let cosLimit = cos(angle)
        return candidates.filter { v in
            if let sharp = kernel[v] { return sharp }
            let normals = (sums[v] ?? [:]).values.compactMap { n -> SIMD3<Double>? in
                let l = simd_length(n)
                return l > 0 ? n / l : nil
            }
            for i in normals.indices {
                for j in normals.indices where j > i && simd_dot(normals[i], normals[j]) < cosLimit { return true }
            }
            return false
        }
    }
}
