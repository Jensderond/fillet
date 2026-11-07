import Foundation
import simd

/// The surface one texture covers, as triangles in space (outward winding), for a pattern laid
/// out over the whole surface at once (see ``TexturePattern/solid(over:)``) instead of face by face.
public struct TextureSurface: Sendable {
    public var points: [SIMD3<Double>]
    public var triangles: [SIMD3<Int32>]
    /// How much longer than the pattern asks for (``SolidTexture/detail(at:normal:)``) the
    /// triangles come out: 1 for export, more for the viewport. A pattern can soften features the
    /// coarser mesh can't follow, so they render smooth rather than frayed.
    public var detailScale: Double

    public init(points: [SIMD3<Double>], triangles: [SIMD3<Int32>], detailScale: Double = 1) {
        self.points = points; self.triangles = triangles; self.detailScale = detailScale
    }

    /// Cosine of the angle between two normals beyond which they face opposite ways (the two
    /// sides of a thin wall) rather than round a corner: 120°. A tight convex curve (a heart's
    /// tip, a box's corner) turns less than that, so its seeds count as neighbours.
    public static let opposite = -0.5

    /// A point on the surface (see ``scatter(spacing:jitter:seed:)``).
    public struct Seed: Sendable {
        public var point: SIMD3<Double>
        /// Outward unit normal of the surface there.
        public var normal: SIMD3<Double>
        /// Stable for the same spot in space, whatever else changes: for per-seed randomness.
        public var id: UInt64
    }

    /// Lowest and highest corner of the surface's bounding box.
    public var bounds: (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    /// Points spread evenly over the surface, no two closer than `spacing` along it (unless they face
    /// opposite ways (``opposite``), like the two sides of a thin wall), and every spot of the
    /// surface within about `spacing` of one. They come from a lattice fixed in space (spacing / 2,
    /// each point moved by up to `jitter` / 2 of that, pseudo-randomly from `seed`), each lattice
    /// point dropped straight onto the nearest triangle below or above it
    /// (``projection(_:_:_:_:normal:)``), then thinned in a pseudo-random order (tight convex bends
    /// first, ``bendPriority(_:)``), measured along the surface. So the same spot
    /// gets the same seeds however finely the surface is tessellated, and editing the shape only
    /// moves the seeds near the change.
    public func scatter(spacing: Double, jitter: Double, seed: UInt64) -> [Seed] {
        guard spacing > 0, !triangles.isEmpty else { return [] }
        let c = spacing / 2
        let jitter = max(0, min(jitter, 0.95))
        // Each lattice point's nearest foot on the surface (nearer than `reach`).
        let reach = 1.6 * c
        typealias Foot = (d2: Double, point: SIMD3<Double>, normal: SIMD3<Double>, bend: Double)
        let bends = convexBends(ignoringEdgesUnder: 0.02 * spacing)
        func latticePoint(_ k: SIMD3<Int32>) -> SIMD3<Double> {
            let shift = SIMD3(Self.unitHash(k, seed, 1), Self.unitHash(k, seed, 2), Self.unitHash(k, seed, 3)) - 0.5
            return (SIMD3<Double>(k) + 0.5 + jitter * shift) * c
        }
        // Across the cores in fixed runs of triangles, each run keeping the first of its triangles
        // with the nearest foot, then the runs taken in order, an earlier one's foot kept unless a
        // later one's is strictly nearer: the same foot as going through the triangles one by one.
        let run = 256
        let runs = concurrentMap((triangles.count + run - 1) / run, chunk: 1) { r -> [SIMD3<Int32>: Foot] in
            var nearest: [SIMD3<Int32>: Foot] = [:]
            for t in (r * run)..<min(triangles.count, (r + 1) * run) {
                let tri = triangles[t]
                let a = points[Int(tri.x)], b = points[Int(tri.y)], d = points[Int(tri.z)]
                let cross = simd_cross(b - a, d - a)
                let area2 = simd_length(cross)
                guard area2 > 1e-14 else { continue }
                let normal = cross / area2
                let lo = simd_min(a, simd_min(b, d)) - reach, hi = simd_max(a, simd_max(b, d)) + reach
                let k0 = SIMD3<Int32>(floor3(lo / c) - 1), k1 = SIMD3<Int32>(floor3(hi / c) + 1)
                for z in k0.z...k1.z {
                    for y in k0.y...k1.y {
                        for x in k0.x...k1.x {
                            let k = SIMD3(x, y, z)
                            let l = latticePoint(k)
                            guard let q = Self.projection(l, a, b, d, normal: normal) else { continue }
                            let d2 = simd_distance_squared(l, q)
                            guard d2 < reach * reach else { continue }
                            if let old = nearest[k], old.d2 <= d2 { continue }
                            nearest[k] = (d2, q, normal, bends[t])
                        }
                    }
                }
            }
            return nearest
        }
        var nearest: [SIMD3<Int32>: Foot] = runs.first ?? [:]
        for part in runs.dropFirst() {
            for (k, foot) in part {
                if let old = nearest[k], old.d2 <= foot.d2 { continue }
                nearest[k] = foot
            }
        }
        // Thin them: in a fixed pseudo-random order, tight convex bends first (see
        // ``bendPriority``), keep a candidate when no kept one facing the same way is nearer than
        // `spacing` along the surface.
        func rank(_ k: SIMD3<Int32>) -> Double {
            Self.unitHash(k, seed, 4) - Self.bendPriority(nearest[k]!.bend * spacing)
        }
        let ranked = nearest.keys.map { (key: $0, rank: rank($0)) }
        let order = ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return (a.key.x, a.key.y, a.key.z) < (b.key.x, b.key.y, b.key.z)
        }.map(\.key)
        var kept: [Seed] = []
        var grid: [SIMD3<Int32>: [Int32]] = [:]
        let r2 = spacing * spacing
        for k in order {
            let cand = nearest[k]!
            let g = SIMD3<Int32>(floor3(cand.point / spacing))
            var free = true
            search: for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        for i in grid[g &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] {
                            let s = kept[Int(i)]
                            if simd_dot(s.normal, cand.normal) > Self.opposite,
                               simd_distance_squared(s.point, cand.point) < r2,
                               Self.surfaceDistanceSquared(cand.point - s.point, s.normal, cand.normal) < r2 {
                                free = false
                                break search
                            }
                        }
                    }
                }
            }
            guard free else { continue }
            grid[g, default: []].append(Int32(kept.count))
            kept.append(Seed(point: cand.point, normal: cand.normal, id: Self.hash(k, seed, 5)))
        }
        return kept
    }

    /// How strongly a seed candidate on a convex bend of curvature `bend` (1/mm, times the seed
    /// spacing) goes before the others when the candidates are thinned: 0 on flat faces and gentle
    /// curves, 1 (before every other) round a bend tighter than about half a stone across.
    ///
    /// Stones laid round a corner like a mason's quoins: a seed on the bend makes the stone there
    /// wrap round it, with joints crossing the bend. Left to chance, a joint often ran along a tight
    /// rounded corner (a heart's tip, a box's rounded edge) and the corner read as a straight seam
    /// between two columns of stones.
    static func bendPriority(_ bend: Double) -> Double {
        let t = min(max((bend - 1.2) / 0.8, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Per triangle: how tightly the surface bends convexly across it (1/mm), from the normals at
    /// its corners (area-weighted over the triangles round each point). Edges shorter than
    /// `ignoringEdgesUnder` are left out (a kernel blend's slivers).
    func convexBends(ignoringEdgesUnder shortest: Double) -> [Double] {
        var normals = [SIMD3<Double>](repeating: .zero, count: points.count)
        for tri in triangles {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let n = simd_cross(b - a, c - a)
            normals[Int(tri.x)] += n; normals[Int(tri.y)] += n; normals[Int(tri.z)] += n
        }
        for i in normals.indices {
            let l = simd_length(normals[i])
            normals[i] = l > 0 ? normals[i] / l : .zero
        }
        return triangles.map { tri in
            var bend = 0.0
            for (i, j) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                let d = points[Int(j)] - points[Int(i)]
                let l2 = simd_length_squared(d)
                guard l2 > shortest * shortest else { continue }
                bend = max(bend, simd_dot(normals[Int(j)] - normals[Int(i)], d) / l2)
            }
            return bend
        }
    }

    /// The way along the surface between two points `c` apart with normals `n` and `m`, squared
    /// (as far as ``unfold(_:from:to:)`` puts one from the other).
    static func surfaceDistanceSquared(_ c: SIMD3<Double>, _ n: SIMD3<Double>, _ m: SIMD3<Double>) -> Double {
        let turn = simd_cross(n, m)
        let sine = simd_length(turn)
        guard sine > 1e-6 else { return simd_length_squared(c) }
        let axis = turn / sine
        let along = simd_dot(c, axis)
        let half = atan2(sine, simd_dot(n, m)) / 2
        let stretch = half / sin(half)
        return along * along + (simd_length_squared(c) - along * along) * stretch * stretch
    }

    /// The foot of the perpendicular from `p` to the plane of triangle (`a`, `b`, `c`) (unit
    /// `normal`), when it falls inside the triangle; nil otherwise.
    ///
    /// Not the triangle's nearest point: that clamps every point beyond an edge onto the edge, so
    /// outside a convex fold of the tessellation (along a fillet's facets, round a tight curve,
    /// past the surface's own border) a whole wedge of space lands on one line, and the seeds
    /// thinned from those spots line up along it, cutting the stones into straight columns and
    /// slivers there.
    static func projection(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                           normal n: SIMD3<Double>) -> SIMD3<Double>? {
        let q = p - simd_dot(p - a, n) * n
        // Barycentric coordinates of q: each sub-triangle's area against the whole, signed.
        let whole = simd_dot(simd_cross(b - a, c - a), n)
        guard whole > 0 else { return nil }
        let u = simd_dot(simd_cross(c - b, q - b), n) / whole
        let v = simd_dot(simd_cross(a - c, q - c), n) / whole
        let w = 1 - u - v
        return u >= 0 && v >= 0 && w >= 0 ? q : nil
    }

    /// Where a point `c` away from a surface point (normal `n`) lands when the surface between
    /// them, whose normal at the far end is `m`, is unrolled into the tangent plane at the near end:
    /// the chord's part along the axis the normal turns about stays as it is, the part across it
    /// lengthens from the chord to the arc of a circle turning the normal by the same angle. So it
    /// lies in the tangent plane, as far away as the way along the surface: exactly round a
    /// cylinder (a rounded vertical corner), closely round any smooth bend.
    ///
    /// Not the chord projected into the tangent plane: round a tight bend that came out much
    /// shorter than the way along the surface, and differently on each side of a joint, so a
    /// stone's edge round was squeezed into a crease on one side of a joint crossing the bend and
    /// stretched on the other, and narrow stones along the bend stood as ridges.
    static func unfold(_ c: SIMD3<Double>, from n: SIMD3<Double>, to m: SIMD3<Double>) -> SIMD3<Double> {
        let flat = c - simd_dot(c, n) * n
        let turn = simd_cross(n, m)
        let sine = simd_length(turn), cosine = simd_dot(n, m)
        // (Nearly) parallel or opposite: the tangent plane's own projection.
        guard sine > 1e-6, simd_length_squared(flat) > 1e-18 else { return flat }
        let axis = turn / sine
        let along = simd_dot(c, axis)
        let across = c - along * axis
        let half = atan2(sine, cosine) / 2
        let arc = simd_length(across) * half / sin(half)
        let towards = across - simd_dot(across, n) * n
        let t = simd_length(towards)
        guard t > 1e-12 else { return flat }
        return along * axis + (arc / t) * towards
    }

    static func hash(_ k: SIMD3<Int32>, _ seed: UInt64, _ salt: UInt64) -> UInt64 {
        var x = UInt64(UInt32(bitPattern: k.x)) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(UInt32(bitPattern: k.y)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= UInt64(UInt32(bitPattern: k.z)) &* 0x1656_67B1_9E37_79F9
        x ^= (seed &+ 1) &* 0xD6E8_FEB8_6659_FD93
        x ^= salt &* 0xA076_1D64_78BD_642F
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return x
    }

    static func unitHash(_ k: SIMD3<Int32>, _ seed: UInt64, _ salt: UInt64) -> Double {
        Double(hash(k, seed, salt) >> 11) / Double(UInt64(1) << 53)
    }
}

/// A pattern laid out over a whole ``TextureSurface`` in space (see ``TexturePattern/solid(over:)``):
/// one layout across every face the texture covers, so nothing changes where one face meets the
/// next.
public protocol SolidTexture: Sendable {
    /// Height at point `p` of the surface, mm along the outward normal; `normal` is the surface's
    /// outward unit normal there (zero when unknown).
    func height(at p: SIMD3<Double>, normal: SIMD3<Double>) -> Double
    /// Edge length wanted around `p`, mm (as ``TexturePattern/detail(at:)``).
    func detail(at p: SIMD3<Double>, normal: SIMD3<Double>) -> Double
    /// A smooth measure along the surface (mm per mm) whose level lines ``contourLevels`` the
    /// relief bends along, such as the distance into a stone across its rounded edge; nil where
    /// there is none. The mesh lines its points up along those lines (see
    /// ``WorkMesh/snapToContours(_:where:)``), so a bend comes out as a smooth row of triangles
    /// rather than a zigzag of them that shades as a frayed edge.
    func contour(at p: SIMD3<Double>, normal: SIMD3<Double>) -> Double?
    /// The values of ``contour(at:normal:)`` the points are lined up on.
    var contourLevels: [Double] { get }
}

extension SolidTexture {
    public func contour(at p: SIMD3<Double>, normal: SIMD3<Double>) -> Double? { nil }
    public var contourLevels: [Double] { [] }
}


/// Each component rounded down.
@inline(__always) func floor3(_ v: SIMD3<Double>) -> SIMD3<Double> { v.rounded(.down) }
