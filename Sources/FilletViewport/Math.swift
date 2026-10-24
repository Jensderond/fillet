import Foundation
import simd
import FilletKernel

/// A half-line in world space (millimetres). `direction` is unit length.
public struct Ray: Hashable, Sendable, CustomStringConvertible {
    public var origin: Vec3
    public var direction: Vec3

    /// Creates a ray; `direction` is normalised.
    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction.normalized
    }

    /// The point at parameter `t` (distance from the origin in mm).
    public func point(at t: Double) -> Vec3 { origin + direction * t }

    /// Intersection with a plane (nil when parallel or behind the origin).
    public func intersect(_ plane: Plane) -> Vec3? {
        plane.intersect(rayOrigin: origin, direction: direction)
    }

    /// Parameter of the point on the ray closest to the infinite line `p + s * d`
    /// together with that line parameter `s`. Nil when ray and line are parallel.
    public func closestParameters(toLine p: Vec3, direction d: Vec3) -> (t: Double, s: Double)? {
        let u = direction, v = d.normalized
        let w0 = origin - p
        let a = u.dot(u), b = u.dot(v), c = v.dot(v), dd = u.dot(w0), e = v.dot(w0)
        let den = a * c - b * b
        guard abs(den) > 1e-12 else { return nil }
        let t = (b * e - c * dd) / den
        let s = (a * e - b * dd) / den
        return (t, s)
    }

    public var description: String { "Ray(\(origin) → \(direction))" }
}

/// Axis-aligned bounding box in world space.
public struct Bounds3: Hashable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) { self.min = min; self.max = max }

    /// Smallest box containing all points, or nil for an empty sequence.
    public init?<S: Sequence>(points: S) where S.Element == Vec3 {
        var it = points.makeIterator()
        guard let first = it.next() else { return nil }
        var lo = first.simd, hi = first.simd
        while let p = it.next() { lo = simd_min(lo, p.simd); hi = simd_max(hi, p.simd) }
        self.init(min: Vec3(lo), max: Vec3(hi))
    }

    public var center: Vec3 { (min + max) * 0.5 }
    public var size: Vec3 { max - min }
    /// Radius of the bounding sphere around `center`.
    public var radius: Double { size.length * 0.5 }

    public func union(_ o: Bounds3) -> Bounds3 {
        Bounds3(min: Vec3(simd_min(min.simd, o.min.simd)), max: Vec3(simd_max(max.simd, o.max.simd)))
    }

    public func union(_ p: Vec3) -> Bounds3 {
        Bounds3(min: Vec3(simd_min(min.simd, p.simd)), max: Vec3(simd_max(max.simd, p.simd)))
    }
}

extension Mesh {
    /// World bounds as `Bounds3`, nil for an empty mesh.
    var bounds3: Bounds3? {
        guard let b = bounds else { return nil }
        return Bounds3(min: Vec3(b.min), max: Vec3(b.max))
    }
}

// MARK: - Matrix helpers (Metal clip space: x,y ∈ [-1,1], z ∈ [0,1])

enum Mat {
    static func lookAt(eye: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>) -> simd_double4x4 {
        // Rows are the camera axes; camera looks down -Z (back points towards the viewer).
        simd_double4x4(rows: [
            SIMD4(right.x, right.y, right.z, -simd_dot(right, eye)),
            SIMD4(up.x, up.y, up.z, -simd_dot(up, eye)),
            SIMD4(back.x, back.y, back.z, -simd_dot(back, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    static func perspective(fovY: Double, aspect: Double, near: Double, far: Double) -> simd_double4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_double4x4(rows: [
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, zs * near),
            SIMD4(0, 0, -1, 0),
        ])
    }

    static func orthographic(halfWidth: Double, halfHeight: Double, near: Double, far: Double) -> simd_double4x4 {
        let zs = 1 / (near - far)
        return simd_double4x4(rows: [
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, zs, near * zs),
            SIMD4(0, 0, 0, 1),
        ])
    }

    static func float(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
            SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }
}

extension SIMD3 where Scalar == Double {
    var vec3: Vec3 { Vec3(self) }
}

@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
