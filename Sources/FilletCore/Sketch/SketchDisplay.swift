import FilletKernel
import Foundation
import simd

extension Segment2D {
    /// Sampled points along the curve for drawing. Arcs/circles use at most
    /// `maxAngleStep` radians per step; splines are approximated with a
    /// centripetal Catmull-Rom curve through the points.
    public func sampled(maxAngleStep: Double = .pi / 36) -> [SIMD2<Double>] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .arc(let a, let m, let b):
            return Arc2D(start: a, through: m, end: b)?.sampled(maxStep: maxAngleStep) ?? [a, m, b]
        case .circle(let c, let r):
            return Arc2D(center: c, radius: r, startAngle: 0, sweep: 2 * .pi).sampled(maxStep: maxAngleStep)
        case .bspline(let points):
            return CatmullRom.sample(points)
        }
    }
}

extension SketchShape {
    /// Polylines for drawing this shape (construction shapes included).
    /// Connected curves are merged into one polyline; a point shape yields a
    /// single one-point polyline. Returns `[]` when the shape cannot be evaluated.
    public func displayPolyline(using evaluator: Evaluator, maxAngleStep: Double = .pi / 36) -> [[SIMD2<Double>]] {
        if case .point(let p) = kind {
            guard let v = try? p.evaluate(using: evaluator) else { return [] }
            return [[v]]
        }
        guard let curves = try? curves(using: evaluator) else { return [] }
        var result: [[SIMD2<Double>]] = []
        for curve in curves {
            let pts = curve.sampled(maxAngleStep: maxAngleStep)
            if let last = result.last?.last, let first = pts.first, last.isClose(to: first, tolerance: 1e-7) {
                result[result.count - 1] += pts.dropFirst()
            } else {
                result.append(pts)
            }
        }
        return result
    }
}

/// Centripetal Catmull-Rom interpolation, used to preview interpolating splines.
enum CatmullRom {
    static func sample(_ p: [SIMD2<Double>], stepsPerSpan: Int = 12) -> [SIMD2<Double>] {
        guard p.count > 2 else { return p }
        // Mirror the end points to create phantom control points.
        let pts = [2 * p[0] - p[1]] + p + [2 * p[p.count - 1] - p[p.count - 2]]
        var out: [SIMD2<Double>] = [p[0]]
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            func knot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { max(simd_distance(a, b).squareRoot(), 1e-9) }
            let t0 = 0.0, t1 = t0 + knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
            for s in 1...stepsPerSpan {
                let t = t1 + (t2 - t1) * Double(s) / Double(stepsPerSpan)
                let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
                let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
                let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
                let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
                let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
                out.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
            }
        }
        return out
    }
}
