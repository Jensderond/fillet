import FilletKernel
import Foundation

/// Payloads that reference other features (sketches or bodies).
public protocol FeatureReferencing {
    /// Ids of the features this payload directly depends on.
    var referencedFeatures: Set<UUID> { get }
}

extension Set where Element == BodyRef {
    var featureIDs: Set<UUID> { Set<UUID>(map(\.feature)) }
}

/// Linear extrusion of sketch regions.
public struct Extrude: Hashable, Sendable, Codable, FeatureReferencing {
    public var sketch: UUID
    public var regions: [RegionRef]
    /// Distance along the sketch normal (negative = opposite direction).
    public var distance: Expr
    /// Optional second distance in the opposite direction ("two sides").
    public var back: Expr?
    /// Extrude `distance / 2` to each side. Ignores `back`.
    public var symmetric: Bool
    /// Draft angle; 0 for a straight extrusion.
    public var taper: Expr
    public var operation: Operation
    /// Bodies to join/cut/intersect; empty = all bodies the result touches.
    public var targets: [BodyRef]

    public init(
        sketch: UUID, regions: [RegionRef], distance: Expr, back: Expr? = nil, symmetric: Bool = false,
        taper: Expr = 0, operation: Operation = .newBody, targets: [BodyRef] = []
    ) {
        self.sketch = sketch; self.regions = regions; self.distance = distance; self.back = back
        self.symmetric = symmetric; self.taper = taper; self.operation = operation; self.targets = targets
    }

    public var referencedFeatures: Set<UUID> { Set(targets.map(\.feature)).union([sketch]) }
}

/// Axis of a revolve, in sketch terms.
public enum RevolveAxis: Hashable, Sendable, Codable {
    /// The sketch's horizontal (u) axis.
    case x
    /// The sketch's vertical (v) axis.
    case y
    /// A line shape of the same sketch (usually construction).
    case sketchLine(UUID)

    private enum CodingKeys: String, CodingKey { case shape }

    public init(from decoder: Decoder) throws {
        switch try decoder.decodeTypeTag() {
        case "x": self = .x
        case "y": self = .y
        case "sketchLine": self = .sketchLine(try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .shape))
        case let other:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown revolve axis '\(other)'"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .x: try encoder.encodeTagged("x")
        case .y: try encoder.encodeTagged("y")
        case .sketchLine(let id):
            try encoder.encodeTagged("sketchLine")
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .shape)
        }
    }
}

/// Revolution of sketch regions around an axis.
public struct Revolve: Hashable, Sendable, Codable, FeatureReferencing {
    public var sketch: UUID
    public var regions: [RegionRef]
    public var axis: RevolveAxis
    /// Sweep angle; 360 for a full revolution.
    public var angle: Expr
    public var operation: Operation
    public var targets: [BodyRef]

    public init(
        sketch: UUID, regions: [RegionRef], axis: RevolveAxis, angle: Expr = 360,
        operation: Operation = .newBody, targets: [BodyRef] = []
    ) {
        self.sketch = sketch; self.regions = regions; self.axis = axis; self.angle = angle
        self.operation = operation; self.targets = targets
    }

    public var referencedFeatures: Set<UUID> { Set(targets.map(\.feature)).union([sketch]) }
}

/// Fillet or chamfer of body edges.
public struct EdgeFeature: Hashable, Sendable, Codable, FeatureReferencing {
    public var body: BodyRef
    public var edges: [EdgeRef]
    /// Fillet radius or chamfer distance.
    public var size: Expr

    public init(body: BodyRef, edges: [EdgeRef], size: Expr) {
        self.body = body; self.edges = edges; self.size = size
    }

    public var referencedFeatures: Set<UUID> { Set(edges.map(\.body.feature)).union([body.feature]) }
}

/// Hollows a body, opening the given faces.
public struct Shell: Hashable, Sendable, Codable, FeatureReferencing {
    public var body: BodyRef
    public var removeFaces: [FaceRef]
    /// Wall thickness (inward).
    public var thickness: Expr

    public init(body: BodyRef, removeFaces: [FaceRef], thickness: Expr) {
        self.body = body; self.removeFaces = removeFaces; self.thickness = thickness
    }

    public var referencedFeatures: Set<UUID> { Set(removeFaces.map(\.body.feature)).union([body.feature]) }
}

/// Kind of a primitive solid.
public enum PrimitiveKind: String, Hashable, Sendable, Codable, CaseIterable {
    case box, cylinder, sphere, cone, torus

    /// Meaning of ``Primitive/dimensions`` for this kind, in order.
    public var dimensionNames: [String] {
        switch self {
        case .box: ["width", "depth", "height"]
        case .cylinder: ["diameter", "height"]
        case .sphere: ["diameter"]
        case .cone: ["bottom diameter", "top diameter", "height"]
        case .torus: ["major diameter", "minor diameter"]
        }
    }
}

/// A primitive solid placed on a plane.
public struct Primitive: Hashable, Sendable, Codable, FeatureReferencing {
    public var kind: PrimitiveKind
    public var plane: SketchPlaneRef
    /// Placement point in plane coordinates (box: corner; others: centre of the base).
    public var position: Point2Expr
    /// Dimensions as listed by ``PrimitiveKind/dimensionNames``.
    public var dimensions: [Expr]
    public var operation: Operation
    public var targets: [BodyRef]

    public init(
        kind: PrimitiveKind, plane: SketchPlaneRef = .xy, position: Point2Expr = .origin, dimensions: [Expr],
        operation: Operation = .newBody, targets: [BodyRef] = []
    ) {
        self.kind = kind; self.plane = plane; self.position = position; self.dimensions = dimensions
        self.operation = operation; self.targets = targets
    }

    public var referencedFeatures: Set<UUID> {
        Set(targets.map(\.feature)).union(plane.referencedBodies.featureIDs)
    }
}

/// Boolean combination of existing bodies.
public struct Combine: Hashable, Sendable, Codable, FeatureReferencing {
    public var target: BodyRef
    public var tools: [BodyRef]
    /// `.join`, `.cut` or `.intersect` (`.newBody` is treated as join).
    public var operation: Operation
    /// Keep the tool bodies instead of consuming them.
    public var keepTools: Bool

    public init(target: BodyRef, tools: [BodyRef], operation: Operation = .join, keepTools: Bool = false) {
        self.target = target; self.tools = tools; self.operation = operation; self.keepTools = keepTools
    }

    public var referencedFeatures: Set<UUID> { Set(tools.map(\.feature)).union([target.feature]) }
}

/// Rigid move of bodies: rotation about an axis, then translation.
public struct Move: Hashable, Sendable, Codable, FeatureReferencing {
    public var bodies: [BodyRef]
    public var translation: Vec3Expr
    public var rotationAxis: AxisRef
    public var rotationAngle: Expr
    /// Point a world rotation axis (x, y, z) passes through; nil = the origin. Edge axes ignore it.
    public var rotationCenter: Vec3Expr?

    public init(
        bodies: [BodyRef], translation: Vec3Expr = .zero, rotationAxis: AxisRef = .z, rotationAngle: Expr = 0,
        rotationCenter: Vec3Expr? = nil
    ) {
        self.bodies = bodies; self.translation = translation
        self.rotationAxis = rotationAxis; self.rotationAngle = rotationAngle; self.rotationCenter = rotationCenter
    }

    public var referencedFeatures: Set<UUID> {
        Set(bodies.map(\.feature)).union(rotationAxis.referencedBodies.featureIDs)
    }
}

/// Non-uniform scale of bodies about a centre point (squashes a sphere into an ellipsoid),
/// optionally along turned directions (squashes a tilted disc across its tilt).
public struct Scale: Hashable, Sendable, Codable, FeatureReferencing {
    public var bodies: [BodyRef]
    /// Factors along X, Y and Z (plain numbers; 1 = unchanged), or along the turned axes when
    /// `orientation` is set.
    public var factors: Vec3Expr
    /// Point that stays put.
    public var center: Vec3Expr
    /// Turns the directions the factors apply along; nil = the world axes. Left out of files when nil.
    public var orientation: Orientation?

    /// The X, Y and Z axes turned by `angle` degrees about `axis` (a direction; the turn is
    /// about the centre).
    public struct Orientation: Hashable, Sendable, Codable {
        public var axis: Vec3Expr
        public var angle: Expr

        public init(axis: Vec3Expr, angle: Expr) {
            self.axis = axis; self.angle = angle
        }
    }

    public init(bodies: [BodyRef], factors: Vec3Expr = Vec3Expr(1, 1, 1), center: Vec3Expr = .zero, orientation: Orientation? = nil) {
        self.bodies = bodies; self.factors = factors; self.center = center; self.orientation = orientation
    }

    public var referencedFeatures: Set<UUID> { Set(bodies.map(\.feature)) }
}

/// A solid skinned through cross-sections placed in space: tapering horns, curled hat tips,
/// limbs. Each section is an ellipse (or circle) facing along its `normal`.
public struct Loft: Hashable, Sendable, Codable, FeatureReferencing {
    public struct Section: Hashable, Sendable, Codable {
        public var center: Vec3Expr
        /// Direction the loft passes through the section.
        public var normal: Vec3Expr
        /// Size across the section; 0 makes the loft end in a point (first or last section only).
        public var width: Expr
        /// Second size, for an ellipse; nil = a circle of diameter `width`.
        public var height: Expr?
        /// Turns the width direction around the normal, in degrees.
        public var angle: Expr?

        public init(center: Vec3Expr, normal: Vec3Expr = Vec3Expr(0, 0, 1), width: Expr, height: Expr? = nil, angle: Expr? = nil) {
            self.center = center; self.normal = normal; self.width = width; self.height = height; self.angle = angle
        }
    }

    public var sections: [Section]
    /// Straight between sections instead of one smooth surface.
    public var ruled: Bool
    public var operation: Operation
    public var targets: [BodyRef]

    public init(sections: [Section], ruled: Bool = false, operation: Operation = .newBody, targets: [BodyRef] = []) {
        self.sections = sections; self.ruled = ruled; self.operation = operation; self.targets = targets
    }

    public var referencedFeatures: Set<UUID> { Set(targets.map(\.feature)) }
}

/// Mirror copy of bodies across a plane.
public struct Mirror: Hashable, Sendable, Codable, FeatureReferencing {
    public var bodies: [BodyRef]
    public var plane: SketchPlaneRef
    /// Fuse each mirrored copy with its original.
    public var merge: Bool

    public init(bodies: [BodyRef], plane: SketchPlaneRef, merge: Bool = true) {
        self.bodies = bodies; self.plane = plane; self.merge = merge
    }

    public var referencedFeatures: Set<UUID> {
        Set(bodies.map(\.feature)).union(plane.referencedBodies.featureIDs)
    }
}

/// Arrangement of a pattern.
public enum PatternLayout: Hashable, Sendable, Codable {
    /// `count` copies (including the original) `spacing` apart along `direction`.
    case linear(direction: AxisRef, count: Expr, spacing: Expr)
    /// `count` copies (including the original) spread over `angle` around `axis`.
    case circular(axis: AxisRef, count: Expr, angle: Expr)

    var axis: AxisRef {
        switch self {
        case .linear(let a, _, _), .circular(let a, _, _): a
        }
    }

    private enum CodingKeys: String, CodingKey { case direction, axis, count, spacing, angle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try decoder.decodeTypeTag() {
        case "circular":
            self = .circular(
                axis: try c.decode(AxisRef.self, forKey: .axis), count: try c.decode(Expr.self, forKey: .count),
                angle: try c.decodeIfPresent(Expr.self, forKey: .angle) ?? 360)
        default:
            self = .linear(
                direction: try c.decode(AxisRef.self, forKey: .direction), count: try c.decode(Expr.self, forKey: .count),
                spacing: try c.decode(Expr.self, forKey: .spacing))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let d, let n, let s):
            try encoder.encodeTagged("linear")
            try c.encode(d, forKey: .direction)
            try c.encode(n, forKey: .count)
            try c.encode(s, forKey: .spacing)
        case .circular(let a, let n, let angle):
            try encoder.encodeTagged("circular")
            try c.encode(a, forKey: .axis)
            try c.encode(n, forKey: .count)
            try c.encode(angle, forKey: .angle)
        }
    }
}

/// Repeats bodies in a linear or circular pattern (copies are fused with the originals).
public struct Pattern: Hashable, Sendable, Codable, FeatureReferencing {
    public var bodies: [BodyRef]
    public var layout: PatternLayout

    public init(bodies: [BodyRef], layout: PatternLayout) {
        self.bodies = bodies; self.layout = layout
    }

    public var referencedFeatures: Set<UUID> {
        Set(bodies.map(\.feature)).union(layout.axis.referencedBodies.featureIDs)
    }
}

/// A body imported from a STEP file, stored as an OCCT BRep string so the
/// document stays self-contained.
public struct ImportedSTEP: Hashable, Sendable, Codable, FeatureReferencing {
    /// Original file name, for display.
    public var name: String
    public var brep: String

    public init(name: String, brep: String) { self.name = name; self.brep = brep }

    public var referencedFeatures: Set<UUID> { [] }
}

/// Print-orientation helper: rotates a body so the given planar face lies on the bed (z = 0).
public struct LayFlat: Hashable, Sendable, Codable, FeatureReferencing {
    public var body: BodyRef
    public var face: FaceRef

    public init(body: BodyRef, face: FaceRef) { self.body = body; self.face = face }

    public var referencedFeatures: Set<UUID> { [body.feature, face.body.feature] }
}
