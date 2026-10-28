import Foundation

/// Dragging sketch shapes with the Select tool: which shapes move, where the press landed, and
/// how the move snaps. The grabbed shape's nearest key point (a vertex, midpoint or centre) is
/// what snaps, to the grid or to the points of the shapes that stay put, so dragging a circle
/// lands its centre on the grid, as drawing would.
public struct SketchMove: Hashable, Sendable {
    /// The sketch as it was when the drag began; every step of the drag moves from here.
    public var original: Sketch
    public var shapes: Set<UUID>
    /// The press on the sketch plane.
    public var press: SIMD2<Double>
    /// The point that snaps.
    public var anchor: SIMD2<Double>

    public init(original: Sketch, shapes: Set<UUID>, press: SIMD2<Double>, anchor: SIMD2<Double>) {
        self.original = original
        self.shapes = shapes
        self.press = press
        self.anchor = anchor
    }

    /// A drag of `shapes` grabbed at `press` on `grabbed`. `point` is the index of the grabbed
    /// snap point when the press picked one (as `SketchShape.snapPoints` numbers them).
    public init(original: Sketch, shapes: Set<UUID>, grabbed: UUID, point: Int? = nil, press: SIMD2<Double>,
                using evaluator: Evaluator)
    {
        var anchor = press
        if let shape = original.shape(grabbed) {
            let points = shape.snapPoints(using: evaluator)
            if let point, points.indices.contains(point) {
                anchor = points[point].position
            } else if let nearest = points.filter({ $0.kind != .quadrant })
                .min(by: { planarDistance($0.position, press) < planarDistance($1.position, press) })
            {
                anchor = nearest.position
            }
        }
        self.init(original: original, shapes: shapes, press: press, anchor: anchor)
    }

    /// The snapped offset for the pointer at `raw`, and what the anchor snapped to. The moving
    /// shapes' own points are left out of `context`: a shape can't snap to itself.
    public func offset(to raw: SIMD2<Double>, context: SnapContext) -> (offset: SIMD2<Double>, snap: SketchSnap) {
        let r = resolve(to: raw, context: context)
        return (r.offset, r.resolution.snap)
    }

    /// The snapped offset with the full snap, guides included. `previous` is the last event's
    /// target, held while the pointer stays near it.
    public func resolve(to raw: SIMD2<Double>, context: SnapContext, previous: SnapTarget? = nil)
        -> (offset: SIMD2<Double>, resolution: SnapResolution)
    {
        var others = context
        others.targets = context.targets.excluding(shapes)
        let resolution = others.resolve(anchor + raw - press, previous: previous)
        return (resolution.point - anchor, resolution)
    }

    /// The original sketch with the moving shapes translated by `offset`.
    public func moved(by offset: SIMD2<Double>, using evaluator: Evaluator) -> Sketch {
        var sketch = original
        for i in sketch.shapes.indices where shapes.contains(sketch.shapes[i].id) {
            sketch.shapes[i] = sketch.shapes[i].translated(by: offset, using: evaluator)
        }
        return sketch
    }
}

private func planarDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}

extension SketchShape {
    /// The shape moved by `offset` (mm). Positions move; sizes and angles stay. See
    /// `Expr.offset(by:using:)` for coordinates that use parameters.
    public func translated(by offset: SIMD2<Double>, using evaluator: Evaluator) -> SketchShape {
        func t(_ p: Point2Expr) -> Point2Expr { p.translated(by: offset, using: evaluator) }
        var s = self
        switch kind {
        case .line(let a, let b): s.kind = .line(a: t(a), b: t(b))
        case .polyline(let vertices, let closed):
            s.kind = .polyline(vertices: vertices.map { PolylineVertex(t($0.point), bulge: $0.bulge) }, closed: closed)
        case .rectangle(let anchor, let position, let width, let height, let angle):
            s.kind = .rectangle(anchor: anchor, position: t(position), width: width, height: height, angle: angle)
        case .circle(let center, let diameter): s.kind = .circle(center: t(center), diameter: diameter)
        case .arc(let start, let through, let end): s.kind = .arc(start: t(start), through: t(through), end: t(end))
        case .polygon(let center, let sides, let radius, let inscribed, let angle):
            s.kind = .polygon(center: t(center), sides: sides, radius: radius, inscribed: inscribed, angle: angle)
        case .slot(let a, let b, let width): s.kind = .slot(a: t(a), b: t(b), width: width)
        case .spline(let points): s.kind = .spline(points: points.map(t))
        case .point(let p): s.kind = .point(t(p))
        }
        return s
    }
}

extension Point2Expr {
    /// The point moved by `offset` (mm).
    public func translated(by offset: SIMD2<Double>, using evaluator: Evaluator) -> Point2Expr {
        Point2Expr(x.offset(by: offset.x, using: evaluator), y.offset(by: offset.y, using: evaluator))
    }
}

extension Expr {
    /// This length plus `delta` mm, rounded to 0.0001 mm like drawn coordinates. A plain number
    /// stays a plain number. One that uses parameters keeps them, with the offset added at the
    /// end (`w/2` → `w/2 + 5`); a trailing offset from an earlier move is folded in
    /// (`w/2 + 5` → `w/2 + 8`) rather than piling up.
    public func offset(by delta: Double, using evaluator: Evaluator) -> Expr {
        let delta = (delta * 10000).rounded() / 10000
        guard delta != 0 else { return self }
        if isLiteral, let value = try? evaluator.length(self) {
            return Expr(((value + delta) * 10000).rounded() / 10000)
        }
        let expected = (try? evaluator.length(self)).map { $0 + delta }
        func matches(_ e: Expr) -> Bool {
            guard let expected, let v = try? evaluator.length(e) else { return false }
            return abs(v - expected) < 1e-6
        }
        // Fold into a trailing "+ n" / "- n".
        if let m = source.wholeMatch(of: /(?<head>.*\S)\s+(?<op>[+-])\s+(?<n>\d+(\.\d+)?)/),
            let n = Double(m.n)
        {
            let total = ((m.op == "-" ? -n : n) + delta) * 10000
            let folded = total.rounded() / 10000
            let candidate = folded == 0 ? Expr(String(m.head))
                : Expr("\(m.head) \(folded < 0 ? "-" : "+") \(Expr.format(abs(folded)))")
            if matches(candidate) { return candidate }
        }
        // Addition binds loosest, so appending never regroups the expression.
        return Expr("\(source) \(delta < 0 ? "-" : "+") \(Expr.format(abs(delta)))")
    }
}
