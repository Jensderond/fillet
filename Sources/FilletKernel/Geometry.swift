import Foundation
import simd

/// A failure reported by the geometry kernel (bad input, OCCT algorithm failure, I/O).
public struct KernelError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Double-precision 3D vector/point in millimetres.
public struct Vec3: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x, y, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public init(_ v: SIMD3<Double>) { self.init(v.x, v.y, v.z) }
    public init(_ v: SIMD3<Float>) { self.init(Double(v.x), Double(v.y), Double(v.z)) }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    public var simd: SIMD3<Double> { SIMD3(x, y, z) }
    public var float: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 0 ? self / l : self }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vec3) -> Vec3 { Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
    public func distance(to o: Vec3) -> Double { (self - o).length }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }

    public var description: String { "(\(x), \(y), \(z))" }
}

/// Right-handed placement frame. Sketch coordinates (u, v) map to
/// `origin + u * xDir + v * yDir`.
public struct Plane: Hashable, Codable, Sendable {
    public var origin: Vec3
    public var normal: Vec3
    public var xDir: Vec3

    /// Normalises the axes and makes xDir orthogonal to normal.
    public init(origin: Vec3, normal: Vec3, xDir: Vec3) {
        let n = normal.normalized
        var x = (xDir - n * xDir.dot(n)).normalized
        if x.length < 0.5 { x = Plane.anyPerpendicular(to: n) }
        self.origin = origin
        self.normal = n
        self.xDir = x
    }

    public var yDir: Vec3 { normal.cross(xDir) }

    public static let xy = Plane(origin: .zero, normal: .unitZ, xDir: .unitX)
    /// Front plane: looking from -Y, u = X, v = Z.
    public static let xz = Plane(origin: .zero, normal: -Vec3.unitY, xDir: .unitX)
    /// Right plane: looking from +X, u = Y, v = Z.
    public static let yz = Plane(origin: .zero, normal: .unitX, xDir: .unitY)

    public func point(u: Double, v: Double) -> Vec3 { origin + xDir * u + yDir * v }
    public func point(_ p: SIMD2<Double>) -> Vec3 { point(u: p.x, v: p.y) }

    /// Orthogonal projection of a 3D point into plane coordinates.
    public func project(_ p: Vec3) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(d.dot(xDir), d.dot(yDir))
    }

    /// Signed distance of a point from the plane along the normal.
    public func signedDistance(_ p: Vec3) -> Double { (p - origin).dot(normal) }

    /// Intersection of a ray with the plane, or nil when parallel / behind the origin.
    public func intersect(rayOrigin o: Vec3, direction d: Vec3) -> Vec3? {
        let denom = d.dot(normal)
        guard abs(denom) > 1e-12 else { return nil }
        let t = (origin - o).dot(normal) / denom
        return t >= 0 ? o + d * t : nil
    }

    public func offset(by distance: Double) -> Plane {
        Plane(origin: origin + normal * distance, normal: normal, xDir: xDir)
    }

    public func flipped() -> Plane { Plane(origin: origin, normal: -normal, xDir: xDir) }

    /// Same plane with xDir flipped, if needed, to point along world +X
    /// (or +Y, then +Z, when the axis is perpendicular to those), so sketches
    /// on faces aren't shown mirrored or upside down.
    public func withReadableXAxis() -> Plane {
        let x = xDir
        let sign: Double
        if abs(x.x) > 1e-6 { sign = x.x } else if abs(x.y) > 1e-6 { sign = x.y } else { sign = x.z }
        return sign < 0 ? Plane(origin: origin, normal: normal, xDir: -x) : self
    }

    static func anyPerpendicular(to n: Vec3) -> Vec3 {
        let helper = abs(n.x) < 0.9 ? Vec3.unitX : Vec3.unitY
        return n.cross(helper).normalized
    }
}

/// Rigid/affine transform stored as a row-major 3×4 matrix [R | t].
public struct Transform: Hashable, Codable, Sendable {
    public var m: [Double]  // 12 values

    public init(matrix: [Double]) {
        precondition(matrix.count == 12)
        m = matrix
    }

    public static let identity = Transform(matrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])

    public static func translation(_ t: Vec3) -> Transform {
        Transform(matrix: [1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z])
    }

    /// Rotation by `angle` radians around the axis through `origin` (Rodrigues).
    public static func rotation(axis: Vec3, angle: Double, origin: Vec3 = .zero) -> Transform {
        let a = axis.normalized
        let c = cos(angle), s = sin(angle), t = 1 - c
        let r = [
            t * a.x * a.x + c, t * a.x * a.y - s * a.z, t * a.x * a.z + s * a.y,
            t * a.x * a.y + s * a.z, t * a.y * a.y + c, t * a.y * a.z - s * a.x,
            t * a.x * a.z - s * a.y, t * a.y * a.z + s * a.x, t * a.z * a.z + c,
        ]
        // p' = R (p - o) + o  =>  t = o - R o
        let ro = Vec3(
            r[0] * origin.x + r[1] * origin.y + r[2] * origin.z,
            r[3] * origin.x + r[4] * origin.y + r[5] * origin.z,
            r[6] * origin.x + r[7] * origin.y + r[8] * origin.z)
        let tr = origin - ro
        return Transform(matrix: [r[0], r[1], r[2], tr.x, r[3], r[4], r[5], tr.y, r[6], r[7], r[8], tr.z])
    }

    public func apply(_ p: Vec3) -> Vec3 {
        Vec3(
            m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
            m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
            m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
    }

    public func applyDirection(_ d: Vec3) -> Vec3 {
        Vec3(
            m[0] * d.x + m[1] * d.y + m[2] * d.z,
            m[4] * d.x + m[5] * d.y + m[6] * d.z,
            m[8] * d.x + m[9] * d.y + m[10] * d.z)
    }

    /// self ∘ other (apply `other` first, then `self`).
    public func concatenating(_ o: Transform) -> Transform {
        var r = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<4 {
                var v = 0.0
                for k in 0..<3 { v += m[i * 4 + k] * o.m[k * 4 + j] }
                if j == 3 { v += m[i * 4 + 3] }
                r[i * 4 + j] = v
            }
        }
        return Transform(matrix: r)
    }
}

/// One curve of a planar sketch profile, in plane coordinates (mm).
public enum Segment2D: Hashable, Codable, Sendable {
    case line(SIMD2<Double>, SIMD2<Double>)
    /// Arc through three points: start, any point on the arc, end.
    case arc(start: SIMD2<Double>, through: SIMD2<Double>, end: SIMD2<Double>)
    case circle(center: SIMD2<Double>, radius: Double)
    /// Interpolating B-spline through the points.
    case bspline([SIMD2<Double>])
}

public enum SurfaceType: Int32, Codable, Sendable {
    case plane = 0, cylinder, cone, sphere, torus, bspline, other
}

public enum CurveType: Int32, Codable, Sendable {
    case line = 0, circle, ellipse, bspline, other
}

public struct FaceInfo: Hashable, Codable, Sendable {
    public var surface: SurfaceType
    public var centroid: Vec3
    /// Outward normal near the centroid.
    public var normal: Vec3
    public var area: Double
    public var boundsMin: Vec3
    public var boundsMax: Vec3

    public init(surface: SurfaceType, centroid: Vec3, normal: Vec3, area: Double, boundsMin: Vec3, boundsMax: Vec3) {
        self.surface = surface; self.centroid = centroid; self.normal = normal
        self.area = area; self.boundsMin = boundsMin; self.boundsMax = boundsMax
    }
}

public struct EdgeInfo: Hashable, Codable, Sendable {
    public var curve: CurveType
    public var start: Vec3
    public var mid: Vec3
    public var end: Vec3
    public var tangentAtMid: Vec3
    public var length: Double
    /// Circle radius, 0 for other curves.
    public var radius: Double

    public init(curve: CurveType, start: Vec3, mid: Vec3, end: Vec3, tangentAtMid: Vec3, length: Double, radius: Double) {
        self.curve = curve; self.start = start; self.mid = mid; self.end = end
        self.tangentAtMid = tangentAtMid; self.length = length; self.radius = radius
    }
}

/// Display/export triangulation of a shape.
public struct Mesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Three indices per triangle.
    public var indices: [UInt32]
    /// Index of the B-rep face each triangle belongs to.
    public var triangleFaces: [Int32]
    /// One polyline per B-rep edge, indexed like `Shape.edgeInfo`.
    public var edges: [[SIMD3<Float>]]

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32], triangleFaces: [Int32], edges: [[SIMD3<Float>]]) {
        self.positions = positions; self.normals = normals; self.indices = indices
        self.triangleFaces = triangleFaces; self.edges = edges
    }

    public static let empty = Mesh(positions: [], normals: [], indices: [], triangleFaces: [], edges: [])

    public var triangleCount: Int { indices.count / 3 }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}
