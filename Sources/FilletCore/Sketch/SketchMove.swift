import Foundation

/// Dragging sketch shapes with the Select tool: which shapes move, where the press landed, and
/// how the move snaps. The grabbed shape's nearest key point (a vertex, midpoint or centre) is
/// what snaps, to the grid or to the points of the shapes that stay put, so dragging a circle
/// lands its centre on the grid, as drawing would.
///
/// Dragging a vertex (a line's start or end, a polyline's or spline's point) moves only that
/// point, and the vertices of other shapes joined to it, so a chain of lines stays closed.
public struct SketchMove: Hashable, Sendable {
    /// The sketch as it was when the drag began; every step of the drag moves from here.
    public var original: Sketch
    /// The shapes that change: every shape moved whole, or the shapes of the dragged vertices.
    public var shapes: Set<UUID>
    /// The vertices that move, all at `anchor`. Empty when the shapes move whole.
    public var vertices: [SketchVertex]
    /// The other vertices of the dragged vertices' shapes, which stay put: guides line up with them.
    public var fixedVertices: [SIMD2<Double>]
    /// The press on the sketch plane.
    public var press: SIMD2<Double>
    /// The point that snaps.
    public var anchor: SIMD2<Double>

    public init(original: Sketch, shapes: Set<UUID>, vertices: [SketchVertex] = [], fixedVertices: [SIMD2<Double>] = [],
                press: SIMD2<Double>, anchor: SIMD2<Double>)
    {
        self.original = original
        self.shapes = shapes
        self.vertices = vertices
        self.fixedVertices = fixedVertices
        self.press = press
        self.anchor = anchor
    }

    /// A drag of `vertex` and the vertices joined to it, pressed at `press`. Nil when the vertex
    /// doesn't exist or can't be evaluated.
    public init?(original: Sketch, vertex: SketchVertex, press: SIMD2<Double>, using evaluator: Evaluator) {
        guard let shape = original.shape(vertex.shape), shape.vertices.indices.contains(vertex.index),
            let position = try? shape.vertices[vertex.index].evaluate(using: evaluator)
        else { return nil }
        var joined = original.vertices(at: position, using: evaluator)
        if !joined.contains(vertex) { joined.insert(vertex, at: 0) }
        let shapes = Set(joined.map(\.shape))
        let fixed = original.shapes.filter { shapes.contains($0.id) }.flatMap { shape in
            shape.vertices.indices.filter { !joined.contains(SketchVertex(shape: shape.id, index: $0)) }
                .compactMap { try? shape.vertices[$0].evaluate(using: evaluator) }
                .filter { !$0.isClose(to: position, tolerance: 1e-7) }
        }
        self.init(original: original, shapes: shapes, vertices: joined, fixedVertices: fixed, press: press, anchor: position)
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
    /// target, held while the pointer stays near it. A dragged vertex lines up with the other
    /// vertices of its own shapes (a line's other end, for a level or upright line) but doesn't
    /// snap onto them, which would leave a line of no length.
    public func resolve(to raw: SIMD2<Double>, context: SnapContext, previous: SnapTarget? = nil)
        -> (offset: SIMD2<Double>, resolution: SnapResolution)
    {
        var others = context
        others.targets = context.targets.excluding(shapes)
        let resolution = others.resolve(anchor + raw - press, anchors: fixedVertices, previous: previous)
        return (resolution.point - anchor, resolution)
    }

    /// The original sketch with the moving shapes, or the dragged vertices, translated by `offset`.
    public func moved(by offset: SIMD2<Double>, using evaluator: Evaluator) -> Sketch {
        var sketch = original
        for i in sketch.shapes.indices where shapes.contains(sketch.shapes[i].id) {
            if vertices.isEmpty {
                sketch.shapes[i] = sketch.shapes[i].translated(by: offset, using: evaluator)
            } else {
                for v in vertices where v.shape == sketch.shapes[i].id {
                    let p = sketch.shapes[i].vertices[v.index]
                    sketch.shapes[i] = sketch.shapes[i].replacingVertex(v.index, with: p.translated(by: offset, using: evaluator))
                }
            }
        }
        return sketch
    }

    /// Whether dragging the vertices by `offset` lands one on a neighbouring vertex of its shape
    /// (a line of no length), which the drag doesn't allow.
    public func collapses(by offset: SIMD2<Double>, using evaluator: Evaluator) -> Bool {
        guard !vertices.isEmpty else { return false }
        let target = anchor + offset
        for v in vertices {
            guard let shape = original.shape(v.shape) else { continue }
            var neighbours = [v.index - 1, v.index + 1]
            if case .polyline(_, true) = shape.kind { neighbours = neighbours.map { ($0 + shape.vertices.count) % shape.vertices.count } }
            for n in neighbours where n != v.index && shape.vertices.indices.contains(n) {
                if !vertices.contains(SketchVertex(shape: v.shape, index: n)),
                    let p = try? shape.vertices[n].evaluate(using: evaluator), p.isClose(to: target, tolerance: 1e-6)
                {
                    return true
                }
            }
        }
        return false
    }
}

/// A point that defines a shape and can be dragged on its own: `index` into `SketchShape.vertices`.
public struct SketchVertex: Hashable, Sendable {
    public var shape: UUID
    public var index: Int

    public init(shape: UUID, index: Int) {
        self.shape = shape
        self.index = index
    }
}

extension SketchShape {
    /// The points that define this shape and can be dragged one at a time: a line's start and
    /// end, a polyline's vertices, a spline's points. Empty for shapes that keep their form and
    /// only move whole (rectangles, circles, arcs, polygons, slots, points).
    public var vertices: [Point2Expr] {
        switch kind {
        case .line(let a, let b): [a, b]
        case .polyline(let vertices, _): vertices.map(\.point)
        case .spline(let points): points
        default: []
        }
    }

    /// The shape with vertex `index` at `point` (a polyline vertex keeps its bulge).
    public func replacingVertex(_ index: Int, with point: Point2Expr) -> SketchShape {
        var s = self
        switch kind {
        case .line(let a, let b): s.kind = index == 0 ? .line(a: point, b: b) : .line(a: a, b: point)
        case .polyline(var vertices, let closed):
            vertices[index].point = point
            s.kind = .polyline(vertices: vertices, closed: closed)
        case .spline(var points):
            points[index] = point
            s.kind = .spline(points: points)
        default: break
        }
        return s
    }

    /// The vertex at `position`, if there is one.
    public func vertexIndex(at position: SIMD2<Double>, using evaluator: Evaluator) -> Int? {
        vertices.firstIndex { (try? $0.evaluate(using: evaluator))?.isClose(to: position, tolerance: 1e-7) ?? false }
    }
}

extension Sketch {
    /// Every shape's vertex at `position`: shapes drawn end to end (a chain of lines) share them.
    public func vertices(at position: SIMD2<Double>, using evaluator: Evaluator) -> [SketchVertex] {
        shapes.flatMap { shape in
            shape.vertices.indices.filter { (try? shape.vertices[$0].evaluate(using: evaluator))?.isClose(to: position, tolerance: 1e-7) ?? false }
                .map { SketchVertex(shape: shape.id, index: $0) }
        }
    }

    /// The sketch with `shape` in place of the shape with its id. Vertices it moves take the
    /// vertices of other shapes that were joined to them along, as dragging does, so typing a
    /// line's end keeps a chain of lines closed.
    public func replacing(_ shape: SketchShape, using evaluator: Evaluator) -> Sketch {
        guard let i = shapes.firstIndex(where: { $0.id == shape.id }) else { return self }
        var sketch = self
        let old = shapes[i].vertices
        sketch.shapes[i] = shape
        guard old.count == shape.vertices.count else { return sketch }
        for (before, after) in zip(old, shape.vertices) where before != after {
            guard let from = try? before.evaluate(using: evaluator) else { continue }
            for joined in vertices(at: from, using: evaluator) where joined.shape != shape.id {
                guard let j = sketch.shapes.firstIndex(where: { $0.id == joined.shape }) else { continue }
                sketch.shapes[j] = sketch.shapes[j].replacingVertex(joined.index, with: after)
            }
        }
        return sketch
    }

    /// The vertex a picked point of `shape` is (`point` numbered as `SketchShape.snapPoints` numbers
    /// them): a line's start or end is one, its midpoint or a circle's centre isn't.
    public func vertex(shape id: UUID, point: Int, using evaluator: Evaluator) -> SketchVertex? {
        guard let shape = shape(id) else { return nil }
        let points = shape.snapPoints(using: evaluator)
        guard points.indices.contains(point), [.endpoint, .point].contains(points[point].kind),
            let index = shape.vertexIndex(at: points[point].position, using: evaluator)
        else { return nil }
        return SketchVertex(shape: id, index: index)
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
