import Foundation
import simd

extension WorkMesh {
    /// Wall left between a texture cut into the surface and the surface behind it (mm), at most:
    /// thinner walls keep half their thickness. About two perimeters of a 0.4 mm nozzle.
    static let minimumWall = 0.8
    /// Gap left between relief standing out of a surface and another surface in front of it (a
    /// hole's opposite side, a concave corner), at most: closer ones keep half the gap.
    static let minimumGap = 0.2

    /// Shortens displacements that would carry a point through the body: a deep crevice or
    /// recessed dot on a thin wall would come out the other side, a raised one inside a narrow
    /// hole would cross the opposite side. Each moved point looks along its displacement (on the
    /// undisplaced mesh) for the nearest other surface; the displacement stops short of it by
    /// ``minimumWall`` going into the body or ``minimumGap`` going out of it, and by half the
    /// distance when that surface is textured too (it may move towards this one).
    ///
    /// A point's displacement is scaled down as a whole, and its neighbours' with it, easing back
    /// to full over `ramp` mm along the surface: a dent that would cut through comes out shallower
    /// but keeps its shape, instead of a flattened bottom with folds where it starts.
    func limitThroughWalls(_ offsets: inout [SIMD3<Double>], ramp: Double, where textured: (Int32) -> Bool) {
        let normals = vertexNormals(where: textured)
        // The moved points and how far each needs to look.
        var moved: [(v: Int, dir: SIMD3<Double>, reach: Double, inward: Bool)] = []
        for v in offsets.indices where offsets[v] != .zero {
            let length = simd_length(offsets[v])
            guard length > 1e-9 else { continue }
            let dir = offsets[v] / length
            let inward = simd_dot(dir, normals[v]) < 0
            moved.append((v, dir, length + (inward ? Self.minimumWall : Self.minimumGap), inward))
        }
        guard !moved.isEmpty else { return }

        // A grid of the triangles, walked cell by cell along each query's short segment.
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var meanEdge = 0.0, sampled = 0
        for t in stride(from: 0, to: triangles.count, by: max(1, triangles.count / 2000)) {
            meanEdge += simd_distance(points[Int(triangles[t].x)], points[Int(triangles[t].y)])
            sampled += 1
        }
        meanEdge /= Double(max(sampled, 1))
        let grid = TriangleGrid(points: points, triangles: triangles, lo: lo, hi: hi, meanEdge: meanEdge)

        // The nearest surface along each query's segment: cells in the order the segment crosses
        // them, stopping once a hit lies within the cell being searched.
        var scale = [Double](repeating: 1, count: points.count)
        let chunk = 2048
        let points = self.points, triangles = self.triangles
        let isTextured = faces.map(textured)
        let queries = moved
        let found = UnsafeMutableBufferPointer<(nearest: Double, textured: Bool)>.allocate(capacity: queries.count)
        defer { found.deallocate() }
        let out = SendableBuffer(found)
        DispatchQueue.concurrentPerform(iterations: (queries.count + chunk - 1) / chunk) { block in
            for qi in (block * chunk)..<min(queries.count, (block + 1) * chunk) {
                let q = queries[qi]
                let origin = points[q.v]
                var c = grid.cellOf(origin)
                let step = SIMD3<Int>(q.dir.x > 0 ? 1 : -1, q.dir.y > 0 ? 1 : -1, q.dir.z > 0 ? 1 : -1)
                var tMax = SIMD3<Double>(repeating: .infinity), tDelta = SIMD3<Double>(repeating: .infinity)
                for k in 0..<3 where abs(q.dir[k]) > 1e-12 {
                    let edge = grid.lo[k] + Double(c[k] + (step[k] > 0 ? 1 : 0)) * grid.cell
                    tMax[k] = (edge - origin[k]) / q.dir[k]
                    tDelta[k] = grid.cell / abs(q.dir[k])
                }
                var nearest = Double.infinity, nearestTextured = false
                while true {
                    let i = grid.index(c)
                    for s in Int(grid.start[i])..<Int(grid.start[i + 1]) {
                        let t = Int(grid.cells[s])
                        let tri = triangles[t]
                        // Not the triangles around the point itself.
                        guard Int(tri.x) != q.v, Int(tri.y) != q.v, Int(tri.z) != q.v else { continue }
                        if let d = Self.rayHit(origin, q.dir, points[Int(tri.x)], points[Int(tri.y)], points[Int(tri.z)]),
                           d > 1e-6, d < nearest {
                            nearest = d
                            nearestTextured = isTextured[t]
                        }
                    }
                    let exit = tMax.min()
                    if nearest <= exit || exit > q.reach { break }
                    let k = tMax.x == exit ? 0 : (tMax.y == exit ? 1 : 2)
                    c[k] += step[k]
                    guard c[k] >= 0, c[k] < grid.dims[k] else { break }
                    tMax[k] += tDelta[k]
                }
                out.buffer[qi] = (nearest, nearestTextured)
            }
        }
        var limited = false
        for (qi, q) in queries.enumerated() {
            let (nearest, nearestTextured) = found[qi]
            guard nearest <= q.reach else { continue }
            let keep = min(q.inward ? Self.minimumWall : Self.minimumGap, nearest / 2)
            let allowed = max(0, nearest - keep) * (nearestTextured ? 0.5 : 1)
            let length = simd_length(offsets[q.v])
            if length > allowed {
                scale[q.v] = allowed / length
                limited = true
            }
        }
        guard limited else { return }
        easeScale(&scale, over: max(ramp, 1e-3))
        for v in offsets.indices where scale[v] < 1 { offsets[v] *= scale[v] }
    }

    /// Lowers `scale` so it grows by at most 1 per `ramp` mm along mesh edges away from any point
    /// (the smallest scale(u) + distance(u, v) / ramp), so a limited point pulls its surroundings
    /// down gradually.
    func easeScale(_ scale: inout [Double], over ramp: Double) {
        var degree = [Int](repeating: 0, count: points.count + 1)
        for tri in triangles { degree[Int(tri.x)] += 2; degree[Int(tri.y)] += 2; degree[Int(tri.z)] += 2 }
        var start = [Int](repeating: 0, count: points.count + 1)
        for i in 0..<points.count { start[i + 1] = start[i] + degree[i] }
        var fill = start
        var neighbours = [Int32](repeating: 0, count: start[points.count])
        for tri in triangles {
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                neighbours[fill[Int(p)]] = q; fill[Int(p)] += 1
                neighbours[fill[Int(q)]] = p; fill[Int(q)] += 1
            }
        }
        var heap = MinHeap()
        for (v, s) in scale.enumerated() where s < 1 { heap.push(s, Int32(v)) }
        while let (s, v) = heap.pop() {
            let vi = Int(v)
            guard s <= scale[vi] else { continue }
            for k in start[vi]..<start[vi + 1] {
                let w = Int(neighbours[k])
                let next = s + simd_distance(points[vi], points[w]) / ramp
                if next < scale[w] {
                    scale[w] = next
                    heap.push(next, Int32(w))
                }
            }
        }
    }

    /// Distance along the ray `origin` + t · `dir` to triangle (a, b, c), either side (Möller–Trumbore).
    static func rayHit(_ origin: SIMD3<Double>, _ dir: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>,
                       _ c: SIMD3<Double>) -> Double? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(dir, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-14 else { return nil }
        let inv = 1 / det
        let s = origin - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        return simd_dot(e2, q) * inv
    }
}

/// A uniform grid of a mesh's triangles by their bounding boxes, in compressed rows: cells about two
/// edges long, at most about 4 million of them.
private struct TriangleGrid: Sendable {
    let lo: SIMD3<Double>
    let cell: Double
    let dims: SIMD3<Int>
    /// Row starts into `cells`, one per cell plus the end.
    let start: [Int32]
    /// Triangle indices, cell by cell.
    let cells: [Int32]

    init(points: [SIMD3<Double>], triangles: [SIMD3<Int32>], lo: SIMD3<Double>, hi: SIMD3<Double>, meanEdge: Double) {
        let size = simd_max(hi - lo, SIMD3(repeating: 1e-6))
        let cell = max(2 * meanEdge, cbrt(size.x * size.y * size.z / 4e6), simd_length(size) / 2048, 1e-6)
        let dims = SIMD3<Int>(Int((size.x / cell).rounded(.down)) + 1, Int((size.y / cell).rounded(.down)) + 1,
                              Int((size.z / cell).rounded(.down)) + 1)
        self.lo = lo; self.cell = cell; self.dims = dims
        var start = [Int32](repeating: 0, count: dims.x * dims.y * dims.z + 1)
        var boxes: [(SIMD3<Int>, SIMD3<Int>)] = []
        boxes.reserveCapacity(triangles.count)
        func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int> {
            simd_clamp(SIMD3<Int>(((p - lo) / cell).rounded(.down)), .zero, dims &- 1)
        }
        func index(_ c: SIMD3<Int>) -> Int { (c.z * dims.y + c.y) * dims.x + c.x }
        for tri in triangles {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let box = (cellOf(simd_min(simd_min(a, b), c)), cellOf(simd_max(simd_max(a, b), c)))
            boxes.append(box)
            for z in box.0.z...box.1.z { for y in box.0.y...box.1.y { for x in box.0.x...box.1.x {
                start[index(SIMD3(x, y, z)) + 1] += 1
            } } }
        }
        for i in 1..<start.count { start[i] += start[i - 1] }
        var fill = start
        var cells = [Int32](repeating: 0, count: Int(start[start.count - 1]))
        for (t, box) in boxes.enumerated() {
            for z in box.0.z...box.1.z { for y in box.0.y...box.1.y { for x in box.0.x...box.1.x {
                let i = index(SIMD3(x, y, z))
                cells[Int(fill[i])] = Int32(t)
                fill[i] += 1
            } } }
        }
        self.start = start; self.cells = cells
    }

    func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int> {
        simd_clamp(SIMD3<Int>(((p - lo) / cell).rounded(.down)), .zero, dims &- 1)
    }

    func index(_ c: SIMD3<Int>) -> Int { (c.z * dims.y + c.y) * dims.x + c.x }
}

/// Lets `concurrentPerform` write distinct slots of one buffer.
private struct SendableBuffer<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
    init(_ buffer: UnsafeMutableBufferPointer<T>) { self.buffer = buffer }
}
