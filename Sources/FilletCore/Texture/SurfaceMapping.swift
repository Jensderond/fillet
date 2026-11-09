import FilletKernel
import Foundation
import simd

/// What the kernel knows about a face's surface, for laying a texture on it.
public enum FaceSurface: Hashable, Sendable {
    /// A flat face; the plane's normal points out of the body.
    case plane(Plane)
    /// A face that turns around an axis (cylinder, cone, sphere, torus, revolved profile).
    case axis(FaceAxis)
    /// Any other face (a fillet's blend, a sweep, B-spline, offset, …), sampled on a grid of its
    /// own parameters (see ``ParametricChart``).
    case parametric(FaceGrid)
    /// A face the kernel can't sample: textured with a triplanar blend.
    case other

    public init(face index: Int, of shape: Shape) {
        if let plane = shape.facePlane(index) {
            self = .plane(plane)
        } else if let axis = shape.faceAxis(index) {
            self = .axis(axis)
        } else if let grid = ParametricChart.grid(face: index, of: shape) {
            self = .parametric(grid)
        } else {
            self = .other
        }
    }
}

/// Surface coordinates (u, v) in millimetres for the points of one face (see ``TexturePattern``
/// for the conventions), and the direction a point is displaced along.
struct SurfaceMapping: Sendable {
    private enum Kind: Sendable {
        case planar(origin: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>, normal: SIMD3<Double>)
        case revolved(Revolved)
        /// A ring of straight walls sharing one mapping (see ``WallBand``).
        case band(WallBand)
        /// A free-form face in its own parameters (see ``ParametricChart``).
        case parametric(ParametricChart)
        case triplanar
    }

    /// A face around an axis: u goes around, v up the profile.
    private struct Revolved: Sendable {
        var origin: SIMD3<Double>
        var axis: SIMD3<Double>
        var e1: SIMD3<Double>
        var e2: SIMD3<Double>
        /// Open faces: u = wrap(θ - θ0) · uScale; closed ones (all the way around): u = θ · uScale.
        var closed: Bool
        var theta0: Double
        var uScale: Double
        var v: Profile
    }

    /// How v follows the profile of a revolved face.
    private enum Profile: Sendable {
        /// v = z · scale (cylinder: 1, cone: 1 / cos α).
        case linear(scale: Double)
        /// v = R · asin(z / R).
        case sphere(radius: Double)
        /// v = (φ - φ0) · scale, φ the angle around the tube.
        case torus(major: Double, phi0: Double, scale: Double)
        /// v = arc length of the mean profile at height z (table over z).
        case table(z0: Double, dz: Double, s: [Double])
    }

    private let kind: Kind
    /// Subtracted so a face's coordinates start at its lowest point.
    private var offset = SIMD2<Double>.zero

    /// The mapping for a face with surface `surface` whose mesh points are `points`; closed faces
    /// fit a whole number of `cell` repeats around.
    init(surface: FaceSurface, cell: SIMD2<Double>, points: [SIMD3<Double>]) {
        switch surface {
        case .plane(let plane):
            let frame = FaceAnchor.world.frame(plane)
            kind = .planar(origin: SIMD3(frame.origin), x: SIMD3(frame.xDir), y: SIMD3(frame.yDir), normal: SIMD3(frame.normal))
        case .axis(let a):
            kind = Self.revolved(a, cell: cell, points: points).map { .revolved($0) } ?? .triplanar
        case .parametric(let grid):
            kind = .parametric(ParametricChart(grid: grid))
        case .other:
            kind = .triplanar
        }
        if case .triplanar = kind { return }
        // Each point's (u, v) across the cores (a free-form face finds each on its grid), then
        // the bounds in point order.
        let mapping = self
        let uvs = concurrentMap(points.count) { mapping.uv(points[$0]) }
        var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
        for q in uvs {
            lo = simd_min(lo, q)
            hi = simd_max(hi, q)
        }
        if lo.x.isFinite, lo.y.isFinite {
            extent = hi - lo
            // Around a closed face u wraps, so only v starts at the face's lowest point.
            if case .revolved(let r) = kind, r.closed {
                lo.x = 0
                extent?.x = 2 * .pi * r.uScale
            }
            if case .parametric(let chart) = kind, chart.wraps {
                lo.x = 0
                extent?.x = chart.extent.x
            }
            offset = lo
        }
    }

    /// The mapping shared by the faces of a ring of straight walls: u along its outline (a whole
    /// number of repeats around), v up from its bottom.
    init(band: WallBand) {
        kind = .band(band)
        extent = SIMD2(band.length * band.uScale, band.height)
    }

    /// Size of the face in (u, v), which run from 0 to it (nil for triplanar faces).
    private(set) var extent: SIMD2<Double>?

    /// True when u goes all the way around the face (repeating every `extent.x`).
    var wraps: Bool {
        if case .revolved(let r) = kind { return r.closed }
        if case .band = kind { return true }
        if case .parametric(let chart) = kind { return chart.wraps }
        return false
    }

    var isTriplanar: Bool {
        if case .triplanar = kind { return true }
        return false
    }

    /// The face as a pattern is laid out on it: its extent and its edges `border` (segments in
    /// space, see ``WorkMesh/faceBorders(where:)``) in (u, v).
    func face(border: [WorkMesh.FaceEdge]) -> TextureFace {
        guard !isTriplanar, let extent else { return TextureFace(extent: extent, wraps: wraps) }
        let period = wraps ? extent.x : nil
        var segments: [TextureFace.Segment] = []
        segments.reserveCapacity(border.count)
        for e in border {
            let a = uv(e.a)
            var b = uv(e.b)
            // An edge running across the seam of a closed face: the short way round.
            if let period { b.x = a.x + remainder(b.x - a.x, period) }
            segments.append(TextureFace.Segment(a, b, seam: e.seam))
        }
        return TextureFace(extent: extent, wraps: wraps, border: segments)
    }

    /// (u, v) of a point on the face (not for triplanar faces).
    func uv(_ p: SIMD3<Double>) -> SIMD2<Double> {
        switch kind {
        case .planar(let o, let x, let y, _):
            let w = p - o
            return SIMD2(simd_dot(w, x), simd_dot(w, y)) - offset
        case .revolved(let r):
            let w = p - r.origin
            let z = simd_dot(w, r.axis)
            let radial = w - z * r.axis
            var theta = atan2(simd_dot(radial, r.e2), simd_dot(radial, r.e1))
            if !r.closed { theta = Self.wrap(theta - r.theta0) }
            let v: Double
            switch r.v {
            case .linear(let scale): v = z * scale
            case .sphere(let radius): v = radius * asin(max(-1, min(1, z / radius)))
            case .torus(let major, let phi0, let scale):
                v = Self.wrap(atan2(z, simd_length(radial) - major) - phi0) * scale
            case .table(let z0, let dz, let s):
                let t = (z - z0) / dz
                let i = max(0, min(s.count - 2, Int(t.rounded(.down))))
                let f = max(0, min(1, t - Double(i)))
                v = s[i] + (s[i + 1] - s[i]) * f
            }
            return SIMD2(theta * r.uScale, v) - offset
        case .band(let b):
            return SIMD2(b.uStart + b.arcLength(at: p) * b.uScale, p.z - b.bottom)
        case .parametric(let chart):
            return chart.uv(p) - offset
        case .triplanar:
            return SIMD2(p.x, p.y)
        }
    }

    /// Height of `pattern` at `p` and the unit direction to displace along, given the mesh's
    /// vertex normal `n` there (outward).
    func sample(_ p: SIMD3<Double>, normal n: SIMD3<Double>, _ pattern: any TexturePattern) -> (height: Double, normal: SIMD3<Double>) {
        switch kind {
        case .planar(_, _, _, let normal):
            return (pattern.height(at: uv(p)), simd_dot(normal, n) < 0 ? -normal : normal)
        case .revolved(let r):
            // The mesh normal without its component around the axis: no faceting from the
            // polygonal tessellation around a cylinder.
            let w = p - r.origin
            let radial = w - simd_dot(w, r.axis) * r.axis
            var out = n
            if simd_length(radial) > 1e-9 {
                let t = simd_normalize(simd_cross(r.axis, radial))
                let m = n - simd_dot(n, t) * t
                if simd_length(m) > 0.3 { out = simd_normalize(m) }
            }
            return (pattern.height(at: uv(p)), out)
        case .parametric:
            return (pattern.height(at: uv(p)), n)
        case .band:
            // Straight up walls: the mesh normal, level.
            let level = SIMD3(n.x, n.y, 0)
            return (pattern.height(at: uv(p)), simd_length(level) > 0.3 ? simd_normalize(level) : n)
        case .triplanar:
            var w = simd_abs(n)
            w = w * w * w * w
            let total = w.x + w.y + w.z
            guard total > 1e-12 else { return (0, n) }
            let h = w.x * pattern.height(at: SIMD2(p.y, p.z)) + w.y * pattern.height(at: SIMD2(p.x, p.z))
                + w.z * pattern.height(at: SIMD2(p.x, p.y))
            return (h / total, n)
        }
    }

    // MARK: - Revolved faces

    private static func revolved(_ a: FaceAxis, cell: SIMD2<Double>, points: [SIMD3<Double>]) -> Revolved? {
        guard !points.isEmpty else { return nil }
        let origin = SIMD3(a.origin), axis = simd_normalize(SIMD3(a.direction))
        let helper: SIMD3<Double> = abs(axis.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let e1 = simd_normalize(helper - simd_dot(helper, axis) * axis)
        let e2 = simd_cross(axis, e1)
        var thetas: [Double] = [], zs: [Double] = [], rs: [Double] = []
        thetas.reserveCapacity(points.count)
        for p in points {
            let w = p - origin
            let z = simd_dot(w, axis)
            let radial = w - z * axis
            thetas.append(atan2(simd_dot(radial, e2), simd_dot(radial, e1)))
            zs.append(z)
            rs.append(simd_length(radial))
        }
        let meanR = rs.reduce(0, +) / Double(rs.count)
        guard meanR > 1e-6 else { return nil }
        // Around: a whole number of repeats on a closed face, plain arc length on an open one.
        var theta0 = 0.0, uScale = meanR, closed = false
        if let start = gapEnd(thetas) {
            theta0 = start
        } else {
            closed = true
            let n = max(1, (2 * .pi * meanR / max(cell.x, 1e-6)).rounded())
            uScale = n * cell.x / (2 * .pi)
        }
        let profile: Profile
        switch a.kind {
        case .cylinder: profile = .linear(scale: 1)
        case .cone: profile = .linear(scale: 1 / max(cos(a.semiAngle), 1e-3))
        case .sphere: profile = .sphere(radius: max(a.radius, 1e-6))
        case .torus:
            var phis: [Double] = []
            phis.reserveCapacity(points.count)
            for i in points.indices { phis.append(atan2(zs[i], rs[i] - a.radius)) }
            if let start = gapEnd(phis) {
                profile = .torus(major: a.radius, phi0: start, scale: a.minorRadius)
            } else {
                let m = max(1, (2 * .pi * a.minorRadius / max(cell.y, 1e-6)).rounded())
                profile = .torus(major: a.radius, phi0: 0, scale: m * cell.y / (2 * .pi))
            }
        case .revolution: profile = table(zs: zs, rs: rs)
        }
        return Revolved(origin: origin, axis: axis, e1: e1, e2: e2, closed: closed, theta0: theta0, uScale: uScale, v: profile)
    }

    /// Where the largest empty stretch of `angles` ends, when it is wide enough for the face to
    /// be open there; nil for a face that goes all the way around.
    private static func gapEnd(_ angles: [Double]) -> Double? {
        guard angles.count > 1 else { return nil }
        // A face that goes all the way around has an angle in each of 64 equal stretches of the
        // circle, so no gap (the one across ±π included) is wider than two of them, well under
        // the 0.35 that counts as open: no need to sort them all to find that out.
        let bins = 64
        var filled = [Bool](repeating: false, count: bins), inRange = true
        for a in angles {
            // atan2's range (and not NaN); anything else is left to the sort.
            guard a >= -.pi, a <= .pi else { inRange = false; break }
            filled[min(bins - 1, Int((a + .pi) / (2 * .pi) * Double(bins)))] = true
        }
        if inRange, !filled.contains(false) { return nil }
        let sorted = angles.sorted()
        var gap = sorted[0] + 2 * .pi - sorted[sorted.count - 1], end = sorted[0]
        for i in 1..<sorted.count where sorted[i] - sorted[i - 1] > gap {
            gap = sorted[i] - sorted[i - 1]
            end = sorted[i]
        }
        return gap > 0.35 ? end : nil
    }

    /// Arc length along the mean profile r(z) of a revolved face.
    private static func table(zs: [Double], rs: [Double]) -> Profile {
        let lo = zs.min() ?? 0, hi = zs.max() ?? 0
        guard hi - lo > 1e-6 else { return .linear(scale: 1) }
        let n = 128
        let dz = (hi - lo) / Double(n)
        var sum = [Double](repeating: 0, count: n + 1), count = [Double](repeating: 0, count: n + 1)
        for i in zs.indices {
            let b = max(0, min(n, Int(((zs[i] - lo) / dz).rounded())))
            sum[b] += rs[i]
            count[b] += 1
        }
        var r = [Double?](repeating: nil, count: n + 1)
        for b in 0...n where count[b] > 0 { r[b] = sum[b] / count[b] }
        // Fill empty bins from their neighbours.
        var last: Int?
        for b in 0...n {
            guard let value = r[b] else { continue }
            if let l = last, b - l > 1, let lv = r[l] {
                for k in (l + 1)..<b { r[k] = lv + (value - lv) * Double(k - l) / Double(b - l) }
            } else if last == nil {
                for k in 0..<b { r[k] = value }
            }
            last = b
        }
        if let l = last, let lv = r[l] { for k in l...n { r[k] = lv } }
        var s = [Double](repeating: 0, count: n + 1)
        for b in 1...n {
            let dr = (r[b] ?? 0) - (r[b - 1] ?? 0)
            s[b] = s[b - 1] + (dz * dz + dr * dr).squareRoot()
        }
        return .table(z0: lo, dz: dz, s: s)
    }

    private static func wrap(_ a: Double) -> Double {
        let t = a.truncatingRemainder(dividingBy: 2 * .pi)
        return t < 0 ? t + 2 * .pi : t
    }
}

extension SIMD3 where Scalar == Double {
    init(_ v: Vec3) { self.init(v.x, v.y, v.z) }
}
