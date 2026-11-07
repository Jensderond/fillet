import FilletKernel
import Foundation
import simd

/// Surface coordinates for a free-form face (a fillet's blend, a sweep along a curved outline,
/// any B-spline face) from the face's own parameters, so a pattern lies on it as on a cylinder
/// instead of being projected onto it from outside.
///
/// The face is sampled on a grid of its parameters (``FaceGrid``). A point's parameters come from
/// the nearest spot on that grid (as triangles), and become millimetres through the arc length
/// along its own grid line, centred on the face: u along a fillet's edge, v across its round. So
/// features keep their size where the grid lines shorten (the inside of a curved fillet, a corner
/// blend pinching to a point) and the face's outline in (u, v) narrows there instead; around a
/// closed face u is the length averaged across the face, so the pattern repeats.
/// As on the other faces, v is the direction that runs more up the part (and goes up), u goes
/// around when the face does, and (u, v) run right and up seen from outside, so patterns are
/// never mirrored.
struct ParametricChart: Sendable {
    let grid: FaceGrid
    /// u is the face's v parameter (and the other way round).
    let swap: Bool
    let flipU: Bool
    let flipV: Bool
    /// Arc length at each grid line along the face's own u and v parameters averaged across the
    /// face, mm.
    let lengthU: [Double]
    let lengthV: [Double]
    /// Arc length along each grid line itself, less half its total (so each line is centred),
    /// plus half the longest line's: `alongU[j * nu + i]` along u at row j, `alongV[j * nu + i]`
    /// along v at column i. Empty in a direction the face goes all the way around.
    private let alongU: [Double]
    private let alongV: [Double]
    private let longestU: Double
    private let longestV: Double
    /// The face goes all the way around along the chart's u.
    let wraps: Bool

    private let points: [SIMD3<Double>]
    private let origin: SIMD3<Double>
    private let cellSize: Double
    private let buckets: [SIMD3<Int32>: [Int32]]

    /// Grid points per mm wanted along each direction, and the bounds on the grid size.
    static let spacing = 0.5
    static let gridLimit = 2...256

    init(grid: FaceGrid) {
        self.grid = grid
        let nu = grid.nu, nv = grid.nv
        let points = grid.points.map { SIMD3<Double>($0.x, $0.y, $0.z) }
        self.points = points
        func p(_ i: Int, _ j: Int) -> SIMD3<Double> { points[j * nu + i] }

        // Arc length along each parameter, averaged over the grid lines across.
        var lu = [Double](repeating: 0, count: nu), lv = [Double](repeating: 0, count: nv)
        var climbU = 0.0, climbV = 0.0, riseU = 0.0, riseV = 0.0, runU = 0.0, runV = 0.0
        for i in 1..<nu {
            var sum = 0.0
            for j in 0..<nv {
                let d = p(i, j) - p(i - 1, j)
                sum += simd_length(d)
                climbU += abs(d.z); riseU += d.z; runU += d.y
            }
            lu[i] = lu[i - 1] + sum / Double(nv)
        }
        for j in 1..<nv {
            var sum = 0.0
            for i in 0..<nu {
                let d = p(i, j) - p(i, j - 1)
                sum += simd_length(d)
                climbV += abs(d.z); riseV += d.z; runV += d.y
            }
            lv[j] = lv[j - 1] + sum / Double(nu)
        }
        lengthU = lu
        lengthV = lv
        var au = [Double](), av = [Double]()
        var longU = lu[nu - 1], longV = lv[nv - 1]
        if !grid.uClosed {
            au = [Double](repeating: 0, count: nu * nv)
            longU = 0
            for j in 0..<nv {
                for i in 1..<nu { au[j * nu + i] = au[j * nu + i - 1] + simd_distance(p(i, j), p(i - 1, j)) }
                longU = max(longU, au[j * nu + nu - 1])
            }
            for j in 0..<nv {
                let shift = (longU - au[j * nu + nu - 1]) / 2
                for i in 0..<nu { au[j * nu + i] += shift }
            }
        }
        if !grid.vClosed {
            av = [Double](repeating: 0, count: nu * nv)
            longV = 0
            for i in 0..<nu {
                for j in 1..<nv { av[j * nu + i] = av[(j - 1) * nu + i] + simd_distance(p(i, j), p(i, j - 1)) }
                longV = max(longV, av[(nv - 1) * nu + i])
            }
            for i in 0..<nu {
                let shift = (longV - av[(nv - 1) * nu + i]) / 2
                for j in 0..<nv { av[j * nu + i] += shift }
            }
        }
        alongU = au; alongV = av
        longestU = longU; longestV = longV

        // u goes around a closed face; otherwise v is the parameter that climbs more.
        let swap: Bool
        if grid.uClosed != grid.vClosed {
            swap = grid.vClosed
        } else {
            let steepU = climbU / max(lu[nu - 1] * Double(nv), 1e-12)
            let steepV = climbV / max(lv[nv - 1] * Double(nu), 1e-12)
            swap = steepU > steepV + 1e-6
        }
        self.swap = swap
        wraps = swap ? grid.vClosed : grid.uClosed
        // v goes up (on a level face: towards +y, like a flat face's v).
        let rise = swap ? riseU : riseV, run = swap ? runU : runV
        let scale = max(swap ? lu[nu - 1] : lv[nv - 1], 1e-9) * Double(swap ? nv : nu)
        let flipV = abs(rise) > 1e-3 * scale ? rise < 0 : run < 0
        self.flipV = flipV
        // dS/du × dS/dv points out of an unreversed face; each swap or flip turns the chart over.
        var turns = (grid.reversed ? 1 : 0) + (swap ? 1 : 0) + (flipV ? 1 : 0)
        turns &= 1
        flipU = turns == 1

        // Grid cells into buckets (each cell's box, grown by a margin for points off the surface).
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for q in points { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        var longest = 0.0
        for j in 0..<(nv - 1) {
            for i in 0..<(nu - 1) {
                longest = max(longest, simd_distance(p(i, j), p(i + 1, j + 1)), simd_distance(p(i + 1, j), p(i, j + 1)))
            }
        }
        let size = max(longest, 1e-3 * max(simd_length(hi - lo), 1e-3), 1e-4)
        let margin = size / 2
        origin = lo - SIMD3(repeating: margin)
        cellSize = size
        var buckets: [SIMD3<Int32>: [Int32]] = [:]
        for j in 0..<(nv - 1) {
            for i in 0..<(nu - 1) {
                var a = p(i, j), b = a
                for q in [p(i + 1, j), p(i, j + 1), p(i + 1, j + 1)] { a = simd_min(a, q); b = simd_max(b, q) }
                let c0 = Self.cell(a - SIMD3(repeating: margin), origin: origin, size: size)
                let c1 = Self.cell(b + SIMD3(repeating: margin), origin: origin, size: size)
                for z in c0.z...c1.z {
                    for y in c0.y...c1.y {
                        for x in c0.x...c1.x { buckets[SIMD3(x, y, z), default: []].append(Int32(j * nu + i)) }
                    }
                }
            }
        }
        self.buckets = buckets
    }

    /// The grid for face `index` of `shape`, fine enough to follow its curvature; nil when the
    /// kernel can't sample it.
    static func grid(face index: Int, of shape: Shape) -> FaceGrid? {
        guard let coarse = shape.faceGrid(index, nu: 9, nv: 9) else { return nil }
        var lu = 0.0, lv = 0.0
        for j in 0..<9 { for i in 1..<9 { lu += (coarse.point(i, j) - coarse.point(i - 1, j)).length } }
        for i in 0..<9 { for j in 1..<9 { lv += (coarse.point(i, j) - coarse.point(i, j - 1)).length } }
        lu /= 9; lv /= 9
        guard lu > 1e-6 || lv > 1e-6 else { return nil }
        func count(_ length: Double) -> Int {
            min(max(Int((length / spacing).rounded(.up)) + 1, 9), gridLimit.upperBound)
        }
        return shape.faceGrid(index, nu: count(lu), nv: count(lv))
    }

    /// Size of the face in (u, v), mm.
    var extent: SIMD2<Double> {
        return swap ? SIMD2(longestV, longestU) : SIMD2(longestU, longestV)
    }

    /// (u, v) of a point on (or near) the face, mm from the face's corner.
    func uv(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let (fi, fj) = parameters(p)
        var a = alongU.isEmpty ? Self.interpolate(lengthU, fi) : interpolate(alongU, fi, fj)
        var b = alongV.isEmpty ? Self.interpolate(lengthV, fj) : interpolate(alongV, fi, fj)
        if swap { (a, b) = (b, a) }
        let e = extent
        if flipU { a = e.x - a }
        if flipV { b = e.y - b }
        return SIMD2(a, b)
    }

    /// Fractional grid indices (i, j) of the point on the sampled surface nearest `p`.
    private func parameters(_ p: SIMD3<Double>) -> (Double, Double) {
        let nu = grid.nu
        var best = Double.infinity, bi = 0.0, bj = 0.0
        func test(_ cell: Int) {
            let i = cell % nu, j = cell / nu
            let a = points[cell], b = points[cell + 1], c = points[cell + nu], d = points[cell + nu + 1]
            // Two triangles: (a, b, d) and (a, d, c), with their corners' grid offsets.
            for (q0, q1, q2, o1, o2) in [(a, b, d, SIMD2(1.0, 0), SIMD2(1.0, 1)), (a, d, c, SIMD2(1.0, 1), SIMD2(0.0, 1))] {
                let (s, t, d2) = Self.closest(p, q0, q1, q2)
                if d2 < best {
                    best = d2
                    let o = o1 * s + o2 * t
                    bi = Double(i) + o.x
                    bj = Double(j) + o.y
                }
            }
        }
        // The point's own bucket holds every cell within the margin; a point further off the
        // surface (a chord of a coarse tessellation) looks in rings of buckets around it.
        let key = Self.cell(p, origin: origin, size: cellSize)
        for ring in Int32(0)...8 where !best.isFinite {
            for z in (key.z - ring)...(key.z + ring) {
                for y in (key.y - ring)...(key.y + ring) {
                    for x in (key.x - ring)...(key.x + ring)
                    where max(abs(x - key.x), abs(y - key.y), abs(z - key.z)) == ring {
                        if let cells = buckets[SIMD3(x, y, z)] { for c in cells { test(Int(c)) } }
                    }
                }
            }
        }
        if !best.isFinite {
            // Far off the face (should not happen for its own mesh): the nearest grid point.
            var d2 = Double.infinity
            for (k, q) in points.enumerated() where simd_distance_squared(p, q) < d2 {
                d2 = simd_distance_squared(p, q)
                bi = Double(k % nu); bj = Double(k / nu)
            }
        }
        return (bi, bj)
    }

    private static func cell(_ p: SIMD3<Double>, origin: SIMD3<Double>, size: Double) -> SIMD3<Int32> {
        let q = ((p - origin) / size).rounded(.down)
        return SIMD3(Int32(clamping: Int(max(min(q.x, 1e6), -1e6))), Int32(clamping: Int(max(min(q.y, 1e6), -1e6))),
                     Int32(clamping: Int(max(min(q.z, 1e6), -1e6))))
    }

    /// Bilinear in a table over the grid.
    private func interpolate(_ table: [Double], _ x: Double, _ y: Double) -> Double {
        let nu = grid.nu
        let i = max(0, min(nu - 2, Int(x.rounded(.down)))), j = max(0, min(grid.nv - 2, Int(y.rounded(.down))))
        let fx = max(0, min(1, x - Double(i))), fy = max(0, min(1, y - Double(j)))
        let a = table[j * nu + i] + (table[j * nu + i + 1] - table[j * nu + i]) * fx
        let b = table[(j + 1) * nu + i] + (table[(j + 1) * nu + i + 1] - table[(j + 1) * nu + i]) * fx
        return a + (b - a) * fy
    }

    private static func interpolate(_ table: [Double], _ x: Double) -> Double {
        let i = max(0, min(table.count - 2, Int(x.rounded(.down))))
        let f = max(0, min(1, x - Double(i)))
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// The point of triangle (a, b, c) nearest `p` as a + s (b - a) + t (c - a), and its squared
    /// distance (Ericson, Real-Time Collision Detection 5.1.5). Degenerate triangles fall back to
    /// their nearest corner.
    static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>)
        -> (s: Double, t: Double, d2: Double)
    {
        func result(_ s: Double, _ t: Double) -> (Double, Double, Double) {
            let q = a + s * (b - a) + t * (c - a)
            return (s, t, simd_distance_squared(p, q))
        }
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return result(0, 0) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return result(1, 0) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let den = d1 - d3
            return den > 1e-300 ? result(d1 / den, 0) : result(0, 0)
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return result(0, 1) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let den = d2 - d6
            return den > 1e-300 ? result(0, d2 / den) : result(0, 0)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let den = (d4 - d3) + (d5 - d6)
            let w = den > 1e-300 ? (d4 - d3) / den : 0
            return result(1 - w, w)
        }
        let den = va + vb + vc
        guard abs(den) > 1e-300 else {
            // Degenerate: the nearest corner.
            let ra = result(0, 0), rb = result(1, 0), rc = result(0, 1)
            return [ra, rb, rc].min { $0.2 < $1.2 }!
        }
        return result(vb / den, vc / den)
    }
}
