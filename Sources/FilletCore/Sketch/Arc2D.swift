import Foundation
import simd

/// A circular arc in the plane, described by centre, radius, start angle and
/// signed sweep (positive = counter-clockwise). Angles in radians.
public struct Arc2D: Hashable, Sendable {
    public var center: SIMD2<Double>
    public var radius: Double
    public var startAngle: Double
    public var sweep: Double

    public init(center: SIMD2<Double>, radius: Double, startAngle: Double, sweep: Double) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.sweep = sweep
    }

    /// The arc from `start` through `through` to `end`; nil when the points are
    /// (nearly) collinear or coincident.
    public init?(start a: SIMD2<Double>, through b: SIMD2<Double>, end c: SIMD2<Double>) {
        guard let center = Arc2D.circumcenter(a, b, c) else { return nil }
        let a0 = Arc2D.angle(of: a - center)
        let ccwThrough = Arc2D.positiveAngle(Arc2D.angle(of: b - center) - a0)
        var ccwEnd = Arc2D.positiveAngle(Arc2D.angle(of: c - center) - a0)
        if ccwEnd == 0 { ccwEnd = 2 * .pi }  // start == end: full circle through `through`
        self.center = center
        self.radius = simd_length(a - center)
        self.startAngle = a0
        self.sweep = ccwThrough < ccwEnd ? ccwEnd : ccwEnd - 2 * .pi
    }

    /// Point at parameter `t` ∈ [0, 1] along the arc.
    public func point(at t: Double) -> SIMD2<Double> {
        let a = startAngle + sweep * t
        return center + radius * SIMD2(cos(a), sin(a))
    }

    public var start: SIMD2<Double> { point(at: 0) }
    public var mid: SIMD2<Double> { point(at: 0.5) }
    public var end: SIMD2<Double> { point(at: 1) }

    /// Points along the arc with at most `maxStep` radians between them.
    public func sampled(maxStep: Double = .pi / 36) -> [SIMD2<Double>] {
        let n = max(2, Int((abs(sweep) / maxStep).rounded(.up)))
        return (0...n).map { point(at: Double($0) / Double(n)) }
    }

    static func circumcenter(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> SIMD2<Double>? {
        let ab = b - a, ac = c - a
        let cross = ab.x * ac.y - ab.y * ac.x
        let scale = simd_length(ab) * simd_length(ac)
        guard scale > 0, abs(cross) > 1e-9 * scale else { return nil }
        let d = 2 * cross
        let ab2 = simd_length_squared(ab), ac2 = simd_length_squared(ac)
        let ux = (ac.y * ab2 - ab.y * ac2) / d
        let uy = (ab.x * ac2 - ac.x * ab2) / d
        return a + SIMD2(ux, uy)
    }

    static func angle(of v: SIMD2<Double>) -> Double { atan2(v.y, v.x) }

    /// Angle normalised into [0, 2π).
    static func positiveAngle(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 2 * .pi)
        return r < 0 ? r + 2 * .pi : r
    }
}
