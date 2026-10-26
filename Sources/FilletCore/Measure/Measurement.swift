import FilletKernel
import Foundation

/// Something Measure can pick on a body: the whole body, or one face, edge or vertex of it
/// (indices as in `Shape`, valid for that exact shape).
public enum MeasureElement: Hashable, Sendable {
    case body
    case face(Int)
    case edge(Int)
    case vertex(Int)
}

/// What Measure reports for one picked thing, like Fusion's Inspect > Measure: an edge's length
/// (and radius when it's circular), a face's area (and radius when it's cylindrical or spherical),
/// a body's volume and bounding size, a vertex's position. Lengths in mm, areas in mm², volumes in mm³.
public struct ItemMeasurement: Hashable, Sendable {
    public var element: MeasureElement
    public var curve: CurveType?
    public var surface: SurfaceType?
    public var length: Double?
    public var radius: Double?
    public var area: Double?
    public var volume: Double?
    /// Width, depth and height of the body's bounding box.
    public var size: Vec3?
    public var position: Vec3?

    public init(element: MeasureElement) { self.element = element }
}

/// What Measure reports between two picked things: the minimum distance with the closest points
/// on each, and the angle when both are flat faces or straight edges.
public struct PairMeasurement: Hashable, Sendable {
    public var distance: Double
    public var pointA: Vec3
    public var pointB: Vec3
    /// Radians: 0…π/2 when an edge is involved, between the outward normals (0…π) for two faces.
    public var angle: Double?

    public init(distance: Double, pointA: Vec3, pointB: Vec3, angle: Double? = nil) {
        self.distance = distance; self.pointA = pointA; self.pointB = pointB; self.angle = angle
    }

    /// From the first closest point to the second, along X, Y and Z.
    public var delta: Vec3 { pointB - pointA }
}

/// The measurements behind the Measure tool (and the agents' `measure` tool). Transient: nothing
/// here touches the document.
public enum Measure {
    /// Measurements of one element of a body's shape; nil when the index doesn't exist.
    public static func item(_ shape: Shape, _ element: MeasureElement) -> ItemMeasurement? {
        var m = ItemMeasurement(element: element)
        switch element {
        case .body:
            guard let b = shape.bounds else { return nil }
            m.volume = shape.volume
            m.size = b.max - b.min
        case .face(let i):
            guard let info = shape.faceInfoIfValid(i) else { return nil }
            m.surface = info.surface
            m.area = info.area
            m.radius = shape.faceRadius(i)
        case .edge(let i):
            guard let info = shape.edgeInfoIfValid(i) else { return nil }
            m.curve = info.curve
            m.length = info.length
            if info.curve == .circle { m.radius = info.radius }
        case .vertex(let i):
            guard let p = shape.vertexPoint(i) else { return nil }
            m.position = p
        }
        return m
    }

    /// Minimum distance (and angle, where one exists) between two elements, on the same body or
    /// on two. nil when either doesn't exist or the kernel can't measure them.
    public static func pair(_ a: (shape: Shape, element: MeasureElement), _ b: (shape: Shape, element: MeasureElement)) -> PairMeasurement? {
        guard let sa = subshape(a.shape, a.element), let sb = subshape(b.shape, b.element),
            let d = sa.distance(to: sb)
        else { return nil }
        return PairMeasurement(distance: d.distance, pointA: d.pointA, pointB: d.pointB, angle: try? sa.angle(to: sb))
    }

    /// The element as a standalone shape (the body itself for `.body`).
    public static func subshape(_ shape: Shape, _ element: MeasureElement) -> Shape? {
        switch element {
        case .body: shape
        case .face(let i): try? shape.face(i)
        case .edge(let i): try? shape.edge(i)
        case .vertex(let i): try? shape.vertex(i)
        }
    }
}
