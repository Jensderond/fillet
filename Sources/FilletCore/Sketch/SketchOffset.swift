import FilletKernel
import Foundation
import simd

/// Curves picked for sketch Offset, as Fusion's chain selection picks them: a closed shape by
/// itself, or the open curves (lines, arcs, open polylines) joined end to end with the picked
/// one, up to where the chain ends or branches.
///
/// Offsetting is plain 2D geometry rather than OCCT's `BRepOffsetAPI_MakeOffset`, so the result
/// can stay the kind of shape it came from (a circle gives a circle, a slot a slot, a rectangle
/// offset inward a rectangle) and the preview keeps up with the pointer. Lines and arcs offset
/// side by side; convex corners get an arc around the corner (Fusion's default), concave
/// corners are trimmed where the offset curves cross.
public struct OffsetChain: Hashable, Sendable {
    /// The shapes in the chain, in chain order.
    public var shapes: [UUID]
    public var closed: Bool
    public var construction: Bool
    /// The chain's curves in travel order; closed chains run counter-clockwise, so left is inside.
    var curves: [ChainCurve]
    /// A single shape that offsets into the same kind of shape.
    var special: Special?

    enum Special: Hashable, Sendable {
        case circle(center: Point2Expr, radius: Double)
        case slot(a: Point2Expr, b: Point2Expr, width: Double)
        case rectangle(center: SIMD2<Double>, width: Double, height: Double, angle: Expr)
        case polygon(center: Point2Expr, sides: Expr, count: Int, radius: Double, inscribed: Bool, angle: Expr)
        case spline([SIMD2<Double>])
    }

    /// The signed distance of `p` from the chain: positive outside a closed chain or to the left
    /// of an open one (seen along the chain's direction), with the nearest point on the chain.
    public func signedDistance(to p: SIMD2<Double>) -> (distance: Double, nearest: SIMD2<Double>) {
        var best = (distance: Double.infinity, point: p, tangent: SIMD2<Double>(1, 0))
        for curve in curves {
            let c = curve.closest(to: p)
            if c.distance < best.distance { best = c }
        }
        let side: Double
        if closed {
            side = contains(p) ? -1 : 1
        } else {
            let v = p - best.point
            side = best.tangent.x * v.y - best.tangent.y * v.x >= 0 ? 1 : -1
        }
        return (best.distance * side, best.point)
    }

    /// Display polylines of the chain itself.
    public var polylines: [[SIMD2<Double>]] { curves.map { $0.sampled() } }

    /// Even-odd test against the sampled outline.
    func contains(_ p: SIMD2<Double>) -> Bool {
        let outline = curves.flatMap { $0.sampled().dropLast() }
        var inside = false
        var j = outline.count - 1
        for i in outline.indices {
            let a = outline[i], b = outline[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// The offset copies, `distance` mm outward (closed chains) or to the left (open chains);
    /// negative goes inward or to the right. Throws with a short reason when the offset would
    /// collapse or turn inside out.
    public func offset(by distance: Double) throws -> [SketchShapeKind] {
        guard abs(distance) > 1e-9 else { return [] }
        let tooFar = SketchError(closed ? "Too far in: the offset would collapse" : "Too far: the offset would fold over")
        func e(_ v: Double) -> Expr { SketchToolEngine.expr(v) }
        switch special {
        case .circle(let center, let r):
            guard r + distance > 1e-6 else { throw tooFar }
            return [.circle(center: center, diameter: e(2 * (r + distance)))]
        case .slot(let a, let b, let w):
            guard w / 2 + distance > 1e-6 else { throw tooFar }
            return [.slot(a: a, b: b, width: e(w + 2 * distance))]
        case .rectangle(let center, let w, let h, let angle) where distance < 0:
            guard w + 2 * distance > 1e-6, h + 2 * distance > 1e-6 else { throw tooFar }
            return [.rectangle(anchor: .center, position: SketchToolEngine.expr(center), width: e(w + 2 * distance),
                               height: e(h + 2 * distance), angle: angle)]
        case .polygon(let center, let sides, let n, let r, let inscribed, let angle) where distance < 0:
            // An inscribed polygon's radius reaches the corners, which move 1/cos(π/n) times as far.
            let radius = r + (inscribed ? distance / cos(.pi / Double(n)) : distance)
            guard radius > 1e-6 else { throw tooFar }
            return [.polygon(center: center, sides: sides, radius: e(radius), inscribed: inscribed, angle: angle)]
        case .spline(let points):
            return [.spline(points: Self.offsetSpline(points, by: distance).map(SketchToolEngine.expr))]
        default:
            break
        }
        let result = try Self.offset(curves, closed: closed, left: closed ? -distance : distance, tooFar: tooFar)
        return [Self.shape(result, closed: closed)]
    }

    // MARK: Lines and arcs

    /// Offsets connected curves `left` mm to the left: arcs round convex corners, concave corners
    /// trim. Refuses when a curve would vanish or reverse, or when any part of the result comes
    /// closer to the original than the distance (the offset ran into another part of the chain).
    static func offset(_ curves: [ChainCurve], closed: Bool, left d: Double, tooFar: SketchError) throws -> [ChainCurve] {
        var pieces = try curves.map { c -> ChainCurve in
            guard let o = c.offset(d) else { throw tooFar }
            return o
        }
        // Corner arcs to insert after piece i.
        var corners: [Int: ChainCurve] = [:]
        let n = curves.count
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            guard j != i else { continue }
            let t1 = curves[i].endTangent, t2 = curves[j].startTangent
            let cross = t1.x * t2.y - t1.y * t2.x, dot = simd_dot(t1, t2)
            if abs(cross) < 1e-9 {
                // Smooth: the offsets meet already. A cusp (turning back) can't be offset.
                guard dot > 0 else { throw SketchError("Can't offset a chain that turns back on itself") }
                continue
            }
            let vertex = curves[i].end
            if cross * d < 0 {
                // Convex for this side: a gap opens, bridged by an arc around the corner.
                // It turns as far as the curves do, from the end of one offset to the start of the next.
                let a = pieces[i].end
                corners[i] = .arc(Arc2D(center: vertex, radius: abs(d), startAngle: atan2(a.y - vertex.y, a.x - vertex.x),
                                        sweep: atan2(cross, dot)))
            } else {
                // Concave: the offsets overlap; trim both to where they cross nearest the corner.
                let hits = pieces[i].intersections(with: pieces[j])
                guard let x = hits.min(by: { simd_distance($0, vertex) < simd_distance($1, vertex) }),
                    pieces[i].trimEnd(to: x), pieces[j].trimStart(to: x)
                else { throw tooFar }
            }
        }
        var result: [ChainCurve] = []
        for i in 0..<n {
            result.append(pieces[i])
            if let arc = corners[i] { result.append(arc) }
        }
        // Every point of a true offset is exactly the distance away from the original.
        let limit = abs(d) * (1 - 1e-6) - 1e-7
        for curve in result {
            for p in curve.sampled(maxStep: .pi / 72, linePoints: 16) {
                if curves.contains(where: { $0.closest(to: p).distance < limit }) { throw tooFar }
            }
        }
        return result
    }

    /// One line or arc stays that shape; anything longer becomes a polyline with arc bulges.
    static func shape(_ curves: [ChainCurve], closed: Bool) -> SketchShapeKind {
        func e(_ p: SIMD2<Double>) -> Point2Expr { SketchToolEngine.expr(p) }
        if !closed, curves.count == 1 {
            switch curves[0] {
            case .line(let a, let b): return .line(a: e(a), b: e(b))
            case .arc(let arc): return .arc(start: e(arc.start), through: e(arc.mid), end: e(arc.end))
            }
        }
        var vertices = curves.map { curve -> PolylineVertex in
            switch curve {
            case .line(let a, _):
                return PolylineVertex(e(a))
            case .arc(let arc):
                let p = arc.start, q = arc.end
                let dir = simd_normalize(q - p)
                let sagitta = simd_dot(arc.mid - (p + q) / 2, SIMD2(-dir.y, dir.x))
                return PolylineVertex(e(p), bulge: SketchToolEngine.expr(sagitta))
            }
        }
        if !closed, let last = curves.last { vertices.append(PolylineVertex(e(last.end))) }
        return .polyline(vertices: vertices, closed: closed)
    }

    /// Moves each spline point along the curve's normal there (estimated from its neighbours).
    /// Approximate: the spline through the moved points follows the true offset closely on
    /// gentle curves.
    static func offsetSpline(_ points: [SIMD2<Double>], by d: Double) -> [SIMD2<Double>] {
        points.indices.map { i in
            let prev = points[max(i - 1, 0)], next = points[min(i + 1, points.count - 1)]
            let t = simd_normalize(next - prev)
            return points[i] + SIMD2(-t.y, t.x) * d
        }
    }
}

// MARK: - Chains

extension Sketch {
    /// The chain `id` belongs to (see `OffsetChain`), or nil for a point or a shape that
    /// doesn't evaluate.
    public func offsetChain(containing id: UUID, using ev: Evaluator) -> OffsetChain? {
        guard let shape = shape(id), let curves = try? shape.curves(using: ev), !curves.isEmpty else { return nil }
        func single(_ closed: Bool, _ special: OffsetChain.Special? = nil) -> OffsetChain {
            var chain = OffsetChain(shapes: [id], closed: closed, construction: shape.construction,
                                    curves: curves.flatMap(ChainCurve.from), special: special)
            if closed { chain.orientCounterClockwise() }
            return chain
        }
        switch shape.kind {
        case .point:
            return nil
        case .circle(let center, _):
            guard case .circle(_, let r) = curves[0] else { return nil }
            return single(true, .circle(center: center, radius: r))
        case .slot(let a, let b, let width):
            guard let w = try? ev.length(width) else { return nil }
            return single(true, .slot(a: a, b: b, width: w))
        case .rectangle(let anchor, let position, let width, let height, let angle):
            guard let w = try? ev.length(width), let h = try? ev.length(height), let p = try? position.evaluate(using: ev),
                let a = try? ev.angleRadians(angle)
            else { return nil }
            let c = SketchShapeKind.rectangleCorners(anchor: anchor, position: p, width: w, height: h, angle: a)
            return single(true, .rectangle(center: (c[0] + c[2]) / 2, width: abs(w), height: abs(h), angle: angle))
        case .polygon(let center, let sides, let radius, let inscribed, let angle):
            guard let n = try? ev.integer(sides), let r = try? ev.length(radius) else { return nil }
            return single(true, .polygon(center: center, sides: sides, count: n, radius: r, inscribed: inscribed, angle: angle))
        case .polyline(_, true):
            return single(true)
        case .spline(let points):
            guard let pts = try? points.map({ try $0.evaluate(using: ev) }), pts.count >= 2 else { return nil }
            return single(false, .spline(pts))
        case .line, .arc, .polyline:
            return openChain(from: shape, using: ev)
        }
    }

    /// Walks from `start` along open curves that meet end to end, both ways, stopping at an end,
    /// at a branch (more than one way on), or back at the start (a closed chain).
    private func openChain(from start: SketchShape, using ev: Evaluator) -> OffsetChain? {
        struct Link { var id: UUID; var curves: [ChainCurve] }
        var links: [UUID: Link] = [:]
        for s in shapes where s.construction == start.construction {
            switch s.kind {
            case .line, .arc, .polyline(_, false):
                guard let segs = try? s.curves(using: ev) else { continue }
                let curves = segs.flatMap(ChainCurve.from)
                if !curves.isEmpty { links[s.id] = Link(id: s.id, curves: curves) }
            default:
                continue
            }
        }
        guard let first = links[start.id] else { return nil }
        func meets(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { simd_distance(a, b) < 1e-6 }

        var chain: [ChainCurve] = first.curves
        var ids = [first.id]
        var used: Set<UUID> = [first.id]
        var closed = false
        // Forward from the end, then backward from the start.
        for forward in [true, false] {
            while !closed {
                let head = chain[0].start, tail = chain[chain.count - 1].end
                if meets(head, tail) { closed = true; break }
                let tip = forward ? tail : head
                let next = links.values.filter { !used.contains($0.id) && (meets($0.curves[0].start, tip) || meets($0.curves[$0.curves.count - 1].end, tip)) }
                guard next.count == 1, let link = next.first else { break }
                used.insert(link.id)
                // Forward wants the link to start at the tip; backward wants it to end there.
                let startsAtTip = meets(link.curves[0].start, tip)
                let oriented = startsAtTip == forward ? link.curves : link.curves.reversed().map(\.reversed)
                if forward {
                    chain += oriented
                    ids.append(link.id)
                } else {
                    chain = oriented + chain
                    ids.insert(link.id, at: 0)
                }
            }
        }
        var result = OffsetChain(shapes: ids, closed: closed, construction: start.construction, curves: chain, special: nil)
        if closed { result.orientCounterClockwise() }
        return result
    }

    /// The chains of `ids` (each picked shape once; shapes of the same chain share it), in order.
    public func offsetChains(containing ids: [UUID], using ev: Evaluator) -> [OffsetChain] {
        var chains: [OffsetChain] = []
        for id in ids where !chains.contains(where: { $0.shapes.contains(id) }) {
            if let chain = offsetChain(containing: id, using: ev) { chains.append(chain) }
        }
        return chains
    }

    /// The chain of the curve nearest `p`, if one passes within `tolerance`.
    public func offsetChain(near p: SIMD2<Double>, tolerance: Double, using ev: Evaluator) -> OffsetChain? {
        var best: (UUID, Double)?
        for shape in shapes {
            if case .point = shape.kind { continue }
            guard let curves = try? shape.curves(using: ev) else { continue }
            let d = curves.flatMap(ChainCurve.from).map { $0.closest(to: p).distance }.min() ?? .infinity
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (shape.id, d) }
        }
        return best.flatMap { offsetChain(containing: $0.0, using: ev) }
    }
}

extension OffsetChain {
    /// Reverses a clockwise closed chain, so left is inside.
    mutating func orientCounterClockwise() {
        let outline = curves.flatMap { $0.sampled().dropLast() }
        var area = 0.0
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            area += a.x * b.y - b.x * a.y
        }
        if area < 0 { curves = curves.reversed().map(\.reversed) }
    }
}

// MARK: - Curves

/// A line or arc of a chain, in the direction of travel.
enum ChainCurve: Hashable, Sendable {
    case line(SIMD2<Double>, SIMD2<Double>)
    /// The sweep's sign is the direction of travel (positive = counter-clockwise).
    case arc(Arc2D)

    /// Lines and arcs as they are, a circle as a full arc, a spline as its sampled outline.
    static func from(_ segment: Segment2D) -> [ChainCurve] {
        switch segment {
        case .line(let a, let b): return [.line(a, b)]
        case .arc(let a, let m, let b): return Arc2D(start: a, through: m, end: b).map { [.arc($0)] } ?? [.line(a, b)]
        case .circle(let c, let r): return [.arc(Arc2D(center: c, radius: r, startAngle: 0, sweep: 2 * .pi))]
        case .bspline:
            let pts = segment.sampled()
            return zip(pts, pts.dropFirst()).filter { simd_distance($0, $1) > 1e-9 }.map { .line($0, $1) }
        }
    }

    var start: SIMD2<Double> {
        switch self {
        case .line(let a, _): a
        case .arc(let arc): arc.start
        }
    }

    var end: SIMD2<Double> {
        switch self {
        case .line(_, let b): b
        case .arc(let arc): arc.end
        }
    }

    var startTangent: SIMD2<Double> { tangent(at: 0) }
    var endTangent: SIMD2<Double> { tangent(at: 1) }

    private func tangent(at t: Double) -> SIMD2<Double> {
        switch self {
        case .line(let a, let b): return simd_normalize(b - a)
        case .arc(let arc):
            let angle = arc.startAngle + arc.sweep * t
            return SIMD2(-sin(angle), cos(angle)) * (arc.sweep < 0 ? -1 : 1)
        }
    }

    var reversed: ChainCurve {
        switch self {
        case .line(let a, let b): .line(b, a)
        case .arc(let arc): .arc(Arc2D(center: arc.center, radius: arc.radius, startAngle: arc.startAngle + arc.sweep, sweep: -arc.sweep))
        }
    }

    /// The curve moved `d` mm to its left; nil when an arc would shrink to nothing.
    func offset(_ d: Double) -> ChainCurve? {
        switch self {
        case .line(let a, let b):
            let t = simd_normalize(b - a), n = SIMD2(-t.y, t.x)
            return .line(a + n * d, b + n * d)
        case .arc(var arc):
            // Left of a counter-clockwise arc is towards its centre.
            arc.radius -= d * (arc.sweep < 0 ? -1 : 1)
            return arc.radius > 1e-6 ? .arc(arc) : nil
        }
    }

    /// The nearest point of the curve to `p`, its distance and the direction of travel there.
    func closest(to p: SIMD2<Double>) -> (distance: Double, point: SIMD2<Double>, tangent: SIMD2<Double>) {
        switch self {
        case .line(let a, let b):
            let ab = b - a
            let t = min(max(simd_dot(p - a, ab) / simd_length_squared(ab), 0), 1)
            let q = a + ab * t
            return (simd_distance(p, q), q, simd_normalize(ab))
        case .arc(let arc):
            if let t = parameter(of: p, on: arc) {
                let q = arc.point(at: t)
                return (simd_distance(p, q), q, tangent(at: t))
            }
            let (a, b) = (arc.start, arc.end)
            return simd_distance(p, a) <= simd_distance(p, b) ? (simd_distance(p, a), a, startTangent) : (simd_distance(p, b), b, endTangent)
        }
    }

    /// Where the direction from the centre to `p` crosses the arc, as 0…1 along it; nil off the arc.
    private func parameter(of p: SIMD2<Double>, on arc: Arc2D) -> Double? {
        let v = p - arc.center
        guard simd_length(v) > 1e-12 else { return 0 }
        let along = Arc2D.positiveAngle((atan2(v.y, v.x) - arc.startAngle) * (arc.sweep < 0 ? -1 : 1))
        return along <= abs(arc.sweep) + 1e-12 ? min(along / abs(arc.sweep), 1) : nil
    }

    func sampled(maxStep: Double = .pi / 36, linePoints: Int = 2) -> [SIMD2<Double>] {
        switch self {
        case .line(let a, let b):
            return (0..<linePoints).map { a + (b - a) * (Double($0) / Double(linePoints - 1)) }
        case .arc(let arc):
            return arc.sampled(maxStep: maxStep)
        }
    }

    // MARK: Trimming

    /// Crossings of the two curves' full lines and circles.
    func intersections(with other: ChainCurve) -> [SIMD2<Double>] {
        switch (self, other) {
        case (.line(let a, let b), .line(let c, let d)):
            let r = b - a, s = d - c
            let denom = r.x * s.y - r.y * s.x
            guard abs(denom) > 1e-12 else { return [] }
            let t = ((c - a).x * s.y - (c - a).y * s.x) / denom
            return [a + r * t]
        case (.line(let a, let b), .arc(let arc)), (.arc(let arc), .line(let a, let b)):
            let dir = simd_normalize(b - a)
            let foot = a + dir * simd_dot(arc.center - a, dir)
            let h2 = arc.radius * arc.radius - simd_length_squared(foot - arc.center)
            guard h2 >= -1e-9 else { return [] }
            let h = max(h2, 0).squareRoot()
            return [foot - dir * h, foot + dir * h]
        case (.arc(let p), .arc(let q)):
            let d = simd_distance(p.center, q.center)
            guard d > 1e-12, d <= p.radius + q.radius + 1e-9, d >= abs(p.radius - q.radius) - 1e-9 else { return [] }
            let a = (p.radius * p.radius - q.radius * q.radius + d * d) / (2 * d)
            let h = max(p.radius * p.radius - a * a, 0).squareRoot()
            let u = (q.center - p.center) / d
            let m = p.center + u * a
            return [m + SIMD2(-u.y, u.x) * h, m - SIMD2(-u.y, u.x) * h]
        }
    }

    /// Moves the start to `x` (a point on the curve); false when the curve would vanish or reverse.
    mutating func trimStart(to x: SIMD2<Double>) -> Bool {
        switch self {
        case .line(let a, let b):
            guard simd_dot(b - x, b - a) > 1e-9 else { return false }
            self = .line(x, b)
        case .arc(var arc):
            let s = arc.sweep < 0 ? -1.0 : 1.0
            let moved = Self.wrapped((atan2(x.y - arc.center.y, x.x - arc.center.x) - arc.startAngle) * s)
            guard abs(arc.sweep) - moved > 1e-9 else { return false }
            arc.startAngle += s * moved
            arc.sweep -= s * moved
            self = .arc(arc)
        }
        return true
    }

    /// Moves the end to `x` (a point on the curve); false when the curve would vanish or reverse.
    mutating func trimEnd(to x: SIMD2<Double>) -> Bool {
        switch self {
        case .line(let a, let b):
            guard simd_dot(x - a, b - a) > 1e-9 else { return false }
            self = .line(a, x)
        case .arc(var arc):
            let s = arc.sweep < 0 ? -1.0 : 1.0
            let moved = Self.wrapped((arc.startAngle + arc.sweep - atan2(x.y - arc.center.y, x.x - arc.center.x)) * s)
            guard abs(arc.sweep) - moved > 1e-9 else { return false }
            arc.sweep -= s * moved
            self = .arc(arc)
        }
        return true
    }

    /// An angle in [-π/2, 3π/2): a trim moves an end forward, or back a little for rounding.
    private static func wrapped(_ a: Double) -> Double {
        Arc2D.positiveAngle(a + .pi / 2) - .pi / 2
    }
}
