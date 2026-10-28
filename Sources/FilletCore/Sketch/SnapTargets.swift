import FilletKernel
import Foundation
import simd

/// A straight edge of existing geometry. Past either end, its extension is a snap guide.
public struct SnapLine: Hashable, Sendable {
    public var a: SIMD2<Double>
    public var b: SIMD2<Double>
    public var shape: UUID

    public init(a: SIMD2<Double>, b: SIMD2<Double>, shape: UUID) {
        self.a = a; self.b = b; self.shape = shape
    }
}

/// Everything the pointer can snap to in one sketch: key points (intersections included) and
/// straight edges. Points are kept sorted by x and by y, so a pointer event only looks at the
/// points within the snap radius instead of scanning the sketch. Build it once per sketch change
/// (`Sketch.snapTargets(using:)`), not per pointer event.
public struct SnapTargets: Sendable {
    /// Sorted by x.
    public private(set) var points: [SnapPoint]
    /// Indices into `points`, sorted by y.
    private var byY: [Int]
    public private(set) var lines: [SnapLine]

    public init(points: [SnapPoint] = [], lines: [SnapLine] = []) {
        let sorted = points.sorted { $0.position.x < $1.position.x }
        self.points = sorted
        byY = sorted.indices.sorted { sorted[$0].position.y < sorted[$1].position.y }
        self.lines = lines
    }

    public static let empty = SnapTargets()

    /// Points whose x lies within `r` of `x`.
    public func points(xWithin r: Double, of x: Double) -> ArraySlice<SnapPoint> {
        let lo = firstIndex(points.count) { points[$0].position.x >= x - r }
        let hi = firstIndex(points.count) { points[$0].position.x > x + r }
        return points[lo..<max(lo, hi)]
    }

    /// Points whose y lies within `r` of `y`.
    public func points(yWithin r: Double, of y: Double) -> [SnapPoint] {
        let lo = firstIndex(byY.count) { points[byY[$0]].position.y >= y - r }
        let hi = firstIndex(byY.count) { points[byY[$0]].position.y > y + r }
        return byY[lo..<max(lo, hi)].map { points[$0] }
    }

    /// Points within `r` of `p`.
    public func points(near p: SIMD2<Double>, within r: Double) -> [SnapPoint] {
        points(xWithin: r, of: p.x).filter { snapDistance($0.position, p) <= r }
    }

    /// Without the points and edges of `shapes` (shapes being moved can't snap to themselves).
    public func excluding(_ shapes: Set<UUID>) -> SnapTargets {
        guard !shapes.isEmpty else { return self }
        return SnapTargets(
            points: points.filter { !shapes.contains($0.shape) && !($0.other.map(shapes.contains) ?? false) },
            lines: lines.filter { !shapes.contains($0.shape) })
    }

    /// With more points (the sketch origin).
    public func adding(_ more: [SnapPoint]) -> SnapTargets {
        SnapTargets(points: points + more, lines: lines)
    }

    /// The first index in 0..<count where `isAbove` holds (it must be monotonic).
    private func firstIndex(_ count: Int, where isAbove: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isAbove(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

func snapDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}

extension Sketch {
    /// Snap points of every shape, the points where curves of different shapes cross, and the
    /// straight edges (for extension guides). Splines take part with their points only.
    public func snapTargets(using evaluator: Evaluator) -> SnapTargets {
        var points = snapPoints(using: evaluator)
        var lines: [SnapLine] = []
        var curves: [(shape: UUID, curve: SnapCurve)] = []
        for shape in shapes {
            if case .point = shape.kind { continue }
            guard let segments = try? shape.curves(using: evaluator) else { continue }
            for segment in segments {
                if case .line(let a, let b) = segment { lines.append(SnapLine(a: a, b: b, shape: shape.id)) }
                if let curve = SnapCurve(segment) { curves.append((shape.id, curve)) }
            }
        }
        // Crossings of curves of different shapes, except where a point already snaps (shared corners).
        let boxes = curves.map(\.curve.bounds)
        var crossings: [SnapPoint] = []
        for i in curves.indices {
            for j in (i + 1)..<curves.count where curves[i].shape != curves[j].shape && boxes[i].overlaps(boxes[j]) {
                for p in curves[i].curve.intersections(with: curves[j].curve)
                where !points.contains(where: { $0.position.isClose(to: p, tolerance: 1e-7) })
                    && !crossings.contains(where: { $0.position.isClose(to: p, tolerance: 1e-7) })
                {
                    crossings.append(SnapPoint(position: p, kind: .intersection, shape: curves[i].shape, other: curves[j].shape))
                }
            }
        }
        points += crossings
        return SnapTargets(points: points, lines: lines)
    }
}

/// A sketch curve reduced to what intersections need: a segment, or a circle or arc of one.
enum SnapCurve {
    case segment(SIMD2<Double>, SIMD2<Double>)
    /// A full circle has `arc == nil`.
    case circular(center: SIMD2<Double>, radius: Double, arc: Arc2D?)

    init?(_ segment: Segment2D) {
        switch segment {
        case .line(let a, let b): self = .segment(a, b)
        case .arc(let a, let m, let b):
            guard let arc = Arc2D(start: a, through: m, end: b) else { return nil }
            self = .circular(center: arc.center, radius: arc.radius, arc: arc)
        case .circle(let c, let r): self = .circular(center: c, radius: r, arc: nil)
        case .bspline: return nil
        }
    }

    struct Box {
        var min: SIMD2<Double>, max: SIMD2<Double>
        func overlaps(_ o: Box) -> Bool {
            let e = 1e-9
            return min.x <= o.max.x + e && o.min.x <= max.x + e && min.y <= o.max.y + e && o.min.y <= max.y + e
        }
    }

    var bounds: Box {
        switch self {
        case .segment(let a, let b): Box(min: simd_min(a, b), max: simd_max(a, b))
        case .circular(let c, let r, _): Box(min: c - SIMD2(r, r), max: c + SIMD2(r, r))
        }
    }

    func intersections(with other: SnapCurve) -> [SIMD2<Double>] {
        switch (self, other) {
        case (.segment(let a, let b), .segment(let c, let d)):
            return Self.segmentSegment(a, b, c, d).map { [$0] } ?? []
        case (.segment(let a, let b), .circular(let c, let r, let arc)), (.circular(let c, let r, let arc), .segment(let a, let b)):
            return Self.segmentCircle(a, b, c, r).filter { arc?.contains($0) ?? true }
        case (.circular(let c1, let r1, let arc1), .circular(let c2, let r2, let arc2)):
            return Self.circleCircle(c1, r1, c2, r2).filter { (arc1?.contains($0) ?? true) && (arc2?.contains($0) ?? true) }
        }
    }

    static func segmentSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD2<Double>? {
        let r = b - a, s = d - c
        let denom = cross(r, s)
        guard abs(denom) > 1e-12 * max(simd_length(r) * simd_length(s), 1e-12) else { return nil }  // parallel
        let t = cross(c - a, s) / denom, u = cross(c - a, r) / denom
        let e = 1e-9
        guard t >= -e, t <= 1 + e, u >= -e, u <= 1 + e else { return nil }
        return a + r * t
    }

    static func segmentCircle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ radius: Double) -> [SIMD2<Double>] {
        let d = b - a, f = a - c
        let qa = simd_dot(d, d), qb = 2 * simd_dot(f, d), qc = simd_dot(f, f) - radius * radius
        guard qa > 1e-18 else { return [] }
        let disc = qb * qb - 4 * qa * qc
        guard disc >= -1e-12 * qa * radius * radius else { return [] }
        let root = max(disc, 0).squareRoot()
        let ts: [Double] = root < 1e-12 ? [-qb / (2 * qa)] : [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)]
        return ts.filter { t in t >= -1e-9 && t <= 1 + 1e-9 }.map { t in a + d * t }
    }

    static func circleCircle(_ c1: SIMD2<Double>, _ r1: Double, _ c2: SIMD2<Double>, _ r2: Double) -> [SIMD2<Double>] {
        let v = c2 - c1
        let dist = simd_length(v)
        guard dist > 1e-9, dist <= r1 + r2 + 1e-9, dist >= abs(r1 - r2) - 1e-9 else { return [] }
        let along = (r1 * r1 - r2 * r2 + dist * dist) / (2 * dist)
        let h = max(r1 * r1 - along * along, 0).squareRoot()
        let base = c1 + v * (along / dist)
        let n = SIMD2(-v.y, v.x) / dist
        return h < 1e-9 ? [base] : [base + n * h, base - n * h]
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
}

extension Arc2D {
    /// Whether `p` (on the arc's circle) lies within its sweep.
    func contains(_ p: SIMD2<Double>) -> Bool {
        let angle = Arc2D.angle(of: p - center)
        let travelled = sweep >= 0 ? Arc2D.positiveAngle(angle - startAngle) : Arc2D.positiveAngle(startAngle - angle)
        let e = 1e-9
        return travelled <= abs(sweep) + e || travelled >= 2 * .pi - e
    }
}
