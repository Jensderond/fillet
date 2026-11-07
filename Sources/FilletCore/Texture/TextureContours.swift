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
            for j in 0..<3 { around[fill[Int(tri[j])]] = Int32(t); fill[Int(tri[j])] += 1 }
        }
        // The layouts by face index, and the points that may move (inside one such face, its
        // normal known) with the measure where they are now, worked out across the cores first:
        // a point only ever moves at its own turn below, so this is where it still is then.
        var solidByFace = [(any SolidTexture)?](repeating: nil, count: Int(max(faces.max() ?? -1, -1)) + 1)
        for (f, solid) in solids where f >= 0 && Int(f) < solidByFace.count { solidByFace[Int(f)] = solid }
        // Each layout's levels, asked for once: the property makes a new array every time, and
        // it was asked for at every point.
        let levelsByFace = solidByFace.map { $0?.contourLevels ?? [] }
        var candidates: [Int32] = [], candidateNormals: [SIMD3<Double>] = []
        var candidate = [Int32](repeating: -1, count: points.count)
        for v in points.indices where start[v + 1] > start[v] && movable(v) {
            let f = faces[Int(around[start[v]])]
            guard f >= 0, solidByFace[Int(f)] != nil, !levelsByFace[Int(f)].isEmpty else { continue }
            var oneFace = true
            for k in start[v]..<start[v + 1] where faces[Int(around[k])] != f { oneFace = false; break }
            guard oneFace else { continue }
            let n = surfaceNormal(Int32(v), face: f)
            guard n != .zero else { continue }
            candidate[v] = Int32(candidates.count)
            candidates.append(Int32(v))
            candidateNormals.append(n)
        }
        // The nearest neighbour's distance, the measure and where the point would go, worked
        // out across the cores from where the points are before any moves (each face's layout
        // opened once, rather than its box copied and counted for every point on every core).
        // At its turn below a point is still there, and where its nearest neighbour is still
        // as far (to the bit) everything up to the triangle check comes out the same, so only
        // the points next to an earlier move that changed that distance work it out again.
        var spans: [Int32: [Int]] = [:]
        for (i, v) in candidates.enumerated() { spans[faces[Int(around[start[Int(v)]])], default: []].append(i) }
        var planned = [ContourPlan](repeating: ContourPlan(shortest: 0, measure: nil, target: nil), count: candidates.count)
        for (f, list) in spans.sorted(by: { $0.key < $1.key }) {
            let solid = solidByFace[Int(f)]!
            let out = contourPlans(solid, list.map { Int(candidates[$0]) }, normals: list.map { candidateNormals[$0] },
                                   start: start, around: around)
            for (j, i) in list.enumerated() { planned[i] = out[j] }
        }
        for v in points.indices where candidate[v] >= 0 {
            let f = faces[Int(around[start[v]])]
            let solid = solidByFace[Int(f)]!
            // One face all round (above), and its normal known.
            var shortest = Double.infinity
            for k in start[v]..<start[v + 1] {
                let tri = triangles[Int(around[k])]
                for j in 0..<3 where Int(tri[j]) != v { shortest = min(shortest, simd_distance(points[Int(tri[j])], points[v])) }
            }
            let plan = planned[Int(candidate[v])]
            let target: SIMD3<Double>?
            if shortest.bitPattern == plan.shortest.bitPattern {
                target = plan.target
            } else if let e = plan.measure {
                target = Self.contourTarget(solid, levels: levelsByFace[Int(f)], at: points[v], normal: candidateNormals[Int(candidate[v])],
                                            measure: e, shortest: shortest)
            } else {
                target = nil
            }
            guard let q = target else { continue }
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

    /// ``ContourPlan`` of each of the points `list` (normals `normals`) of one face laid out by
    /// `solid`, across the cores; `start` and `around` list the triangles round each point.
    private func contourPlans<S: SolidTexture>(_ solid: S, _ list: [Int], normals: [SIMD3<Double>],
                                               start: [Int], around: [Int32]) -> [ContourPlan] {
        let levels = solid.contourLevels
        return concurrentMap(list.count) { j in
            let v = list[j], n = normals[j]
            var shortest = Double.infinity
            for k in start[v]..<start[v + 1] {
                let tri = triangles[Int(around[k])]
                for i in 0..<3 where Int(tri[i]) != v { shortest = min(shortest, simd_distance(points[Int(tri[i])], points[v])) }
            }
            let e = solid.contour(at: points[v], normal: n)
            let target = e.flatMap { Self.contourTarget(solid, levels: levels, at: points[v], normal: n, measure: $0, shortest: shortest) }
            return ContourPlan(shortest: shortest, measure: e, target: target)
        }
    }

    /// Where ``snapToContours(_:where:)`` would slide point `p` (normal `n`, measure `e`, its
    /// nearest neighbour `shortest` away) before checking the triangles round it: onto the
    /// nearest of `levels` along the measure's gradient, or nil when that is too far, too near or
    /// the gradient too uneven.
    static func contourTarget<S: SolidTexture>(_ solid: S, levels: [Double], at p: SIMD3<Double>, normal n: SIMD3<Double>,
                                               measure e: Double, shortest: Double) -> SIMD3<Double>? {
        guard shortest.isFinite else { return nil }
        var level = levels[0]
        for l in levels where abs(l - e) < abs(level - e) { level = l }
        let delta = level - e
        let reach = 0.35 * shortest
        guard abs(delta) > 1e-4 * reach, abs(delta) < reach else { return nil }
        // The measure's gradient along the surface.
        let helper: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let t1 = simd_normalize(helper - simd_dot(helper, n) * n), t2 = simd_cross(n, t1)
        let h = 0.05 * shortest
        guard let e1 = solid.contour(at: p + h * t1, normal: n), let e2 = solid.contour(at: p + h * t2, normal: n) else { return nil }
        let g = ((e1 - e) * t1 + (e2 - e) * t2) / h
        let g2 = simd_length_squared(g)
        // Off where the measure turns a corner (a stone's corner, the joint's middle).
        guard g2 > 0.25, g2 < 2.25 else { return nil }
        let q = p + delta / g2 * g
        guard let eq = solid.contour(at: q, normal: n), abs(eq - level) < 0.3 * abs(delta) else { return nil }
        return q
    }
}

/// One point's move in ``WorkMesh/snapToContours(_:where:)``, worked out ahead.
private struct ContourPlan {
    /// The distance to its nearest neighbour.
    var shortest: Double
    /// The texture's measure where it is (nil: none there).
    var measure: Double?
    /// Where it would go, before the triangle check (nil: it stays).
    var target: SIMD3<Double>?
}
