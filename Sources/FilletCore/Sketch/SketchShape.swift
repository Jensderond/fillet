import Foundation

/// A 2D sketch placed on a plane, made of parametric shapes.
public struct Sketch: Hashable, Sendable, Codable {
    public var plane: SketchPlaneRef
    public var shapes: [SketchShape]

    public init(plane: SketchPlaneRef = .xy, shapes: [SketchShape] = []) {
        self.plane = plane
        self.shapes = shapes
    }

    /// The shape with the given id.
    public func shape(_ id: UUID) -> SketchShape? { shapes.first { $0.id == id } }
}

/// One parametric shape of a sketch.
public struct SketchShape: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// Construction geometry is drawn (dashed) and snappable but never forms profiles.
    public var construction: Bool
    public var kind: SketchShapeKind

    public init(id: UUID = UUID(), construction: Bool = false, _ kind: SketchShapeKind) {
        self.id = id
        self.construction = construction
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, construction, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        construction = try c.decodeIfPresent(Bool.self, forKey: .construction) ?? false
        kind = try c.decode(SketchShapeKind.self, forKey: .kind)
    }
}

/// Which point of a rectangle its `position` refers to.
public enum RectangleAnchor: String, Hashable, Sendable, Codable {
    /// `position` is a corner; the rectangle extends along +width / +height (rotated by `angle`).
    case corner
    /// `position` is the centre.
    case center
}

/// A polyline vertex. `bulge` turns the segment *leaving* this vertex into an
/// arc: it is the signed sagitta in mm (distance from the chord midpoint to
/// the arc), positive bulging to the left of the direction of travel.
public struct PolylineVertex: Hashable, Sendable, Codable {
    public var point: Point2Expr
    public var bulge: Expr?

    public init(_ point: Point2Expr, bulge: Expr? = nil) {
        self.point = point
        self.bulge = bulge
    }

    public init(_ x: Expr, _ y: Expr, bulge: Expr? = nil) {
        self.init(Point2Expr(x, y), bulge: bulge)
    }

    private enum CodingKeys: String, CodingKey { case x, y, bulge }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = Point2Expr(try c.decode(Expr.self, forKey: .x), try c.decode(Expr.self, forKey: .y))
        bulge = try c.decodeIfPresent(Expr.self, forKey: .bulge)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(point.x, forKey: .x)
        try c.encode(point.y, forKey: .y)
        try c.encodeIfPresent(bulge, forKey: .bulge)
    }
}

/// The geometry of a sketch shape. All coordinates and sizes are expressions
/// (lengths in mm, angles in degrees).
public enum SketchShapeKind: Hashable, Sendable, Codable {
    case line(a: Point2Expr, b: Point2Expr)
    /// Connected straight/arc segments; `closed` adds a segment from the last vertex back to the first.
    case polyline(vertices: [PolylineVertex], closed: Bool)
    /// `angle` rotates the rectangle counter-clockwise around `position`.
    case rectangle(anchor: RectangleAnchor, position: Point2Expr, width: Expr, height: Expr, angle: Expr)
    case circle(center: Point2Expr, diameter: Expr)
    /// Arc from `start` through `through` to `end`.
    case arc(start: Point2Expr, through: Point2Expr, end: Point2Expr)
    /// Regular polygon. `inscribed`: vertices lie on the circle of `radius`;
    /// otherwise the edges touch it (circumscribed). The first vertex is at `angle`.
    case polygon(center: Point2Expr, sides: Expr, radius: Expr, inscribed: Bool, angle: Expr)
    /// Stadium shape: two end centres and the total width (= end diameter).
    case slot(a: Point2Expr, b: Point2Expr, width: Expr)
    /// Interpolating spline through the points.
    case spline(points: [Point2Expr])
    case point(Point2Expr)

    /// Name of the case as written in JSON (`"type"`).
    public var typeName: String {
        switch self {
        case .line: "line"
        case .polyline: "polyline"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .arc: "arc"
        case .polygon: "polygon"
        case .slot: "slot"
        case .spline: "spline"
        case .point: "point"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case a, b, vertices, closed, anchor, position, width, height, angle, center, diameter
        case start, through, end, sides, radius, inscribed, points
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func p(_ k: CodingKeys) throws -> Point2Expr { try c.decode(Point2Expr.self, forKey: k) }
        func e(_ k: CodingKeys, default d: Expr? = nil) throws -> Expr {
            if let d { return try c.decodeIfPresent(Expr.self, forKey: k) ?? d }
            return try c.decode(Expr.self, forKey: k)
        }
        switch try decoder.decodeTypeTag() {
        case "line": self = .line(a: try p(.a), b: try p(.b))
        case "polyline":
            self = .polyline(
                vertices: try c.decode([PolylineVertex].self, forKey: .vertices),
                closed: try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false)
        case "rectangle":
            self = .rectangle(
                anchor: try c.decodeIfPresent(RectangleAnchor.self, forKey: .anchor) ?? .corner,
                position: try p(.position), width: try e(.width), height: try e(.height),
                angle: try e(.angle, default: 0))
        case "circle": self = .circle(center: try p(.center), diameter: try e(.diameter))
        case "arc": self = .arc(start: try p(.start), through: try p(.through), end: try p(.end))
        case "polygon":
            self = .polygon(
                center: try p(.center), sides: try e(.sides), radius: try e(.radius),
                inscribed: try c.decodeIfPresent(Bool.self, forKey: .inscribed) ?? true,
                angle: try e(.angle, default: 0))
        case "slot": self = .slot(a: try p(.a), b: try p(.b), width: try e(.width))
        case "spline": self = .spline(points: try c.decode([Point2Expr].self, forKey: .points))
        case "point": self = .point(try p(.position))
        case let other:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown sketch shape type '\(other)'"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encodeTagged(typeName)
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .line(let a, let b):
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        case .polyline(let vertices, let closed):
            try c.encode(vertices, forKey: .vertices)
            try c.encode(closed, forKey: .closed)
        case .rectangle(let anchor, let position, let width, let height, let angle):
            try c.encode(anchor, forKey: .anchor)
            try c.encode(position, forKey: .position)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(angle, forKey: .angle)
        case .circle(let center, let diameter):
            try c.encode(center, forKey: .center)
            try c.encode(diameter, forKey: .diameter)
        case .arc(let start, let through, let end):
            try c.encode(start, forKey: .start)
            try c.encode(through, forKey: .through)
            try c.encode(end, forKey: .end)
        case .polygon(let center, let sides, let radius, let inscribed, let angle):
            try c.encode(center, forKey: .center)
            try c.encode(sides, forKey: .sides)
            try c.encode(radius, forKey: .radius)
            try c.encode(inscribed, forKey: .inscribed)
            try c.encode(angle, forKey: .angle)
        case .slot(let a, let b, let width):
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
            try c.encode(width, forKey: .width)
        case .spline(let points):
            try c.encode(points, forKey: .points)
        case .point(let p):
            try c.encode(p, forKey: .position)
        }
    }
}
