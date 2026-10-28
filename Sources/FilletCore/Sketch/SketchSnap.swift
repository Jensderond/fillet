import FilletKernel
import Foundation

/// What kind of feature a snap point marks.
public enum SnapKind: String, Hashable, Sendable, CaseIterable {
    case endpoint, midpoint, center, quadrant
    /// A sketch point shape or an interior spline point.
    case point
    /// Where curves of two different shapes cross.
    case intersection
}

/// A point the sketch UI can snap to.
public struct SnapPoint: Hashable, Sendable {
    public var position: SIMD2<Double>
    public var kind: SnapKind
    public var shape: UUID
    /// The second shape of an intersection.
    public var other: UUID?

    public init(position: SIMD2<Double>, kind: SnapKind, shape: UUID, other: UUID? = nil) {
        self.position = position
        self.kind = kind
        self.shape = shape
        self.other = other
    }
}

extension SketchShape {
    /// Endpoints, midpoints, centres and circle quadrants of this shape
    /// (deduplicated; empty when it cannot be evaluated).
    public func snapPoints(using evaluator: Evaluator) -> [SnapPoint] {
        var out: [SnapPoint] = []
        func add(_ p: SIMD2<Double>, _ kind: SnapKind) {
            guard !out.contains(where: { $0.kind == kind && $0.position.isClose(to: p, tolerance: 1e-7) }) else { return }
            out.append(SnapPoint(position: p, kind: kind, shape: id))
        }

        if case .point(let p) = kind {
            if let v = try? p.evaluate(using: evaluator) { add(v, .point) }
            return out
        }
        guard let curves = try? curves(using: evaluator) else { return [] }

        for curve in curves {
            switch curve {
            case .line(let a, let b):
                add(a, .endpoint)
                add(b, .endpoint)
                add((a + b) / 2, .midpoint)
            case .arc(let a, let m, let b):
                add(a, .endpoint)
                add(b, .endpoint)
                if let arc = Arc2D(start: a, through: m, end: b) {
                    add(arc.mid, .midpoint)
                    add(arc.center, .center)
                }
            case .circle(let c, let r):
                add(c, .center)
                for q in [SIMD2(r, 0), SIMD2(0, r), SIMD2(-r, 0), SIMD2(0, -r)] { add(c + q, .quadrant) }
            case .bspline(let points):
                for (i, p) in points.enumerated() {
                    add(p, i == 0 || i == points.count - 1 ? .endpoint : .point)
                }
            }
        }

        // Shape centres that are not curve centres.
        switch kind {
        case .rectangle(let anchor, let position, let width, let height, let angle):
            if let w = try? evaluator.length(width), let h = try? evaluator.length(height),
                let a = try? evaluator.angleRadians(angle), let p = try? position.evaluate(using: evaluator)
            {
                let c = SketchShapeKind.rectangleCorners(anchor: anchor, position: p, width: w, height: h, angle: a)
                add((c[0] + c[2]) / 2, .center)
            }
        case .polygon(let center, _, _, _, _):
            if let c = try? center.evaluate(using: evaluator) { add(c, .center) }
        default:
            break
        }
        return out
    }
}

extension Sketch {
    /// Snap points of all shapes (construction included).
    public func snapPoints(using evaluator: Evaluator) -> [SnapPoint] {
        shapes.flatMap { $0.snapPoints(using: evaluator) }
    }
}
