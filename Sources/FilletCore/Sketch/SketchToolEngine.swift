import FilletKernel
import Foundation

/// A drawing tool in sketch mode.
public enum SketchTool: String, CaseIterable, Hashable, Sendable {
    case select, line, rectangle, centerRectangle, circle, arc, polygon, slot, spline, point

    public var title: String {
        switch self {
        case .select: "Select"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .centerRectangle: "Center Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .polygon: "Polygon"
        case .slot: "Slot"
        case .spline: "Spline"
        case .point: "Point"
        }
    }

    /// Hint shown while the tool is active, given how many points are placed. `verb` is the
    /// platform's pointing word: "Tap" on iPad, "Click" with a pointer.
    public func hint(placed: Int, verb: String = "Tap") -> String {
        switch (self, placed) {
        case (.select, _): "\(verb) shapes to select them, drag to move them"
        case (.line, 0): "\(verb) or drag to start a line"
        case (.line, _): "\(verb) the next point. Done or the first point ends the line"
        case (.rectangle, 0): "\(verb) or drag from the first corner"
        case (.rectangle, _): "\(verb) the opposite corner"
        case (.centerRectangle, 0): "\(verb) the center"
        case (.centerRectangle, _): "\(verb) a corner"
        case (.circle, 0): "\(verb) the center"
        case (.circle, _): "\(verb) a point on the circle"
        case (.arc, 0): "\(verb) the start point"
        case (.arc, 1): "\(verb) the end point"
        case (.arc, _): "\(verb) a point the arc passes through"
        case (.polygon, 0): "\(verb) the center"
        case (.polygon, _): "\(verb) a corner"
        case (.slot, 0): "\(verb) the center of one end"
        case (.slot, 1): "\(verb) the center of the other end"
        case (.slot, _): "\(verb) to set the width"
        case (.spline, 0): "\(verb) the first point"
        case (.spline, _): "\(verb) more points, then Done"
        case (.point, _): "\(verb) to place a point"
        }
    }
}

/// A size of the shape in progress that can be typed while drawing (Tab, then a number).
public struct DimensionField: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case width, height, diameter, radius, length
        /// Degrees counterclockwise from the sketch's +X axis.
        case angle
    }
    public var kind: Kind
    /// The typed value while locked, otherwise the value under the cursor (mm or degrees).
    public var value: Double
    public var locked: Bool

    public var title: String {
        switch kind {
        case .width: "Width"
        case .height: "Height"
        case .diameter: "Diameter"
        case .radius: "Radius"
        case .length: "Length"
        case .angle: "Angle"
        }
    }
}

/// What the cursor snapped to, for on-screen feedback.
public enum SketchSnap: Hashable, Sendable {
    case grid
    case point(SnapKind)
    /// Horizontal/vertical alignment with the previous point.
    case horizontal, vertical
    case none
}

/// Snap targets and tolerance for one input event.
public struct SnapContext: Sendable {
    public var points: [SnapPoint]
    /// Snap radius in millimetres (derived from the on-screen size).
    public var tolerance: Double
    public var gridSize: Double
    public init(points: [SnapPoint], tolerance: Double, gridSize: Double) {
        self.points = points; self.tolerance = tolerance; self.gridSize = gridSize
    }

    /// Snaps `raw` to the nearest snap point within the tolerance (endpoints, centres and
    /// points before midpoints and quadrants), otherwise to the grid (or to 0.01 mm with the
    /// grid off). `extra` adds candidates; `gridStep` overrides the grid step (half steps for
    /// centre-based sizes).
    public func snap(_ raw: SIMD2<Double>, extra: [(SIMD2<Double>, SnapKind)] = [], gridStep: Double? = nil)
        -> (point: SIMD2<Double>, snap: SketchSnap)
    {
        func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let d = a - b
            return (d.x * d.x + d.y * d.y).squareRoot()
        }
        let candidates = points.map { ($0.position, $0.kind) } + extra
        let rank: [SnapKind: Int] = [.endpoint: 0, .center: 0, .point: 0, .midpoint: 1, .quadrant: 1]
        if let best = candidates
            .filter({ distance($0.0, raw) <= tolerance })
            .min(by: { (rank[$0.1] ?? 2, distance($0.0, raw)) < (rank[$1.1] ?? 2, distance($1.0, raw)) })
        {
            return (best.0, .point(best.1))
        }
        if gridSize > 0 {
            let step = gridStep ?? gridSize
            return ((raw / step).rounded(.toNearestOrAwayFromZero) * step, .grid)
        }
        return ((raw * 100).rounded(.toNearestOrAwayFromZero) / 100, .none)
    }
}

/// Turns presses, drags and taps on the sketch plane into sketch shapes.
///
/// Every gesture is press → drag* → release. A release far from its press
/// counts as a drag (e.g. corner-to-corner rectangle); otherwise it is a tap
/// that places one point. Tools that need more points wait for more taps.
public struct SketchToolEngine: Sendable {
    public private(set) var tool: SketchTool = .line
    public var construction = false
    public var polygonSides = 6
    /// Placed points of the shape in progress.
    public private(set) var points: [SIMD2<Double>] = []
    /// The snapped cursor position, if the pointer is over the plane, moved to honour typed sizes.
    public private(set) var cursor: SIMD2<Double>?
    /// The snapped cursor before typed sizes move it.
    private var freeCursor: SIMD2<Double>?
    /// Typed sizes of the shape in progress by field index (see `dimensionFields`). They hold
    /// while the cursor moves; the cursor still picks the free sizes and the direction.
    public private(set) var locks: [Int: Double] = [:]
    public private(set) var snap: SketchSnap = .none
    /// Start of the current line chain (to detect closing it).
    private var chainStart: SIMD2<Double>?
    private var pressPoint: SIMD2<Double>?
    /// Grid step of the last input event (0 = off), used to snap sizes as well as points.
    private var grid: Double = 0

    public init(tool: SketchTool = .line) { self.tool = tool }

    public mutating func setTool(_ tool: SketchTool) {
        self.tool = tool
        cancel()
    }

    /// Drops the shape in progress.
    public mutating func cancel() {
        points = []
        locks = [:]
        chainStart = nil
        pressPoint = nil
    }

    public var hint: String { tool.hint(placed: points.count) }
    public func hint(verb: String) -> String { tool.hint(placed: points.count, verb: verb) }
    public var isIdle: Bool { points.isEmpty }

    // MARK: Input

    public mutating func hover(_ raw: SIMD2<Double>, context: SnapContext) {
        track(raw, context)
    }

    public mutating func press(_ raw: SIMD2<Double>, context: SnapContext) {
        pressPoint = track(raw, context)
    }

    public mutating func drag(_ raw: SIMD2<Double>, context: SnapContext) {
        track(raw, context)
        // A drag from an empty state starts the shape at the press point.
        if let start = pressPoint, points.isEmpty, let c = cursor, distance(start, c) > context.tolerance,
            [.line, .rectangle, .centerRectangle, .circle, .polygon].contains(tool)
        {
            points = [start]
            if tool == .line { chainStart = start }
        }
    }

    /// Ends a gesture; returns any shapes it completed.
    public mutating func release(_ raw: SIMD2<Double>, context: SnapContext) -> [SketchShape] {
        let p = track(raw, context)
        pressPoint = nil
        return place(p, tolerance: context.tolerance)
    }

    // MARK: Typed sizes

    /// The sizes that can be typed for the shape in progress, in Tab order.
    public var dimensionKinds: [DimensionField.Kind] {
        guard !points.isEmpty else { return [] }
        switch tool {
        case .rectangle, .centerRectangle: return [.width, .height]
        case .circle: return [.diameter]
        case .polygon: return [.radius]
        case .line: return [.length, .angle]
        case .arc, .slot: return points.count == 1 ? [.length] : []
        case .select, .point, .spline: return []
        }
    }

    /// Each typeable size with its live (or locked) value.
    public func dimensionFields() -> [DimensionField] {
        guard let anchor = points.last else { return [] }
        let values = measure(cursor ?? anchor)
        return zip(dimensionKinds, values).enumerated().map { i, field in
            DimensionField(kind: field.0, value: locks[i] ?? field.1, locked: locks[i] != nil)
        }
    }

    /// Holds a size at `value` (mm, or degrees for an angle). Lengths must be positive.
    @discardableResult
    public mutating func lock(_ field: Int, to value: Double) -> Bool {
        let kinds = dimensionKinds
        guard kinds.indices.contains(field), value.isFinite, kinds[field] == .angle || value > 1e-6 else { return false }
        locks[field] = value
        if let free = freeCursor { cursor = constrained(free) }
        return true
    }

    public mutating func unlock(_ field: Int) {
        locks[field] = nil
        if let free = freeCursor { cursor = constrained(free) }
    }

    /// Places the next point where the typed sizes put it (Return), taking any free size and
    /// the direction from the cursor. Does nothing while the free sizes are still zero.
    public mutating func placeTyped() -> [SketchShape] {
        guard let anchor = points.last else { return [] }
        let p = constrained(freeCursor ?? anchor)
        switch tool {
        case .rectangle, .centerRectangle, .circle, .polygon:
            guard shape(from: points[0], to: p) != nil else { return [] }
        default:
            guard distance(anchor, p) > 1e-9 else { return [] }
        }
        cursor = p
        return place(p, tolerance: 0)
    }

    /// Moves a cursor position so the shape gets the locked sizes; it keeps the side of the
    /// anchor the cursor is on, and the cursor's distance for sizes that aren't locked.
    private func constrained(_ c: SIMD2<Double>) -> SIMD2<Double> {
        guard let first = points.first, !locks.isEmpty else { return c }
        func side(_ v: Double) -> Double { v < 0 ? -1 : 1 }
        func direction(from a: SIMD2<Double>) -> SIMD2<Double> {
            distance(a, c) > 1e-9 ? (c - a) / distance(a, c) : SIMD2(1, 0)
        }
        var d = c - first
        switch tool {
        case .rectangle:
            if let w = locks[0] { d.x = side(d.x) * w }
            if let h = locks[1] { d.y = side(d.y) * h }
            return first + d
        case .centerRectangle:
            if let w = locks[0] { d.x = side(d.x) * w / 2 }
            if let h = locks[1] { d.y = side(d.y) * h / 2 }
            return first + d
        case .circle:
            return locks[0].map { first + direction(from: first) * $0 / 2 } ?? c
        case .polygon, .arc, .slot:
            guard tool == .polygon || points.count == 1 else { return c }
            return locks[0].map { first + direction(from: first) * $0 } ?? c
        case .line:
            let last = points[points.count - 1]
            let length = locks[0] ?? distance(last, c)
            let angle = locks[1].map { $0 * .pi / 180 } ?? atan2(c.y - last.y, c.x - last.x)
            return last + SIMD2(cos(angle), sin(angle)) * length
        case .select, .point, .spline:
            return c
        }
    }

    /// The value of each typeable size with the cursor at `c`: the typed value where locked.
    private func measure(_ c: SIMD2<Double>) -> [Double] {
        guard let first = points.first, let last = points.last else { return [] }
        let d = c - first
        switch tool {
        case .rectangle: return [locks[0] ?? abs(d.x), locks[1] ?? abs(d.y)]
        // Snap the size, not the corner, so odd widths (15 mm) are reachable.
        case .centerRectangle: return [locks[0] ?? snapSize(abs(d.x) * 2), locks[1] ?? snapSize(abs(d.y) * 2)]
        case .circle: return [locks[0] ?? snapSize(distance(first, c) * 2)]
        case .polygon: return [locks[0] ?? snapSize(distance(first, c))]
        case .line:
            let angle = atan2(c.y - last.y, c.x - last.x) * 180 / .pi
            return [locks[0] ?? distance(last, c), locks[1] ?? angle]
        case .arc, .slot: return points.count == 1 ? [locks[0] ?? distance(first, c)] : []
        case .select, .point, .spline: return []
        }
    }

    /// Finishes open-ended tools (line chain, spline).
    public mutating func finish() -> [SketchShape] {
        defer { cancel() }
        if tool == .spline, points.count >= 2 {
            return [make(.spline(points: points.map(Self.expr)))]
        }
        return []
    }

    private mutating func place(_ p: SIMD2<Double>, tolerance: Double) -> [SketchShape] {
        if let last = points.last, distance(last, p) < 1e-9 { return [] }  // repeated tap
        // Typed sizes belong to the step they were typed for.
        defer { locks = [:] }
        switch tool {
        case .select:
            return []
        case .point:
            return [make(.point(Self.expr(p)))]
        case .line:
            guard let last = points.last else {
                points = [p]
                chainStart = p
                return []
            }
            let closing = chainStart.map { distance($0, p) <= tolerance } ?? false
            let end = closing ? chainStart! : p
            let line = make(.line(a: Self.expr(last), b: Self.expr(end)))
            if closing {
                cancel()
            } else {
                points = [end]
            }
            return [line]
        case .spline:
            points.append(p)
            return []
        case .rectangle, .centerRectangle, .circle, .polygon:
            guard let first = points.first else {
                points = [p]
                return []
            }
            defer { cancel() }
            return shape(from: first, to: p).map { [make($0)] } ?? []
        case .arc, .slot:
            points.append(p)
            guard points.count == 3 else { return [] }
            defer { cancel() }
            return threePointShape(points[0], points[1], points[2]).map { [make($0)] } ?? []
        }
    }

    // MARK: Preview

    /// Polylines previewing the shape in progress up to the cursor.
    public func preview() -> [[SIMD2<Double>]] {
        guard let c = cursor, !points.isEmpty else { return [] }
        let kind: SketchShapeKind?
        switch tool {
        case .line: kind = .line(a: Self.expr(points[0]), b: Self.expr(c))
        case .spline: kind = .spline(points: (points + [c]).map(Self.expr))
        case .rectangle, .centerRectangle, .circle, .polygon: kind = shape(from: points[0], to: c)
        case .arc, .slot:
            kind = points.count == 1 ? .line(a: Self.expr(points[0]), b: Self.expr(c))
                : threePointShape(points[0], points[1], c)
        case .select, .point: kind = nil
        }
        guard let kind else { return [] }
        return SketchShape(kind).displayPolyline(using: .empty)
    }

    /// A live dimension shown while drawing: from/to in sketch coordinates and its label.
    public struct PreviewDimension: Hashable, Sendable {
        public var from: SIMD2<Double>
        public var to: SIMD2<Double>
        public var label: String
        /// The typeable size it shows (index into `dimensionFields()`).
        public var field: Int?
    }

    /// Dimensions of the shape in progress ("40 × 25" style feedback while drawing).
    public func previewDimensions() -> [PreviewDimension] {
        guard let c = cursor, let first = points.first else { return [] }
        func mm(_ v: Double) -> String {
            let r = (v * 100).rounded() / 100
            return r == r.rounded() ? "\(Int(r)) mm" : String(format: "%.2f mm", r)
        }
        switch tool {
        case .rectangle, .centerRectangle:
            guard case .rectangle(let anchor, let position, let width, let height, _)? = shape(from: first, to: c),
                let p = try? position.evaluate(using: .empty), let w = try? Evaluator.empty.length(width),
                let h = try? Evaluator.empty.length(height)
            else { return [] }
            let origin = anchor == .center ? p - SIMD2(w, h) / 2 : p
            return [
                PreviewDimension(from: origin, to: origin + SIMD2(w, 0), label: mm(w), field: 0),
                PreviewDimension(from: origin + SIMD2(w, 0), to: origin + SIMD2(w, h), label: mm(h), field: 1),
            ]
        case .circle:
            guard case .circle(_, let d)? = shape(from: first, to: c), let diameter = try? Evaluator.empty.length(d) else { return [] }
            let dir = distance(first, c) > 1e-9 ? (c - first) / distance(first, c) : SIMD2(1, 0)
            return [PreviewDimension(from: first - dir * diameter / 2, to: first + dir * diameter / 2, label: "Ø " + mm(diameter), field: 0)]
        case .polygon:
            guard case .polygon(_, _, let r, _, _)? = shape(from: first, to: c), let radius = try? Evaluator.empty.length(r) else { return [] }
            let dir = distance(first, c) > 1e-9 ? (c - first) / distance(first, c) : SIMD2(1, 0)
            return [PreviewDimension(from: first, to: first + dir * radius, label: "R " + mm(radius), field: 0)]
        case .line:
            guard let last = points.last, distance(last, c) > 1e-9 else { return [] }
            // The angle has no line of its own: it sits at the start, where the angle opens.
            let angle = atan2(c.y - last.y, c.x - last.x) * 180 / .pi
            return [
                PreviewDimension(from: last, to: c, label: mm(distance(last, c)), field: 0),
                PreviewDimension(from: last, to: last, label: Self.degrees(angle), field: 1),
            ]
        case .spline:
            guard let last = points.last, distance(last, c) > 1e-9 else { return [] }
            return [PreviewDimension(from: last, to: c, label: mm(distance(last, c)))]
        case .slot, .arc:
            guard points.count == 1 else { return [] }
            return [PreviewDimension(from: first, to: c, label: mm(distance(first, c)), field: 0)]
        case .select, .point:
            return []
        }
    }

    // MARK: Geometry

    private func shape(from a: SIMD2<Double>, to b: SIMD2<Double>) -> SketchShapeKind? {
        let d = b - a
        let size = measure(b)
        switch tool {
        case .rectangle:
            let w = size[0], h = size[1]
            guard w > 1e-6, h > 1e-6 else { return nil }
            return .rectangle(anchor: .corner, position: Self.expr(SIMD2(d.x < 0 ? a.x - w : a.x, d.y < 0 ? a.y - h : a.y)),
                              width: Self.expr(w), height: Self.expr(h), angle: 0)
        case .centerRectangle:
            let w = size[0], h = size[1]
            guard w > 1e-6, h > 1e-6 else { return nil }
            return .rectangle(anchor: .center, position: Self.expr(a), width: Self.expr(w), height: Self.expr(h), angle: 0)
        case .circle:
            let diameter = size[0]
            guard diameter > 1e-6 else { return nil }
            return .circle(center: Self.expr(a), diameter: Self.expr(diameter))
        case .polygon:
            let r = size[0]
            guard r > 1e-6 else { return nil }
            return .polygon(center: Self.expr(a), sides: Expr(integerLiteral: polygonSides), radius: Self.expr(r),
                            inscribed: true, angle: Self.expr(atan2(d.y, d.x) * 180 / .pi))
        default:
            return nil
        }
    }

    private func threePointShape(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> SketchShapeKind? {
        switch tool {
        case .arc:
            // a = start, b = end, c = a point on the arc; reject collinear points.
            let cross = (b - a).x * (c - a).y - (b - a).y * (c - a).x
            guard abs(cross) > 1e-9 else { return nil }
            return .arc(start: Self.expr(a), through: Self.expr(c), end: Self.expr(b))
        case .slot:
            let ab = b - a
            let len = (ab.x * ab.x + ab.y * ab.y).squareRoot()
            guard len > 1e-6 else { return nil }
            let n = SIMD2(-ab.y, ab.x) / len
            let width = abs(((c - a) * n).sum()) * 2
            guard width > 1e-6 else { return nil }
            return .slot(a: Self.expr(a), b: Self.expr(b), width: Self.expr(width))
        default:
            return nil
        }
    }

    /// Rounds a dimension to the grid step (never below one step) when the grid is on.
    private func snapSize(_ v: Double) -> Double {
        guard grid > 0 else { return v }
        return max(grid, (v / grid).rounded() * grid)
    }

    private func make(_ kind: SketchShapeKind) -> SketchShape {
        SketchShape(construction: construction && tool != .point, kind)
    }

    // MARK: Snapping

    /// Snaps an input position, then applies the typed sizes; returns the new cursor.
    @discardableResult
    private mutating func track(_ raw: SIMD2<Double>, _ context: SnapContext) -> SIMD2<Double> {
        let free = snapped(raw, context)
        freeCursor = free
        let p = constrained(free)
        cursor = p
        return p
    }

    private mutating func snapped(_ raw: SIMD2<Double>, _ context: SnapContext) -> SIMD2<Double> {
        grid = context.gridSize
        // 1. Existing geometry (and the chain start, to close a loop), 2. the grid.
        var extra: [(SIMD2<Double>, SnapKind)] = chainStart.map { [($0, .endpoint)] } ?? []
        extra += points.map { ($0, SnapKind.endpoint) }
        // Centre-based sizes (centre rectangle, circle, polygon) need half steps for whole-step sizes.
        let sizing = points.count == 1 && [.centerRectangle, .circle, .polygon].contains(tool)
        let snapped = context.snap(raw, extra: extra, gridStep: sizing ? context.gridSize / 2 : nil)
        var p = snapped.point
        snap = snapped.snap
        if case .point = snap { return p }
        // 3. Horizontal / vertical with the previous point.
        if let last = points.last {
            if abs(raw.y - last.y) <= context.tolerance {
                p.y = last.y
                snap = .horizontal
            } else if abs(raw.x - last.x) <= context.tolerance {
                p.x = last.x
                snap = .vertical
            }
        }
        return p
    }

    private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// "30°", "12.5°": an angle label, rounded to 0.1°.
    static func degrees(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))°" : String(format: "%.1f°", r)
    }

    /// Literal expression rounded to 0.0001 mm.
    static func expr(_ v: Double) -> Expr { Expr((v * 10000).rounded() / 10000) }
    static func expr(_ p: SIMD2<Double>) -> Point2Expr { Point2Expr(expr(p.x), expr(p.y)) }
}
