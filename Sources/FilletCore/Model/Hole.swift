import FilletKernel
import Foundation

/// What a hole looks like at the face, like Fusion's hole types.
public enum HoleType: String, Hashable, Sendable, Codable, CaseIterable {
    case simple, counterbore, countersink
}

/// How deep a hole goes.
public enum HoleExtent: String, Hashable, Sendable, Codable, CaseIterable {
    /// `depth` into the body.
    case distance
    /// Out the other side.
    case throughAll
}

/// Holes drilled into a flat face of a body, all the same size (like Fusion's Hole).
///
/// The centres are in the face's plane coordinates (origin at the face centroid, axes as
/// ``Shape/facePlane(_:)`` gives them, like a sketch on that face), so the holes follow the
/// face when an earlier step moves or resizes it.
public struct Hole: Hashable, Sendable, Codable, FeatureReferencing {
    /// The face drilled into; nil until one is picked.
    public var face: FaceRef?
    public var centers: [Point2Expr]
    /// Simple, counterbore or countersink (not `type`: that key names the feature kind in JSON).
    public var holeType: HoleType
    public var diameter: Expr
    public var extent: HoleExtent
    /// Depth of the full-diameter part, from the face (the drill point goes below it).
    public var depth: Expr
    /// Drill point included angle; 0 = flat bottom.
    public var tipAngle: Expr
    public var counterboreDiameter: Expr
    public var counterboreDepth: Expr
    public var countersinkDiameter: Expr
    /// Included angle of the countersink cone.
    public var countersinkAngle: Expr

    /// A standard twist drill's point.
    public static let drillPoint: Expr = 118

    public init(
        face: FaceRef?, centers: [Point2Expr] = [], holeType: HoleType = .simple, diameter: Expr = 5,
        extent: HoleExtent = .distance, depth: Expr = 10, tipAngle: Expr = Hole.drillPoint,
        counterboreDiameter: Expr = 9, counterboreDepth: Expr = 3,
        countersinkDiameter: Expr = 10, countersinkAngle: Expr = 90
    ) {
        self.face = face; self.centers = centers; self.holeType = holeType; self.diameter = diameter
        self.extent = extent; self.depth = depth; self.tipAngle = tipAngle
        self.counterboreDiameter = counterboreDiameter; self.counterboreDepth = counterboreDepth
        self.countersinkDiameter = countersinkDiameter; self.countersinkAngle = countersinkAngle
    }

    public var referencedFeatures: Set<UUID> { face.map { [$0.body.feature] } ?? [] }

    private enum CodingKeys: String, CodingKey {
        case face, centers, holeType, diameter, extent, depth, tipAngle
        case counterboreDiameter, counterboreDepth, countersinkDiameter, countersinkAngle
    }

    /// Everything but the face may be left out (agents write holes by hand); defaults as `init`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Hole(face: nil)
        face = try c.decodeIfPresent(FaceRef.self, forKey: .face)
        centers = try c.decodeIfPresent([Point2Expr].self, forKey: .centers) ?? []
        holeType = try c.decodeIfPresent(HoleType.self, forKey: .holeType) ?? d.holeType
        diameter = try c.decodeIfPresent(Expr.self, forKey: .diameter) ?? d.diameter
        extent = try c.decodeIfPresent(HoleExtent.self, forKey: .extent) ?? d.extent
        depth = try c.decodeIfPresent(Expr.self, forKey: .depth) ?? d.depth
        tipAngle = try c.decodeIfPresent(Expr.self, forKey: .tipAngle) ?? d.tipAngle
        counterboreDiameter = try c.decodeIfPresent(Expr.self, forKey: .counterboreDiameter) ?? d.counterboreDiameter
        counterboreDepth = try c.decodeIfPresent(Expr.self, forKey: .counterboreDepth) ?? d.counterboreDepth
        countersinkDiameter = try c.decodeIfPresent(Expr.self, forKey: .countersinkDiameter) ?? d.countersinkDiameter
        countersinkAngle = try c.decodeIfPresent(Expr.self, forKey: .countersinkAngle) ?? d.countersinkAngle
    }

    /// The kernel's hole size, with the expressions evaluated.
    public func spec(using ev: Evaluator) throws -> HoleSpec {
        let head: HoleSpec.Head = switch holeType {
        case .simple: .simple
        case .counterbore: .counterbore(diameter: try ev.length(counterboreDiameter), depth: try ev.length(counterboreDepth))
        case .countersink: .countersink(diameter: try ev.length(countersinkDiameter), angle: try ev.angleRadians(countersinkAngle))
        }
        let depth = extent == .throughAll ? nil : try ev.length(depth)
        if let depth, depth <= 0 { throw FeatureError("Depth must be greater than zero") }
        return HoleSpec(diameter: try ev.length(diameter), depth: depth, tipAngle: try ev.angleRadians(tipAngle), head: head)
    }

    /// The face on `shape` (the body before the holes): its index, how it was found, and its plane.
    public func resolveFace(on shape: Shape) throws -> (index: Int, found: ResolvedReference, plane: Plane) {
        guard let face else { throw FeatureError("Pick a flat face to drill into") }
        let infos = shape.faceInfos
        guard let m = ReferenceResolver.match(face.signature, in: infos) else {
            throw FeatureError("The hole face can no longer be found — reselect it")
        }
        let found = ResolvedReference(m, offset: face.signature.centroid.distance(to: infos[m.index].centroid))
        guard let plane = shape.facePlane(m.index) else { throw FeatureError("Holes need a flat face") }
        return (m.index, found, plane)
    }

    /// The centres in world coordinates on `plane` (the face's plane).
    public func worldCenters(on plane: Plane, using ev: Evaluator) throws -> [Vec3] {
        try centers.map { plane.point(try $0.evaluate(using: ev)) }
    }

    /// Drills the holes into `shape` (the body before them), whose face lies on `plane`.
    public func drilled(_ shape: Shape, plane: Plane, using ev: Evaluator) throws -> Shape {
        guard !centers.isEmpty else { throw FeatureError("Place at least one hole on the face") }
        let spec = try spec(using: ev)
        return try shape.drilled(at: try worldCenters(on: plane, using: ev), direction: -plane.normal, spec)
    }
}
