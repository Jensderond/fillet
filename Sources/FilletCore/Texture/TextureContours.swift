import Foundation
import simd

extension WorkMesh {
    /// Slides points of faces `solids` covers along the surface onto the nearest level line of
    /// their texture's ``SolidTexture/contour(at:normal:)``, when one passes within about a third
    /// of an edge of them.
    ///
    /// Triangles laid out regardless of a stone's outline cross its rounded edge at random: their
    /// corners land at uneven heights on the curve, and where it bends the facets catch the light
    /// as a saw-toothed fringe along the edge (worst on the viewport's coarser mesh). With the
    /// points in rows along the curve, the facets run along it too. Only points inside one face
    /// move (the edges between faces stay where they are), and a move that would turn or squash
    /// a triangle is left out.
    mutating func snapToContours(_ solids: [Int32: any SolidTexture], where movable: (Int) -> Bool) {
        guard !solids.isEmpty else { return }
        var start = [Int](repeating: 0, count: points.count + 1)
        for tri in triangles { start[Int(tri.x) + 1] += 1; start[Int(tri.y) + 1] += 1; start[Int(tri.z) + 1] += 1 }
        for i in 0..<points.count { start[i + 1] += start[i] }
        var fill = start
        var around = [Int32](repeating: 0, count: start[points.count])
        for (t, tri) in triangles.enumerated() {
            for v in [tri.x, tri.y, tri.z] { around[fill[Int(v)]] = Int32(t); fill[Int(v)] += 1 }
        }
        for v in points.indices where start[v + 1] > start[v] && movable(v) {
            let f = faces[Int(around[start[v]])]
            guard let solid = solids[f] else { continue }
            let levels = solid.contourLevels
            guard !levels.isEmpty else { continue }
            // One face all round, and its normal known.
            var shortest = Double.infinity
            var oneFace = true
            for k in start[v]..<start[v + 1] {
                let t = Int(around[k])
                if faces[t] != f { oneFace = false; break }
                let tri = triangles[t]
                for w in [tri.x, tri.y, tri.z] where Int(w) != v { shortest = min(shortest, simd_distance(points[Int(w)], points[v])) }
            }
            guard oneFace, shortest.isFinite else { continue }
            let n = surfaceNormal(Int32(v), face: f)
            guard n != .zero else { continue }
            let p = points[v]
            guard let e = solid.contour(at: p, normal: n) else { continue }
            var level = levels[0]
            for l in levels where abs(l - e) < abs(level - e) { level = l }
            let delta = level - e
            let reach = 0.35 * shortest
            guard abs(delta) > 1e-4 * reach, abs(delta) < reach else { continue }
            // The measure's gradient along the surface.
            let helper: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let t1 = simd_normalize(helper - simd_dot(helper, n) * n), t2 = simd_cross(n, t1)
            let h = 0.05 * shortest
            guard let e1 = solid.contour(at: p + h * t1, normal: n), let e2 = solid.contour(at: p + h * t2, normal: n) else { continue }
            let g = ((e1 - e) * t1 + (e2 - e) * t2) / h
            let g2 = simd_length_squared(g)
            // Off where the measure turns a corner (a stone's corner, the joint's middle).
            guard g2 > 0.25, g2 < 2.25 else { continue }
            let q = p + delta / g2 * g
            guard let eq = solid.contour(at: q, normal: n), abs(eq - level) < 0.3 * abs(delta) else { continue }
            // Every triangle round the point keeps its facing and most of its area.
            var fine = true
            for k in start[v]..<start[v + 1] {
                let tri = triangles[Int(around[k])]
                let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
                let before = simd_cross(b - a, c - a)
                let a2 = Int(tri.x) == v ? q : a, b2 = Int(tri.y) == v ? q : b, c2 = Int(tri.z) == v ? q : c
                let after = simd_cross(b2 - a2, c2 - a2)
                if simd_dot(before, after) < 0.25 * simd_length_squared(before) { fine = false; break }
            }
            guard fine else { continue }
            points[v] = q
        }
    }
}
