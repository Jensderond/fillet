import Foundation
import simd

/// A ring of straight walls: textured faces that stand vertically between the same bottom and top
/// heights and meet each other smoothly all the way around, like the sides of an extruded heart
/// or a rounded rectangle. They share one surface mapping, so a pattern runs around the whole
/// outline without a seam where one face ends and the next begins: u is the arc length along
/// the outline (counter-clockwise from above), stretched slightly so a whole number of repeats
/// fits around, and v the height above the bottom. The outline starts at its front (lowest y) with
/// the middle of a repeat, so a symmetric outline gets a symmetric pattern.
struct WallBand: Sendable {
    /// The outline at the bottom, counter-clockwise from above (first point not repeated).
    let outline: [SIMD2<Double>]
    /// Arc length at each outline point, plus the total at the end.
    let lengths: [Double]
    let bottom: Double
    let height: Double
    /// u per millimetre of outline.
    let uScale: Double
    /// u at the start of the outline: half a repeat, so one is centred there.
    let uStart: Double
    /// Buckets of segment indices on a square grid, for finding the nearest segment quickly.
    private let gridOrigin: SIMD2<Double>
    private let gridCell: Double
    private let gridSize: SIMD2<Int>
    private let buckets: [[Int32]]

    var length: Double { lengths.last ?? 0 }

    init(outline: [SIMD2<Double>], bottom: Double, height: Double, cell: Double) {
        self.outline = outline
        self.bottom = bottom
        self.height = height
        var lengths = [0.0]
        for i in outline.indices {
            lengths.append(lengths[i] + simd_distance(outline[i], outline[(i + 1) % outline.count]))
        }
        self.lengths = lengths
        let total = lengths.last ?? 0
        let repeats = max(1, (total / max(cell, 1e-6)).rounded())
        uScale = total > 0 ? repeats * cell / total : 1
        uStart = cell / 2

        var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
        for p in outline { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = gridCellSize(total: total, count: outline.count)
        let margin = size * 0.5
        lo -= SIMD2(repeating: margin); hi += SIMD2(repeating: margin)
        let dims = SIMD2(max(1, Int(((hi.x - lo.x) / size).rounded(.up))), max(1, Int(((hi.y - lo.y) / size).rounded(.up))))
        var buckets = [[Int32]](repeating: [], count: dims.x * dims.y)
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let smin = simd_min(a, b) - SIMD2(repeating: margin), smax = simd_max(a, b) + SIMD2(repeating: margin)
            let c0 = SIMD2(Int((smin.x - lo.x) / size), Int((smin.y - lo.y) / size))
            let c1 = SIMD2(Int((smax.x - lo.x) / size), Int((smax.y - lo.y) / size))
            for y in max(0, c0.y)...min(dims.y - 1, c1.y) {
                for x in max(0, c0.x)...min(dims.x - 1, c1.x) { buckets[y * dims.x + x].append(Int32(i)) }
            }
        }
        gridOrigin = lo; gridCell = size; gridSize = dims; self.buckets = buckets
    }

    /// Arc length along the outline of the point nearest to `p` (seen from above).
    func arcLength(at p: SIMD3<Double>) -> Double {
        let q = SIMD2(p.x, p.y)
        let cx = Int((q.x - gridOrigin.x) / gridCell), cy = Int((q.y - gridOrigin.y) / gridCell)
        var best = (d: Double.infinity, s: 0.0)
        func test(_ i: Int) {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 0 ? max(0, min(1, simd_dot(q - a, ab) / l2)) : 0
            let d = simd_distance_squared(q, a + t * ab)
            if d < best.d { best = (d, lengths[i] + t * (lengths[i + 1] - lengths[i])) }
        }
        if (0..<gridSize.x).contains(cx), (0..<gridSize.y).contains(cy), !buckets[cy * gridSize.x + cx].isEmpty {
            for i in buckets[cy * gridSize.x + cx] { test(Int(i)) }
        } else {
            for i in outline.indices { test(i) }
        }
        return best.s
    }
}

private func gridCellSize(total: Double, count: Int) -> Double {
    max(total / Double(max(count, 1)) * 2, 0.25)
}

extension WorkMesh {
    /// The shared mapping of every textured face that is part of a ring of straight walls (see
    /// ``WallBand``), by face. Only rings of two or more faces that meet smoothly (under
    /// ``TextureEngine/creaseAngle``) count: a single round face already wraps by itself, and the
    /// faces of a sharp-cornered box keep their own mappings (the texture fades at its corners).
    /// Patterns that space themselves on each face (``TexturePattern/fitsAround``) are left out.
    func wallBands(_ specs: [Int32: TextureEngine.FaceTexture]) -> [Int32: SurfaceMapping] {
        guard !triangles.isEmpty else { return [:] }
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let tol = 1e-4 * max(simd_length(hi - lo), 1)

        // Faces whose every triangle stands vertically, with their bottom and top heights.
        var range: [Int32: (lo: Double, hi: Double)] = [:]
        var slanted = Set<Int32>()
        for (t, f) in faces.enumerated() {
            guard let spec = specs[f], !spec.pattern.fitsAround, !slanted.contains(f) else { continue }
            let tri = triangles[t]
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let n = simd_cross(b - a, c - a)
            let l = simd_length(n)
            if l > 1e-12, abs(n.z) / l > 0.02 { slanted.insert(f); range[f] = nil; continue }
            let r = range[f] ?? (.infinity, -.infinity)
            range[f] = (min(r.lo, a.z, b.z, c.z), max(r.hi, a.z, b.z, c.z))
        }
        guard range.count >= 2 else { return [:] }

        // Each edge's faces, to find the bottom edges of the walls (where a wall meets a face
        // that isn't one).
        var edgeFaces: [UInt64: [Int32]] = [:]
        for (t, tri) in triangles.enumerated() {
            for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                edgeFaces[Self.key(a, b), default: []].append(faces[t])
            }
        }
        var next: [Int32: [Int32]] = [:]
        var edgeFace: [UInt64: Int32] = [:]
        for (t, tri) in triangles.enumerated() {
            let f = faces[t]
            guard let r = range[f] else { continue }
            for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                let k = Self.key(a, b)
                guard let fs = edgeFaces[k], fs.count == 2, fs.contains(where: { range[$0] == nil }) else { continue }
                guard abs(points[Int(a)].z - r.lo) < tol, abs(points[Int(b)].z - r.lo) < tol else { continue }
                next[a, default: []].append(b)
                next[b, default: []].append(a)
                edgeFace[k] = f
            }
        }
        guard next.values.allSatisfy({ $0.count == 2 }) else { return [:] }

        // Walk the bottom edges into closed loops.
        var visited = Set<Int32>()
        var loops: [[Int32]] = []
        for start in next.keys.sorted() where !visited.contains(start) {
            var loop = [start]
            visited.insert(start)
            var prev = start, cur = next[start]![0]
            while cur != start {
                guard !visited.contains(cur) else { return [:] }
                loop.append(cur)
                visited.insert(cur)
                let n = next[cur]!
                let step = n[0] == prev ? n[1] : n[0]
                prev = cur
                cur = step
            }
            loops.append(loop)
        }

        var out: [Int32: SurfaceMapping] = [:]
        var claimed = Set<Int32>()
        for loop in loops {
            var faceSet = Set<Int32>()
            for i in loop.indices {
                if let f = edgeFace[Self.key(loop[i], loop[(i + 1) % loop.count])] { faceSet.insert(f) }
            }
            guard faceSet.count >= 2, claimed.isDisjoint(with: faceSet) else { continue }
            claimed.formUnion(faceSet)
            // One height range and one pattern for the whole ring.
            let ranges = faceSet.compactMap { range[$0] }
            let first = ranges[0]
            guard ranges.allSatisfy({ abs($0.lo - first.lo) < tol && abs($0.hi - first.hi) < tol }) else { continue }
            let patterns = faceSet.compactMap { specs[$0]?.pattern }
            let p0 = patterns[0]
            guard patterns.allSatisfy({ type(of: $0) == type(of: p0) && $0.cell == p0.cell }) else { continue }
            var outline = loop.map { SIMD2(points[Int($0)].x, points[Int($0)].y) }
            // Smooth all the way around.
            let smooth = outline.indices.allSatisfy { i in
                let a = outline[(i + outline.count - 1) % outline.count], b = outline[i], c = outline[(i + 1) % outline.count]
                let u = b - a, v = c - b
                let lu = simd_length(u), lv = simd_length(v)
                guard lu > 1e-9, lv > 1e-9 else { return true }
                return acos(max(-1, min(1, simd_dot(u, v) / (lu * lv)))) < TextureEngine.creaseAngle
            }
            guard smooth else { continue }
            var area = 0.0
            for i in outline.indices {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                area += a.x * b.y - b.x * a.y
            }
            if area < 0 { outline.reverse() }
            // Start at the front (the lowest y; of a symmetric outline, on its axis), where a
            // repeat is centred: a heart's point gets a whole column of stitches.
            if let front = outline.indices.min(by: { (outline[$0].y, abs(outline[$0].x)) < (outline[$1].y, abs(outline[$1].x)) }) {
                outline = Array(outline[front...] + outline[..<front])
            }
            let band = WallBand(outline: outline, bottom: first.lo, height: first.hi - first.lo, cell: p0.cell.x)
            let mapping = SurfaceMapping(band: band)
            for f in faceSet { out[f] = mapping }
        }
        return out
    }
}
