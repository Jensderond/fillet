import FilletKernel
import Foundation

/// A solid body, identified by the id of the feature that created it.
/// Join/cut/intersect features modify their target bodies in place, so the
/// id stays stable. Encodes as a plain UUID string.
public struct BodyRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var feature: UUID

    public init(_ feature: UUID) { self.feature = feature }

    public init(from decoder: Decoder) throws {
        feature = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(feature)
    }

    public var description: String { "body(\(feature.uuidString.prefix(8)))" }

    /// Whether `step` makes this body: its first body has the step's id, extra bodies (a pattern's
    /// copies, a split) an id that differs only in the last three bytes (see `ModelEvaluator.derivedRef`).
    public func isMade(by step: UUID) -> Bool {
        let a = feature.uuid, b = step.uuid
        return a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 && a.4 == b.4 && a.5 == b.5 && a.6 == b.6
            && a.7 == b.7 && a.8 == b.8 && a.9 == b.9 && a.10 == b.10 && a.11 == b.11 && a.12 == b.12
    }
}

/// A persistent reference to a face of a body, re-found on recompute by signature.
public struct FaceRef: Hashable, Sendable, Codable {
    public var body: BodyRef
    public var signature: FaceSignature

    public init(body: BodyRef, signature: FaceSignature) {
        self.body = body
        self.signature = signature
    }
}

/// A persistent reference to an edge of a body, re-found on recompute by signature.
public struct EdgeRef: Hashable, Sendable, Codable {
    public var body: BodyRef
    public var signature: EdgeSignature

    public init(body: BodyRef, signature: EdgeSignature) {
        self.body = body
        self.signature = signature
    }
}

/// A closed sketch region, identified by a point inside it (sketch coordinates, mm).
/// Encodes as `{"x": …, "y": …}`.
public struct RegionRef: Hashable, Sendable, Codable {
    public var point: SIMD2<Double>

    public init(_ point: SIMD2<Double>) { self.point = point }
    public init(x: Double, y: Double) { self.point = SIMD2(x, y) }

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = SIMD2(try c.decode(Double.self, forKey: .x), try c.decode(Double.self, forKey: .y))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(point.x, forKey: .x)
        try c.encode(point.y, forKey: .y)
    }
}

/// One of the three origin planes.
public enum StandardPlane: String, Hashable, Sendable, Codable, CaseIterable {
    case xy, xz, yz

    /// The kernel plane (see ``Plane/xy``, ``Plane/xz``, ``Plane/yz`` for axis conventions).
    public var plane: Plane {
        switch self {
        case .xy: .xy
        case .xz: .xz
        case .yz: .yz
        }
    }
}

/// Where a sketch (or a mirror/primitive) is placed.
public enum SketchPlaneRef: Hashable, Sendable, Codable {
    /// An origin plane, offset along its normal by a length expression.
    case standard(StandardPlane, offset: Expr)
    /// A planar face of a body. `fallback` is the plane at the time the
    /// reference was made, used when the face can no longer be resolved.
    case face(FaceRef, fallback: Plane)

    /// The XY plane without offset.
    public static let xy = SketchPlaneRef.standard(.xy, offset: 0)

    /// Body features this placement depends on.
    public var referencedBodies: Set<BodyRef> {
        if case .face(let f, _) = self { return [f.body] }
        return []
    }

    /// Resolves the placement. `facePlane` maps a face reference to the
    /// current plane of that face (nil when it cannot be resolved, in which
    /// case the cached fallback is used).
    public func resolve(using evaluator: Evaluator, facePlane: (FaceRef) -> Plane? = { _ in nil }) throws -> Plane {
        switch self {
        case .standard(let p, let offset):
            return p.plane.offset(by: try evaluator.length(offset))
        case .face(let f, let fallback):
            return facePlane(f) ?? fallback
        }
    }

    private enum CodingKeys: String, CodingKey { case plane, offset, face, fallback }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try decoder.decodeTypeTag() {
        case "face":
            self = .face(
                try c.decode(FaceRef.self, forKey: .face),
                fallback: try c.decode(Plane.self, forKey: .fallback))
        default:
            self = .standard(
                try c.decode(StandardPlane.self, forKey: .plane),
                offset: try c.decodeIfPresent(Expr.self, forKey: .offset) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .standard(let p, let offset):
            try encoder.encodeTagged("standard")
            try c.encode(p, forKey: .plane)
            try c.encode(offset, forKey: .offset)
        case .face(let f, let fallback):
            try encoder.encodeTagged("face")
            try c.encode(f, forKey: .face)
            try c.encode(fallback, forKey: .fallback)
        }
    }
}

/// How a feature's result combines with existing bodies.
public enum Operation: String, Hashable, Sendable, Codable, CaseIterable {
    case newBody, join, cut, intersect
}

/// A 3D axis for patterns and rotations.
public enum AxisRef: Hashable, Sendable, Codable {
    /// A world axis through the origin.
    case x, y, z
    /// A straight edge (its line) or a circular edge (its centre axis).
    case edge(EdgeRef)

    /// Body features this axis depends on.
    public var referencedBodies: Set<BodyRef> {
        if case .edge(let e) = self { return [e.body] }
        return []
    }

    private enum CodingKeys: String, CodingKey { case edge }

    public init(from decoder: Decoder) throws {
        switch try decoder.decodeTypeTag() {
        case "edge": self = .edge(try decoder.container(keyedBy: CodingKeys.self).decode(EdgeRef.self, forKey: .edge))
        case "x": self = .x
        case "y": self = .y
        case "z": self = .z
        case let other:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown axis '\(other)'"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .x: try encoder.encodeTagged("x")
        case .y: try encoder.encodeTagged("y")
        case .z: try encoder.encodeTagged("z")
        case .edge(let e):
            try encoder.encodeTagged("edge")
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(e, forKey: .edge)
        }
    }
}
