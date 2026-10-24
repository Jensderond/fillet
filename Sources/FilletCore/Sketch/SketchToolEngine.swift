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

    /// Hint shown while the tool is active, given how many points are placed.
    public func hint(placed: Int) -> String {
        switch (self, placed) {
        case (.select, _): "Tap shapes to select them"
        case (.line, 0): "Tap or drag to start a line"
        case (.line, _): "Tap the next point — tap the first point or Done to finish"
        case (.rectangle, 0): "Drag or tap the first corner"
        case (.rectangle, _): "Tap the opposite corner"
        case (.centerRectangle, 0): "Tap the center"
        case (.centerRectangle, _): "Tap a corner"
        case (.circle, 0): "Tap the center"
        case (.circle, _): "Tap a point on the circle"
        case (.arc, 0): "Tap the start point"
        case (.arc, 1): "Tap the end point"
        case (.arc, _): "Tap a point the arc passes through"
        case (.polygon, 0): "Tap the center"
        case (.polygon, _): "Tap a corner"
        case (.slot, 0): "Tap the first end center"
        case (.slot, 1): "Tap the second end center"
        case (.slot, _): "Tap to set the width"
        case (.spline, 0): "Tap the first point"
        case (.spline, _): "Tap more points — Done to finish"
        case (.point, _): "Tap to place a point"
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
    /// The snapped cursor position, if the pointer is over the plane.
    public private(set) var cursor: SIMD2<Double>?
    public private(set) var snap: SketchSnap = .none
    /// Start of the current line chain (to detect closing it).
    private var chainStart: SIMD2<Double>?
    private var pressPoint: SIMD2<Double>?

    public init(tool: SketchTool = .line) { self.tool = tool }

    public mutating func setTool(_ tool: SketchTool) {
        self.tool = tool
        cancel()
    }

    /// Drops the shape in progress.
    public mutating func cancel() {
        points = []
        chainStart = nil
        pressPoint = nil
    }

    public var hint: String { tool.hint(placed: points.count) }
    public var isIdle: Bool { points.isEmpty }

    // MARK: Input

    public mutating func hover(_ raw: SIMD2<Double>, context: SnapContext) {
        cursor = snapped(raw, context)
    }

    public mutating func press(_ raw: SIMD2<Double>, context: SnapContext) {
        let p = snapped(raw, context)
        cursor = p
        pressPoint = p
    }

    public mutating func drag(_ raw: SIMD2<Double>, context: SnapContext) {
        cursor = snapped(raw, context)
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
        let p = snapped(raw, context)
        cursor = p
        pressPoint = nil
        return place(p, tolerance: context.tolerance)
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

    // MARK: Geometry

    private func shape(from a: SIMD2<Double>, to b: SIMD2<Double>) -> SketchShapeKind? {
        let d = b - a
        switch tool {
        case .rectangle:
            let w = abs(d.x), h = abs(d.y)
            guard w > 1e-6, h > 1e-6 else { return nil }
            return .rectangle(anchor: .corner, position: Self.expr(SIMD2(min(a.x, b.x), min(a.y, b.y))),
                              width: Self.expr(w), height: Self.expr(h), angle: 0)
        case .centerRectangle:
            let w = abs(d.x) * 2, h = abs(d.y) * 2
            guard w > 1e-6, h > 1e-6 else { return nil }
            return .rectangle(anchor: .center, position: Self.expr(a), width: Self.expr(w), height: Self.expr(h), angle: 0)
        case .circle:
            let r = distance(a, b)
            guard r > 1e-6 else { return nil }
            return .circle(center: Self.expr(a), diameter: Self.expr(r * 2))
        case .polygon:
            let r = distance(a, b)
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

    private func make(_ kind: SketchShapeKind) -> SketchShape {
        SketchShape(construction: construction && tool != .point, kind)
    }

    // MARK: Snapping

    private mutating func snapped(_ raw: SIMD2<Double>, _ context: SnapContext) -> SIMD2<Double> {
        // 1. Existing geometry (and the chain start, to close a loop).
        var candidates = context.points.map { ($0.position, $0.kind) }
        if let s = chainStart { candidates.append((s, .endpoint)) }
        candidates += points.map { ($0, SnapKind.endpoint) }
        let rank: [SnapKind: Int] = [.endpoint: 0, .center: 0, .point: 0, .midpoint: 1, .quadrant: 1]
        if let best = candidates
            .filter({ distance($0.0, raw) <= context.tolerance })
            .min(by: { (rank[$0.1] ?? 2, distance($0.0, raw)) < (rank[$1.1] ?? 2, distance($1.0, raw)) })
        {
            snap = .point(best.1)
            return best.0
        }
        // 2. Grid.
        var p = raw
        snap = .none
        if context.gridSize > 0 {
            p = (raw / context.gridSize).rounded(.toNearestOrAwayFromZero) * context.gridSize
            snap = .grid
        } else {
            p = (raw * 100).rounded(.toNearestOrAwayFromZero) / 100
        }
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

    /// Literal expression rounded to 0.0001 mm.
    static func expr(_ v: Double) -> Expr { Expr((v * 10000).rounded() / 10000) }
    static func expr(_ p: SIMD2<Double>) -> Point2Expr { Point2Expr(expr(p.x), expr(p.y)) }
}
