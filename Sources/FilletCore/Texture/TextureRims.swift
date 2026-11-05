import Foundation
import simd

extension WorkMesh {
    /// Re-meshes the subdivided surface along the patterns' rims (``TexturePattern/rims(lo:hi:scale:)``):
    /// for each rim, the triangles between its outermost and innermost curve (and a small gap on
    /// either side) are replaced by strips that run along the curves, joined to the mesh around
    /// them. A sharp step whose height changes between two curves then has its edge exactly on
    /// them, as a smooth curve, instead of zig-zagging across triangles.
    ///
    /// Run after subdivision and before displacement: the new points lie on the undisplaced
    /// surface and get their heights like every other point. The gaps between the curves and the
    /// mesh are zipped by angle (or, where the mesh's boundary is too ragged for that, ear-clipped)
    /// and then flipped to the constrained Delaunay triangulation. A rim that would cross a face
    /// boundary or another rim, or that can't be joined without overlaps, is left as it was.
    /// Returns the surface mapping of each face it re-meshed: the displacement must use the same
    /// one (rebuilt from the changed mesh it could shift a little, and the curves with it).
    @discardableResult
    mutating func followRims(_ specs: [Int32: TextureEngine.FaceTexture], scale: Double) -> [Int32: SurfaceMapping] {
        var facePoints: [Int32: [SIMD3<Double>]] = [:]
        var faceTriangles: [Int32: [Int]] = [:]
        for (t, f) in faces.enumerated() where specs[f] != nil {
            // The same points the displacement builds its mapping from.
            facePoints[f, default: []].append(points[Int(triangles[t].x)])
            faceTriangles[f, default: []].append(t)
        }
        var removed = [Bool](repeating: false, count: triangles.count)
        var added: [(SIMD3<Int32>, Int32)] = []
        var vertexFaces: VertexFaces?
        // (u, v) of the current face's points (a point on a face edge gets each face's in turn).
        var uv = [SIMD2<Double>](repeating: .zero, count: points.count)
        var used: [Int32: SurfaceMapping] = [:]

        for f in specs.keys.sorted() {
            guard let spec = specs[f], let tris = faceTriangles[f] else { continue }
            let mapping = SurfaceMapping(surface: spec.surface, cell: TextureEngine.mappingCell(spec.pattern),
                                         points: facePoints[f] ?? [])
            guard !mapping.isTriplanar, let extent = mapping.extent else { continue }
            let pattern = spec.pattern.fitted(to: extent, wraps: mapping.wraps)
            var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
            for t in tris {
                for v in [triangles[t].x, triangles[t].y, triangles[t].z] {
                    let i = Int(v)
                    uv[i] = mapping.uv(points[i])
                    lo = simd_min(lo, uv[i])
                    hi = simd_max(hi, uv[i])
                }
            }
            let period = mapping.wraps ? extent.x : nil
            if period != nil { lo.x = 0; hi.x = extent.x }
            let rims = pattern.rims(lo: lo, hi: hi, scale: scale)
            guard !rims.isEmpty else { continue }
            if vertexFaces == nil { vertexFaces = self.vertexFaces() }
            for rim in rims {
                guard let patch = rimPatch(rim, face: f, triangles: tris, uv: uv, period: period,
                                           removed: removed, vertexFaces: vertexFaces!) else { continue }
                used[f] = mapping
                for t in patch.removed { removed[t] = true }
                let base = Int32(points.count)
                points += patch.points
                for tri in patch.triangles {
                    added.append((SIMD3(tri.x < 0 ? base + (-tri.x - 1) : tri.x,
                                        tri.y < 0 ? base + (-tri.y - 1) : tri.y,
                                        tri.z < 0 ? base + (-tri.z - 1) : tri.z), f))
                }
            }
        }
        guard !added.isEmpty else { return used }
        var newTriangles: [SIMD3<Int32>] = [], newFaces: [Int32] = []
        newTriangles.reserveCapacity(triangles.count + added.count)
        newFaces.reserveCapacity(triangles.count + added.count)
        for t in triangles.indices where !removed[t] {
            newTriangles.append(triangles[t])
            newFaces.append(faces[t])
        }
        for (tri, f) in added {
            newTriangles.append(tri)
            newFaces.append(f)
        }
        triangles = newTriangles
        faces = newFaces
        return used
    }

    /// One rim's replacement: triangles to drop, new points, and new triangles whose negative
    /// indices `-(k + 1)` refer to the k-th new point.
    private struct RimPatch {
        var removed: [Int]
        var points: [SIMD3<Double>]
        var triangles: [SIMD3<Int32>]
    }

    /// A closed curve around the centre with each point's angle, for "how far out is the curve
    /// at this angle".
    private struct Ring {
        var offsets: [SIMD2<Double>]
        var angles: [Double]

        init?(_ offsets: [SIMD2<Double>]) {
            guard offsets.count >= 8 else { return nil }
            self.offsets = offsets
            var angles: [Double] = []
            angles.reserveCapacity(offsets.count)
            var last = atan2(offsets[0].y, offsets[0].x)
            angles.append(last)
            for p in offsets.dropFirst() {
                var a = atan2(p.y, p.x)
                while a <= last - .pi { a += 2 * .pi }
                while a > last + .pi { a -= 2 * .pi }
                guard a > last else { return nil }
                angles.append(a)
                last = a
            }
            guard abs(last + Self.step(from: offsets.last!, to: offsets[0]) - angles[0] - 2 * .pi) < 1e-6 else { return nil }
            self.angles = angles
        }

        static func step(from p: SIMD2<Double>, to q: SIMD2<Double>) -> Double {
            var d = atan2(q.y, q.x) - atan2(p.y, p.x)
            while d <= -.pi { d += 2 * .pi }
            while d > .pi { d -= 2 * .pi }
            return d
        }

        /// Distance of the curve from the centre in the direction `angle`.
        func radius(at angle: Double) -> Double {
            let a0 = angles[0]
            var a = angle
            while a < a0 { a += 2 * .pi }
            while a >= a0 + 2 * .pi { a -= 2 * .pi }
            // First point with an angle above a.
            var l = 0, h = angles.count
            while l < h {
                let m = (l + h) / 2
                if angles[m] <= a { l = m + 1 } else { h = m }
            }
            let i = l - 1
            let p = offsets[i], q = offsets[(i + 1) % offsets.count]
            let ai = angles[i], aj = i + 1 < angles.count ? angles[i + 1] : a0 + 2 * .pi
            // Where the ray at `a` meets the segment p–q.
            let dir = SIMD2(cos(a), sin(a))
            let e = q - p
            let den = dir.x * e.y - dir.y * e.x
            if abs(den) > 1e-15 {
                let r = (p.x * e.y - p.y * e.x) / den
                if r.isFinite, r > 0 { return r }
            }
            let t = aj > ai ? (a - ai) / (aj - ai) : 0
            return simd_length(p) + (simd_length(q) - simd_length(p)) * t
        }

        var maxRadius: Double { offsets.map { simd_length($0) }.max() ?? 0 }
        var minRadius: Double { offsets.map { simd_length($0) }.min() ?? 0 }
    }

    private func rimPatch(_ rim: TextureRim, face f: Int32, triangles tris: [Int], uv: [SIMD2<Double>], period: Double?,
                          removed: [Bool], vertexFaces: VertexFaces) -> RimPatch? {
        guard rim.rings.count >= 2, let count = rim.rings.first?.count, count >= 8,
              rim.rings.allSatisfy({ $0.count == count }) else { return nil }
        var rings: [Ring] = []
        for r in rim.rings {
            guard let ring = Ring(r) else { return nil }
            rings.append(ring)
        }
        let outer = rings[0], inner = rings[rings.count - 1]
        // Spacing of the outer curve's points: the gap kept between the curves and the mesh.
        var outerLength = 0.0
        for i in 0..<count { outerLength += simd_distance(outer.offsets[i], outer.offsets[(i + 1) % count]) }
        let gap = 0.5 * outerLength / Double(count)
        let rOut = outer.maxRadius + gap, rIn = inner.minRadius - gap
        guard rIn > 0 else { return nil }
        let reach = rOut + 3

        func offset(_ v: Int32) -> SIMD2<Double> {
            var d = uv[Int(v)] - rim.center
            if let period { d.x = remainder(d.x, period) }
            return d
        }
        // 0: inside the inner curve (less the gap), 1: between, 2: outside the outer curve (plus the gap).
        var classes: [Int32: Int] = [:]
        func cls(_ v: Int32) -> Int {
            if let c = classes[v] { return c }
            let d = offset(v)
            let r = simd_length(d)
            var c = 1
            if r >= rOut {
                c = 2
            } else if r <= rIn {
                c = 0
            } else {
                let a = atan2(d.y, d.x)
                if r >= outer.radius(at: a) + gap { c = 2 } else if r <= inner.radius(at: a) - gap { c = 0 }
            }
            classes[v] = c
            return c
        }

        // Triangles to replace: everything not wholly inside or wholly outside.
        var cut = Set<Int>()
        var near: [Int32: [Int]] = [:]
        for t in tris {
            let tri = triangles[t]
            let d = offset(tri.x)
            guard abs(d.x) < reach, abs(d.y) < reach else { continue }
            for v in [tri.x, tri.y, tri.z] { near[v, default: []].append(t) }
            let a = cls(tri.x), b = cls(tri.y), c = cls(tri.z)
            if a == b && b == c && a != 1 { continue }
            guard !removed[t] else { return nil }
            cut.insert(t)
        }
        guard !cut.isEmpty else { return nil }
        // Points between the curves must belong to this face alone (not on a face edge).
        for t in cut {
            for v in [triangles[t].x, triangles[t].y, triangles[t].z] where cls(v) == 1 {
                guard vertexFaces.faces(of: Int(v)) == [f] else { return nil }
            }
        }
        func dkey(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b)) }
        // Winding of the mesh in (u, v): +1 when its triangles run counter-clockwise.
        var area = 0.0
        for t in cut {
            let tri = triangles[t]
            let p = offset(tri.x), q = offset(tri.y), r = offset(tri.z)
            area += cross2(q - p, r - p)
        }
        let winding: Double = area >= 0 ? 1 : -1

        /// The hole's boundary in the cut triangles' winding, split into the outer and inner loop,
        /// each counter-clockwise around the centre; or the points where it doubles back.
        func loops() -> Result<([Int32], [Int32]), RimTrouble> {
            var directed = Set<UInt64>()
            for t in cut {
                let tri = triangles[t]
                for k in 0..<3 { directed.insert(dkey(tri[k], tri[(k + 1) % 3])) }
            }
            var nextOuter: [Int32: Int32] = [:], nextInner: [Int32: Int32] = [:]
            var bad = Set<Int32>()
            for t in cut {
                let tri = triangles[t]
                for k in 0..<3 {
                    let a = tri[k], b = tri[(k + 1) % 3]
                    guard !directed.contains(dkey(b, a)) else { continue }
                    let ca = cls(a), cb = cls(b)
                    guard ca == cb, ca != 1 else { return .failure(.broken) }
                    if ca == 2 {
                        if nextOuter[a] != nil { bad.insert(a) }
                        nextOuter[a] = b
                    } else {
                        if nextInner[a] != nil { bad.insert(a) }
                        nextInner[a] = b
                    }
                }
            }
            guard bad.isEmpty else { return .failure(.grow(bad)) }
            func cycle(_ next: [Int32: Int32], sign: Double) -> Result<[Int32], RimTrouble> {
                // The cycles of the boundary: one goes once around the centre, the right way; any
                // other is a pocket or island of kept triangles, to be taken in.
                var left = next
                var main: [Int32]?
                var pockets = Set<Int32>()
                while let start = left.keys.min() {
                    var out: [Int32] = [start]
                    var v = left.removeValue(forKey: start)!
                    while v != start {
                        guard let n = left.removeValue(forKey: v) else { return .failure(.broken) }
                        out.append(v)
                        v = n
                    }
                    var total = 0.0
                    for i in out.indices {
                        total += Ring.step(from: offset(out[i]), to: offset(out[(i + 1) % out.count]))
                    }
                    if main == nil, abs(total - sign * 2 * .pi) < 1e-6 {
                        main = out
                    } else {
                        pockets.formUnion(out)
                    }
                }
                guard let main else { return .failure(.broken) }
                guard pockets.isEmpty else { return .failure(.grow(pockets)) }
                return .success(sign > 0 ? main : main.reversed())
            }
            let o = cycle(nextOuter, sign: winding), i = cycle(nextInner, sign: -winding)
            switch (o, i) {
            case (.success(let a), .success(let b)): return .success((a, b))
            case (.failure(.grow(let x)), .failure(.grow(let y))): return .failure(.grow(x.union(y)))
            case (.failure(.grow(let x)), .success), (.success, .failure(.grow(let x))): return .failure(.grow(x))
            case (.failure(let e), _), (_, .failure(let e)): return .failure(e)
            }
        }
        // New points: each curve point placed on the cut triangles (barycentric in (u, v)).
        let cell = max(4 * gap, 0.05)
        var grid: [SIMD2<Int32>: [Int]] = [:]
        for t in cut {
            let tri = triangles[t]
            let p = offset(tri.x), q = offset(tri.y), r = offset(tri.z)
            let mn = simd_min(p, simd_min(q, r)), mx = simd_max(p, simd_max(q, r))
            let i0 = Int32((mn.x / cell).rounded(.down)), i1 = Int32((mx.x / cell).rounded(.down))
            let j0 = Int32((mn.y / cell).rounded(.down)), j1 = Int32((mx.y / cell).rounded(.down))
            guard i1 - i0 < 64, j1 - j0 < 64 else { return nil }
            for i in i0...i1 { for j in j0...j1 { grid[SIMD2(i, j), default: []].append(t) } }
        }
        func place(_ o: SIMD2<Double>) -> SIMD3<Double>? {
            let key = SIMD2(Int32((o.x / cell).rounded(.down)), Int32((o.y / cell).rounded(.down)))
            var best: (Double, SIMD3<Double>)?
            for t in grid[key] ?? [] {
                let tri = triangles[t]
                let p = offset(tri.x), q = offset(tri.y), r = offset(tri.z)
                let den: Double = cross2(q - p, r - p)
                guard abs(den) > 1e-18 else { continue }
                let b1: Double = cross2(o - p, r - p) / den
                let b2: Double = cross2(q - p, o - p) / den
                let b0: Double = 1 - b1 - b2
                let worst = min(b0, min(b1, b2))
                if best == nil || worst > best!.0 {
                    let pa: SIMD3<Double> = points[Int(tri.x)] * b0
                    let pb: SIMD3<Double> = points[Int(tri.y)] * b1
                    let pc: SIMD3<Double> = points[Int(tri.z)] * b2
                    best = (worst, pa + pb + pc)
                }
                if worst >= 0 { break }
            }
            guard let best, best.0 > -1e-3 else { return nil }
            return best.1
        }
        var newPoints: [SIMD3<Double>] = []
        newPoints.reserveCapacity(rings.count * count)
        for ring in rings {
            for o in ring.offsets {
                guard let p = place(o) else { return nil }
                newPoints.append(p)
            }
        }
        func ringIndex(_ k: Int, _ i: Int) -> Int32 { -Int32(k * count + i % count) - 1 }

        // Triangles, built counter-clockwise in (u, v), checked, then turned to the mesh's winding.
        var out: [SIMD3<Int32>] = []
        var signedArea = 0.0
        func position(_ v: Int32) -> SIMD2<Double> {
            if v < 0 {
                let k = Int(-v - 1)
                return rings[k / count].offsets[k % count]
            }
            return offset(v)
        }
        func add(_ a: Int32, _ b: Int32, _ c: Int32) -> Bool {
            let p = position(a), q = position(b), r = position(c)
            let s = cross2(q - p, r - p)
            guard s > 1e-14 else { return false }
            signedArea += s / 2
            out.append(SIMD3(a, b, c))
            return true
        }
        /// Joins two counter-clockwise loops, `o` around `i`, by angle; nil when done, else the
        /// mesh points where it got stuck (a triangle would have turned over either way).
        func zipLoops(outer o: [Int32], inner i: [Int32]) -> Set<Int32>? {
            let m = o.count, n = i.count
            let a0 = atan2(position(o[0]).y, position(o[0]).x)
            var j0 = 0, bestD = Double.infinity
            for j in 0..<n {
                let d = abs(Ring.step(from: position(o[0]), to: position(i[j])))
                if d < bestD { bestD = d; j0 = j }
            }
            func unwrapped(_ list: [Int32], from start: Int, base: Double) -> [Double] {
                var out: [Double] = []
                var a = base + Ring.step(from: SIMD2(cos(base), sin(base)), to: position(list[start % list.count]))
                out.append(a)
                for k in 1...list.count {
                    a += Ring.step(from: position(list[(start + k - 1) % list.count]), to: position(list[(start + k) % list.count]))
                    // Where the mesh's boundary doubles back a little, hold the angle.
                    out.append(max(a, out[out.count - 1]))
                }
                return out
            }
            let ao = unwrapped(o, from: 0, base: a0), ai = unwrapped(i, from: j0, base: a0)
            var p = 0, q = 0
            while p < m || q < n {
                let op = o[p % m], iq = i[(j0 + q) % n]
                // Advance along the loop that is behind; if that triangle would turn over, the other.
                let outerFirst = q == n || (p < m && ao[p + 1] <= ai[q + 1])
                var done = false
                for advanceOuter in [outerFirst, !outerFirst] {
                    if advanceOuter {
                        guard p < m, add(op, o[(p + 1) % m], iq) else { continue }
                        p += 1
                    } else {
                        guard q < n, add(op, i[(j0 + q + 1) % n], iq) else { continue }
                        q += 1
                    }
                    done = true
                    break
                }
                if !done {
                    return Set([op, o[(p + 1) % m], o[(p + m - 1) % m], iq, i[(j0 + q + 1) % n], i[(j0 + q + n - 1) % n]].filter { $0 >= 0 })
                }
            }
            return nil
        }
        func polygonArea(_ pts: [SIMD2<Double>]) -> Double {
            var s = 0.0
            for k in pts.indices {
                let p = pts[k], q = pts[(k + 1) % pts.count]
                s += p.x * q.y - p.y * q.x
            }
            return s / 2
        }
        /// Fills the ring between two counter-clockwise loops, `o` around `i`: zipped by angle, or
        /// where the mesh's boundary is too ragged for that, ear-clipped and then flipped to the
        /// constrained Delaunay triangulation (local, well-shaped triangles).
        func fill(outer o: [Int32], inner i: [Int32]) -> Bool {
            var fixed = Set<UInt64>()
            for loop in [o, i] {
                for k in loop.indices { fixed.insert(WorkMesh.key(loop[k], loop[(k + 1) % loop.count])) }
            }
            let (kept, area) = (out.count, signedArea)
            if zipLoops(outer: o, inner: i) == nil {
                // The zip can leave slivers where the mesh's boundary is ragged: flip them away.
                var tris = Array(out[kept...])
                delaunayFlips(&tris, fixed: fixed, position: position)
                out.replaceSubrange(kept..., with: tris)
                return true
            }
            out.removeLast(out.count - kept)
            signedArea = area
            // Bridge the nearest pair into one polygon: o counter-clockwise, then i clockwise.
            var bestO = 0, bestI = 0, bestD = Double.infinity
            for a in o.indices {
                for b in i.indices {
                    let d = simd_distance_squared(position(o[a]), position(i[b]))
                    if d < bestD { bestD = d; bestO = a; bestI = b }
                }
            }
            var poly: [Int32] = []
            poly.reserveCapacity(o.count + i.count + 2)
            for k in 0...o.count { poly.append(o[(bestO + k) % o.count]) }
            for k in 0...i.count { poly.append(i[((bestI - k) % i.count + i.count) % i.count]) }
            guard let clipped = earClip(poly.map(position)) else { return false }
            var tris = clipped.map { SIMD3(poly[$0.0], poly[$0.1], poly[$0.2]) }
            delaunayFlips(&tris, fixed: fixed, position: position)
            for t in tris {
                guard add(t.x, t.y, t.z) else { return false }
            }
            return true
        }
        let ringLoops = (0..<rings.count).map { k in (0..<count).map { ringIndex(k, $0) } }
        // Strips between neighbouring curves.
        for k in 0..<(rings.count - 1) {
            for i in 0..<count {
                let a = ringIndex(k, i), b = ringIndex(k, i + 1), c = ringIndex(k + 1, i + 1), d = ringIndex(k + 1, i)
                // The shorter diagonal of the quad.
                if simd_distance_squared(position(a), position(c)) <= simd_distance_squared(position(b), position(d)) {
                    guard add(a, b, c), add(a, c, d) else { return nil }
                } else {
                    guard add(a, b, d), add(b, c, d) else { return nil }
                }
            }
        }
        let strips = (out, signedArea)

        // Join the outer and inner curve to the mesh around them. Where the hole's boundary pinches
        // or leaves pockets of kept triangles, take those in (they are wholly inside or outside, so
        // this only moves the boundary away from the curves) and look again.
        for _ in 0..<24 {
            switch loops() {
            case .failure(.broken):
                return nil
            case .failure(.grow(let trouble)):
                for v in trouble {
                    for t in near[v] ?? [] where !cut.contains(t) {
                        guard !removed[t] else { return nil }
                        cut.insert(t)
                    }
                }
            case .success(let (outerLoop, innerLoop)):
                (out, signedArea) = strips
                guard fill(outer: outerLoop, inner: ringLoops[0]), fill(outer: ringLoops[rings.count - 1], inner: innerLoop)
                else { return nil }
                // No overlaps: the triangles add up to exactly the area between the two loops.
                let expected = polygonArea(outerLoop.map(offset)) - polygonArea(innerLoop.map(offset))
                guard expected > 0, abs(signedArea - expected) <= 1e-7 * expected + 1e-9 else { return nil }
                if winding < 0 { out = out.map { SIMD3($0.x, $0.z, $0.y) } }
                return RimPatch(removed: Array(cut), points: newPoints, triangles: out)
            }
        }
        return nil
    }
}

/// Triangulates a simple counter-clockwise polygon (which may touch itself at repeated points,
/// as a bridged ring does) by clipping the best-shaped ear each time; nil if it gets stuck.
private func earClip(_ p: [SIMD2<Double>]) -> [(Int, Int, Int)]? {
    let n = p.count
    guard n >= 3 else { return nil }
    var prev = (0..<n).map { ($0 + n - 1) % n }, next = (0..<n).map { ($0 + 1) % n }
    var alive = [Bool](repeating: true, count: n)
    func quality(_ i: Int) -> Double {
        let a = p[prev[i]], b = p[i], c = p[next[i]]
        let s = cross2(b - a, c - a)
        guard s > 1e-14 else { return -1 }
        // No other point inside or on the triangle (points at a corner's position don't count).
        for k in 0..<n where alive[k] && k != i && k != prev[i] && k != next[i] {
            let q = p[k]
            if q == a || q == b || q == c { continue }
            if cross2(b - a, q - a) >= 0, cross2(c - b, q - b) >= 0, cross2(a - c, q - c) >= 0 { return -1 }
        }
        let l = simd_length_squared(b - a) + simd_length_squared(c - b) + simd_length_squared(a - c)
        return s / l
    }
    var q = (0..<n).map(quality)
    var out: [(Int, Int, Int)] = []
    out.reserveCapacity(n - 2)
    var left = n
    while left > 3 {
        var best = -1, bestQ = 0.0
        for i in 0..<n where alive[i] && q[i] > bestQ { best = i; bestQ = q[i] }
        guard best >= 0 else { return nil }
        let a = prev[best], c = next[best]
        out.append((a, best, c))
        alive[best] = false
        next[a] = c
        prev[c] = a
        left -= 1
        q[a] = quality(a)
        q[c] = quality(c)
    }
    guard let i = (0..<n).first(where: { alive[$0] }) else { return nil }
    out.append((prev[i], i, next[i]))
    return out
}

/// Lawson flips towards the constrained Delaunay triangulation of counter-clockwise triangles in
/// the plane: an edge not in `fixed` whose opposite angles add up to more than 180° is swapped
/// for the other diagonal when both new triangles stay counter-clockwise.
private func delaunayFlips(_ tris: inout [SIMD3<Int32>], fixed: Set<UInt64>, position: (Int32) -> SIMD2<Double>) {
    func angle(_ at: SIMD2<Double>, _ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
        let x = p - at, y = q - at
        return atan2(abs(cross2(x, y)), simd_dot(x, y))
    }
    for _ in 0..<64 {
        var owner: [UInt64: Int] = [:]
        var touched = [Bool](repeating: false, count: tris.count)
        var flips = 0
        for t in tris.indices {
            let tri = tris[t]
            for k in 0..<3 {
                let a = tri[k], b = tri[(k + 1) % 3]
                let key = WorkMesh.key(a, b)
                guard !fixed.contains(key) else { continue }
                guard let u = owner[key] else { owner[key] = t; continue }
                guard !touched[t], !touched[u] else { continue }
                let c = tri[(k + 2) % 3]
                let o = tris[u]
                var d: Int32 = -1
                for j in 0..<3 where o[j] == b && o[(j + 1) % 3] == a { d = o[(j + 2) % 3] }
                guard d >= 0, d != c else { continue }
                let pa = position(a), pb = position(b), pc = position(c), pd = position(d)
                guard angle(pc, pa, pb) + angle(pd, pb, pa) > .pi + 1e-9 else { continue }
                guard cross2(pa - pc, pd - pc) > 1e-14, cross2(pd - pc, pb - pc) > 1e-14 else { continue }
                tris[t] = SIMD3(c, a, d)
                tris[u] = SIMD3(c, d, b)
                touched[t] = true
                touched[u] = true
                flips += 1
            }
        }
        if flips == 0 { return }
    }
}

/// Why a rim's hole can't be joined yet: its boundary doubles back at these points (take in
/// the triangles around them), or it is broken beyond that.
private enum RimTrouble: Error {
    case grow(Set<Int32>)
    case broken
}

/// z of the cross product of two vectors in the plane.
private func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
