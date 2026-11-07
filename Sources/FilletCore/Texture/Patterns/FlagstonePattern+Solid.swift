import Foundation
import simd

extension FlagstonePattern {
    /// Seed spacing as a fraction of the stone size: thinned at this spacing, seeds come out
    /// about one per `size × size` of surface.
    static let seedSpacing = 0.83

    /// The stones laid over the whole textured surface at once (see ``SolidFlagstones``), so they
    /// run on unbroken where a fillet meets a flat face or one wall the next.
    public func solid(over surface: TextureSurface) -> (any SolidTexture)? {
        let seeds = surface.scatter(spacing: Self.seedSpacing * size, jitter: 0.5 + 0.45 * irregularity, seed: seed)
        guard !seeds.isEmpty else { return nil }
        // The edge round widened for the mesh it will be sampled on (see ``softening``).
        var pattern = self
        let steps = surface.detailScale > 1 ? Self.softeningSteps.coarse : Self.softeningSteps.export
        pattern.softening = steps * rimDetail * max(surface.detailScale, 1)
        return SolidFlagstones(pattern: pattern, seeds: seeds, surface: surface)
    }
}

/// Flagstones over a surface in space: each stone is the part of the surface nearer to one seed
/// (``TextureSurface/scatter(spacing:jitter:seed:)``) than to any other, the restricted Voronoi
/// diagram of the seeds on the surface. The distance to a stone's outline is measured in the
/// surface's tangent plane, to the bisector with each neighbouring seed, so a stone's joints
/// stay as wide on a fillet as on a flat face. The profile across the joint and the stone tops
/// are those of ``FlagstonePattern/height(at:)``.
struct SolidFlagstones: SolidTexture {
    let pattern: FlagstonePattern
    let seeds: [TextureSurface.Seed]
    /// Per seed: the direction its top tilts along and how far it sinks (0…1).
    let tilts: [SIMD3<Double>]
    let sinks: [Double]
    /// Seeds that can matter to a point, by grid cell of size `cell` (a point in a cell not
    /// listed checks every seed).
    var index: [SIMD3<Int32>: [Int32]]
    let cell: Double
    /// Seeds farther than this from a point never matter to it.
    let reach: Double

    init(pattern: FlagstonePattern, seeds: [TextureSurface.Seed], surface: TextureSurface) {
        self.pattern = pattern
        self.seeds = seeds
        var tilts: [SIMD3<Double>] = [], sinks: [Double] = []
        for s in seeds {
            let helper: SIMD3<Double> = abs(s.normal.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let e1 = simd_normalize(helper - simd_dot(helper, s.normal) * s.normal)
            let e2 = simd_cross(s.normal, e1)
            let angle = 2 * .pi * Self.unit(s.id, 4)
            tilts.append(cos(angle) * e1 + sin(angle) * e2)
            sinks.append(Self.unit(s.id, 3))
        }
        self.tilts = tilts
        self.sinks = sinks
        let size = pattern.size
        // A point's own seed is within about a stone; a neighbour matters while its bisector is
        // within the joint, the edge round and the corner rounding of it.
        reach = 1.6 * size + 2 * (pattern.joint / 2 + pattern.edge + 0.15 * size)
        cell = 0.5 * size
        // Seeds by a coarse grid, then each cell the surface passes through gets those near it.
        var coarse: [SIMD3<Int32>: [Int32]] = [:]
        for (i, s) in seeds.enumerated() { coarse[SIMD3<Int32>(floor3(s.point / reach)), default: []].append(Int32(i)) }
        var index: [SIMD3<Int32>: [Int32]] = [:]
        let radius = reach + cell * 0.87
        for tri in surface.triangles {
            let a = surface.points[Int(tri.x)], b = surface.points[Int(tri.y)], c = surface.points[Int(tri.z)]
            let lo = simd_min(a, simd_min(b, c)) - 0.5 * cell, hi = simd_max(a, simd_max(b, c)) + 0.5 * cell
            let k0 = SIMD3<Int32>(floor3(lo / cell)), k1 = SIMD3<Int32>(floor3(hi / cell))
            for z in k0.z...k1.z {
                for y in k0.y...k1.y {
                    for x in k0.x...k1.x {
                        let k = SIMD3(x, y, z)
                        guard index[k] == nil else { continue }
                        let centre = (SIMD3<Double>(k) + 0.5) * cell
                        let g = SIMD3<Int32>(floor3(centre / reach))
                        var near: [Int32] = []
                        for dz in Int32(-1)...1 {
                            for dy in Int32(-1)...1 {
                                for dx in Int32(-1)...1 {
                                    for i in coarse[g &+ SIMD3(dx, dy, dz)] ?? []
                                    where simd_distance_squared(seeds[Int(i)].point, centre) < radius * radius {
                                        near.append(i)
                                    }
                                }
                            }
                        }
                        index[k] = near.sorted()
                    }
                }
            }
        }
        self.index = index
    }

    /// The stone at `p`: its seed and the distance from `p` to its outline in the tangent plane.
    func stone(at point: SIMD3<Double>, normal n: SIMD3<Double>) -> (seed: Int, edgeDistance: Double) {
        let size = pattern.size
        // Joints wander a little instead of running dead straight (along the surface only).
        var p = point
        if pattern.irregularity > 0 {
            var w = SIMD3(noise(point, steps: 2, salt: 7), noise(point, steps: 2, salt: 8), noise(point, steps: 2, salt: 9))
            w -= simd_dot(w, n) * n
            p += (0.035 * size * pattern.irregularity) * w
        }
        let key = SIMD3<Int32>(floor3(point / cell))
        guard let candidates = index[key] else {
            return Array(Int32(0)..<Int32(seeds.count)).withUnsafeBufferPointer { stone(at: p, normal: n, among: $0) }
        }
        return candidates.withUnsafeBufferPointer { stone(at: p, normal: n, among: $0) }
    }

    /// One side of a stone's outline near a point: the distance `d` to it and the direction `up`
    /// in which that grows (see ``stone(at:normal:among:)``).
    typealias Side = (d: Double, up: SIMD3<Double>)

    /// ``stone(at:normal:)`` at the wandered point `p`, among the seeds `candidates`. Its
    /// scratch lives on the stack: it runs several times for every point of the mesh.
    private func stone(at p: SIMD3<Double>, normal n: SIMD3<Double>,
                       among candidates: UnsafeBufferPointer<Int32>) -> (seed: Int, edgeDistance: Double) {
        guard !candidates.isEmpty else { return (0, .infinity) }
        let size = pattern.size
        // Distance squared to each seed, plus a penalty for seeds facing away (the far side of
        // a thin wall), growing smoothly from zero (so stones never end in a cut) once the
        // normals are more than ``TextureSurface/opposite`` apart. Not before: round a tight
        // convex curve (a heart's tip) the normal turns quickly, and a penalty growing with it
        // there squeezed the stones into strips along the curve.
        let penalty = 4 * size * size
        let opposite = TextureSurface.opposite
        let count = candidates.count
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: count) { dist in
            // Each seed unfolded into the tangent plane at `p` (see ``TextureSurface/unfold(_:from:to:)``):
            // the layout near `p` as a flat Voronoi diagram, measured along the surface.
            withUnsafeTemporaryAllocation(of: SIMD3<Double>.self, capacity: count) { flat in
                var owner = 0
                for k in 0..<count {
                    let s = seeds[Int(candidates[k])]
                    let away = max(0, opposite - simd_dot(s.normal, n)) / (1 + opposite)
                    flat[k] = TextureSurface.unfold(s.point - p, from: n, to: s.normal)
                    dist[k] = simd_length_squared(flat[k]) + penalty * away * away
                    if dist[k] < dist[owner] { owner = k }
                }
                let a = flat[owner]
                // Distance to each neighbour's bisector: |p - b|² - |p - a|² is twice the distance to the
                // bisector times |a - b|. With the direction in which it grows, so the outline is known
                // near `p` as a polygon in the tangent plane.
                return withUnsafeTemporaryAllocation(of: Side.self, capacity: count) { buffer in
                    var sides = 0
                    var nearest = Double.infinity
                    for k in 0..<count where k != owner {
                        let ab = flat[k] - a
                        let length = simd_length(ab)
                        guard length > 1e-9 else { continue }
                        let d = (dist[k] - dist[owner]) / (2 * length)
                        buffer[sides] = (d, -ab / length)
                        sides += 1
                        nearest = min(nearest, d)
                    }
                    guard nearest.isFinite else { return (Int(candidates[owner]), .infinity) }
                    let outline = UnsafeBufferPointer(rebasing: buffer[0..<sides])
                    return (Int(candidates[owner]), max(Self.rounded(outline, nearest: nearest, radius: cornerRadius), 0))
                }
            }
        }
    }

    /// Radius the stones' corners are rounded to (see ``rounded(_:nearest:radius:)``): past where
    /// the edge round reaches the top, so even a sharp corner rises to the stone's full height
    /// and its top's corner is still round (an eighth of a stone across).
    var cornerRadius: Double {
        let round = pattern.edgeRound
        return round.start + round.width + 0.12 * pattern.size
    }

    /// The distance into a stone whose corners are rounded to `radius` (its outline opened by a
    /// disc of that radius), from the distances `d` to its sides and the directions `up` in which
    /// they grow (``stone(at:normal:)``); `nearest` is the smallest `d`.
    ///
    /// Plainly the distance to the nearest side: where two sides met at a sharp angle (a stone's
    /// pointed corner, often where the stones are laid round a fillet) the stone between them was
    /// too narrow to rise out of its rounded edges, and stood as a long low wedge melting into the
    /// joint. Opened, a pointed corner ends in a round of `radius` (the joint fills the tip), so
    /// every corner rises to the full top within its round; blunt corners barely change. Inside
    /// the stone shrunk by `radius` it is the plain distance, outside `radius` less the distance
    /// to that shrunk stone (a convex polygon here).
    static func rounded(_ sides: [Side], nearest: Double, radius: Double) -> Double {
        sides.withUnsafeBufferPointer { rounded($0, nearest: nearest, radius: radius) }
    }

    /// The same, on sides in a buffer (as ``stone(at:normal:)`` keeps them, on the stack).
    static func rounded(_ sides: UnsafeBufferPointer<Side>, nearest: Double, radius: Double) -> Double {
        guard nearest < radius, radius > 0 else { return nearest }
        // The nearest point of the shrunk stone {x : d + up·x ≥ radius for every side}: the foot on
        // one side's line, or a corner where two lines meet, whichever is nearest and inside.
        func inside(_ x: SIMD3<Double>) -> Bool {
            for s in sides where s.d + simd_dot(s.up, x) < radius - 1e-9 { return false }
            return true
        }
        // Every foot and corner; the nearest inside is the one. Kept as the least length so far
        // (lengths are never NaN), rather than all collected and sorted: the same answer, as ties
        // share their length, without the sort that was half this function's time.
        var best = Double.infinity
        for i in sides.indices where sides[i].d < radius {
            let u = sides[i].up, uu = simd_length_squared(u)
            guard uu > 1e-12 else { continue }
            let x = (radius - sides[i].d) / uu * u
            let length = simd_length(x)
            if length < best, inside(x) { best = length }
            // A corner has at least one of its two sides with `p` outside.
            for j in sides.indices where j != i && (sides[j].d >= radius || j > i) {
                let v = sides[j].up
                let uv = simd_dot(u, v), vv = simd_dot(v, v)
                let det = uu * vv - uv * uv
                guard det > 1e-12 * uu * vv else { continue }
                let ri = radius - sides[i].d, rj = radius - sides[j].d
                let alpha = (ri * vv - rj * uv) / det, beta = (rj * uu - ri * uv) / det
                let x = alpha * u + beta * v
                let length = simd_length(x)
                if length < best, inside(x) { best = length }
            }
        }
        // A stone too small to hold the round anywhere keeps its plain outline.
        guard best.isFinite else { return nearest }
        return radius - best
    }

    func height(at p: SIMD3<Double>, normal n: SIMD3<Double>) -> Double {
        let s = stone(at: p, normal: n)
        return pattern.profile(edgeDistance: s.edgeDistance, top: top(s.seed, at: p))
    }

    func detail(at p: SIMD3<Double>, normal n: SIMD3<Double>) -> Double {
        pattern.detail(edgeDistance: stone(at: p, normal: n).edgeDistance)
    }

    /// The distance into the stone, across its rounded edge.
    func contour(at p: SIMD3<Double>, normal n: SIMD3<Double>) -> Double? {
        let e = stone(at: p, normal: n).edgeDistance
        return e.isFinite ? e : nil
    }

    /// Where the edge round leaves the joint floor and meets the top, where it bends most at the
    /// foot (halfway across it), where the foot turns into the shoulder, and in quarters across
    /// the shoulder, which bends most halfway across (``FlagstonePattern/shoulder(_:)``).
    var contourLevels: [Double] {
        let round = pattern.edgeRound
        let foot = FlagstonePattern.foot, rest = 1 - foot
        return [0, foot / 2, foot, foot + rest / 4, foot + rest / 2, foot + 3 * rest / 4, 1].map { round.start + $0 * round.width }
    }

    /// Height of a stone's top at `p` (as ``FlagstonePattern/stoneTop(_:at:)``).
    func top(_ seed: Int, at p: SIMD3<Double>) -> Double {
        let depth = pattern.depth, size = pattern.size
        var top = 0.0
        if pattern.relief > 0 {
            let along = simd_dot(p - seeds[seed].point, tilts[seed]) / (0.6 * size)
            let tilt = along / (1 + along * along).squareRoot()
            top -= pattern.relief * 0.5 * depth * (0.5 * sinks[seed] + 0.25 * (1 + tilt))
        }
        if pattern.roughness > 0 {
            let grain = FlagstonePattern.grain
            let n = 0.7 * noise(p, steps: grain.coarse, salt: 5) + 0.3 * noise(p, steps: grain.fine, salt: 6)
            top += pattern.roughness * 0.3 * depth * n
        }
        return top
    }

    /// Smooth value noise in -1…1 in space, `steps` lattice steps per stone size.
    func noise(_ p: SIMD3<Double>, steps: Int, salt: UInt64) -> Double {
        let q = p / pattern.size * Double(steps)
        let base = floor3(q)
        let f = q - base
        let w = f * f * f * (f * (f * 6 - 15) + 10)
        let k = SIMD3<Int32>(base)
        func at(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Double {
            TextureSurface.unitHash(k &+ SIMD3(dx, dy, dz), pattern.seed, 16 + salt) * 2 - 1
        }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let x00 = lerp(at(0, 0, 0), at(1, 0, 0), w.x), x10 = lerp(at(0, 1, 0), at(1, 1, 0), w.x)
        let x01 = lerp(at(0, 0, 1), at(1, 0, 1), w.x), x11 = lerp(at(0, 1, 1), at(1, 1, 1), w.x)
        return lerp(lerp(x00, x10, w.y), lerp(x01, x11, w.y), w.z)
    }

    /// A number in 0..<1 from a seed's id and a stream.
    static func unit(_ id: UInt64, _ salt: UInt64) -> Double {
        var x = id ^ (salt &* 0x9E37_79B9_7F4A_7C15)
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }
}
