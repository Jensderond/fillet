import FilletKernel
import Foundation
import simd

/// A sketch shape whose dimensions evaluate to invalid geometry.
public struct SketchError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public var shape: UUID?

    public init(_ message: String, shape: UUID? = nil) {
        self.message = message
        self.shape = shape
    }

    public var description: String { message }
}

extension SketchShape {
    /// Profile curves for region detection. Construction shapes produce none.
    public func segments(using evaluator: Evaluator) throws -> [Segment2D] {
        construction ? [] : try curves(using: evaluator)
    }

    /// The shape's curves regardless of the construction flag (for display and snapping).
    public func curves(using evaluator: Evaluator) throws -> [Segment2D] {
        do {
            return try kind.curves(using: evaluator)
        } catch var error as SketchError {
            error.shape = id
            throw error
        }
    }
}

extension Sketch {
    /// All profile curves of the non-construction shapes, in shape order.
    public func segments(using evaluator: Evaluator) throws -> [Segment2D] {
        var result: [Segment2D] = []
        for s in shapes { result += try s.segments(using: evaluator) }
        return result
    }
}

extension SketchShapeKind {
    /// Evaluated curves of this shape.
    public func curves(using ev: Evaluator) throws -> [Segment2D] {
        switch self {
        case .line(let a, let b):
            let p = try a.evaluate(using: ev), q = try b.evaluate(using: ev)
            guard !p.isClose(to: q) else { throw SketchError("Line has zero length") }
            return [.line(p, q)]

        case .polyline(let vertices, let closed):
            guard vertices.count >= 2 else { throw SketchError("Polyline needs at least two points") }
            let points = try vertices.map { try $0.point.evaluate(using: ev) }
            let count = closed ? points.count : points.count - 1
            var result: [Segment2D] = []
            for i in 0..<count {
                let p = points[i], q = points[(i + 1) % points.count]
                guard !p.isClose(to: q) else { throw SketchError("Polyline has two coincident points") }
                let sagitta = try vertices[i].bulge.map { try ev.length($0) } ?? 0
                if abs(sagitta) < 1e-9 {
                    result.append(.line(p, q))
                } else {
                    let d = simd_normalize(q - p)
                    let through = (p + q) / 2 + SIMD2(-d.y, d.x) * sagitta
                    result.append(.arc(start: p, through: through, end: q))
                }
            }
            return result

        case .rectangle(let anchor, let position, let width, let height, let angle):
            let w = try ev.length(width), h = try ev.length(height)
            guard abs(w) > 1e-9, abs(h) > 1e-9 else { throw SketchError("Rectangle has zero width or height") }
            let corners = try SketchShapeKind.rectangleCorners(
                anchor: anchor, position: position.evaluate(using: ev), width: w, height: h,
                angle: ev.angleRadians(angle))
            return (0..<4).map { .line(corners[$0], corners[($0 + 1) % 4]) }

        case .circle(let center, let diameter):
            let d = try ev.length(diameter)
            guard d > 1e-9 else { throw SketchError("Circle diameter must be positive") }
            return [.circle(center: try center.evaluate(using: ev), radius: d / 2)]

        case .arc(let start, let through, let end):
            let a = try start.evaluate(using: ev), b = try through.evaluate(using: ev), c = try end.evaluate(using: ev)
            guard Arc2D(start: a, through: b, end: c) != nil else { throw SketchError("Arc points are collinear") }
            return [.arc(start: a, through: b, end: c)]

        case .polygon(let center, let sides, let radius, let inscribed, let angle):
            let vertices = try SketchShapeKind.polygonVertices(
                center: center.evaluate(using: ev), sides: ev.integer(sides), radius: ev.length(radius),
                inscribed: inscribed, angle: ev.angleRadians(angle))
            return (0..<vertices.count).map { .line(vertices[$0], vertices[($0 + 1) % vertices.count]) }

        case .slot(let a, let b, let width):
            let p = try a.evaluate(using: ev), q = try b.evaluate(using: ev), w = try ev.length(width)
            guard w > 1e-9 else { throw SketchError("Slot width must be positive") }
            let r = w / 2
            if p.isClose(to: q) { return [.circle(center: p, radius: r)] }
            let d = simd_normalize(q - p), n = SIMD2(-d.y, d.x)
            // Counter-clockwise: right side a→b, round end at b, left side b→a, round end at a.
            return [
                .line(p - n * r, q - n * r),
                .arc(start: q - n * r, through: q + d * r, end: q + n * r),
                .line(q + n * r, p + n * r),
                .arc(start: p + n * r, through: p - d * r, end: p - n * r),
            ]

        case .spline(let points):
            guard points.count >= 2 else { throw SketchError("Spline needs at least two points") }
            let pts = try points.map { try $0.evaluate(using: ev) }
            for i in 1..<pts.count where pts[i].isClose(to: pts[i - 1]) {
                throw SketchError("Spline has two coincident points")
            }
            return [.bspline(pts)]

        case .point:
            return []
        }
    }

    static func rectangleCorners(
        anchor: RectangleAnchor, position: SIMD2<Double>, width w: Double, height h: Double, angle: Double
    ) -> [SIMD2<Double>] {
        let ux = SIMD2(cos(angle), sin(angle)), uy = SIMD2(-sin(angle), cos(angle))
        let origin = anchor == .corner ? position : position - ux * (w / 2) - uy * (h / 2)
        return [origin, origin + ux * w, origin + ux * w + uy * h, origin + uy * h]
    }

    static func polygonVertices(
        center: SIMD2<Double>, sides: Int, radius: Double, inscribed: Bool, angle: Double
    ) throws -> [SIMD2<Double>] {
        guard (3...1000).contains(sides) else { throw SketchError("Polygon needs 3 to 1000 sides") }
        guard radius > 1e-9 else { throw SketchError("Polygon radius must be positive") }
        let n = Double(sides)
        let r = inscribed ? radius : radius / cos(.pi / n)
        return (0..<sides).map { k in
            let a = angle + 2 * .pi * Double(k) / n
            return center + r * SIMD2(cos(a), sin(a))
        }
    }
}

extension SIMD2 where Scalar == Double {
    func isClose(to o: SIMD2<Double>, tolerance: Double = 1e-9) -> Bool {
        simd_distance(self, o) <= tolerance
    }
}
