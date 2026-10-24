import FilletKernel
import Foundation

/// A solid body after recompute.
public struct EvaluatedBody: Identifiable, Sendable {
    public var ref: BodyRef
    /// Display name ("Body 1", or the imported file name).
    public var name: String
    public var shape: Shape
    /// The last feature that changed this body.
    public var lastFeature: UUID

    public var id: BodyRef { ref }
}

/// A sketch after recompute: its resolved plane, curves and closed regions.
public struct EvaluatedSketch: Sendable {
    public var feature: UUID
    /// The sketch definition this was evaluated from.
    public var source: Sketch
    public var plane: Plane
    /// Display polylines per sketch shape, in sketch coordinates (construction shapes included).
    public var curves: [UUID: [[SIMD2<Double>]]]
    /// Closed regions formed by the non-construction shapes (nil when there are none).
    public var regions: SketchRegions?
    /// Per-region translucent fill triangles in sketch coordinates.
    public var regionFills: [[SIMD2<Double>]]
    /// Shapes that failed to evaluate, with a message.
    public var shapeErrors: [UUID: String]
}

/// Outcome of one feature during recompute.
public enum FeatureStatus: Hashable, Sendable {
    case ok
    /// The feature failed and was skipped; later features still ran.
    case failed(String)
    /// Rolled back or suppressed.
    case inactive
}

/// The result of evaluating a document: bodies, sketches and per-feature status.
public struct EvaluatedModel: Sendable {
    /// Bodies in creation order.
    public var bodies: [EvaluatedBody] = []
    public var sketches: [UUID: EvaluatedSketch] = [:]
    public var status: [UUID: FeatureStatus] = [:]
    public var parameters: ParameterTable

    public init(parameters: ParameterTable) { self.parameters = parameters }

    public func body(_ ref: BodyRef) -> EvaluatedBody? { bodies.first { $0.ref == ref } }

    public func error(for feature: UUID) -> String? {
        if case .failed(let message) = status[feature] { return message }
        return nil
    }

    /// Persistent reference to a face picked in the viewport.
    public func faceRef(body: BodyRef, face index: Int) -> FaceRef? {
        guard let shape = bodies.first(where: { $0.ref == body })?.shape, let info = shape.faceInfoIfValid(index) else { return nil }
        return FaceRef(body: body, signature: FaceSignature(info))
    }

    /// Persistent reference to an edge picked in the viewport.
    public func edgeRef(body: BodyRef, edge index: Int) -> EdgeRef? {
        guard let shape = bodies.first(where: { $0.ref == body })?.shape, let info = shape.edgeInfoIfValid(index) else { return nil }
        return EdgeRef(body: body, signature: EdgeSignature(info))
    }

    /// Current index of a referenced face, if it can still be found.
    public func resolve(_ ref: FaceRef) -> Int? {
        guard let shape = body(ref.body)?.shape else { return nil }
        return ReferenceResolver.resolve(ref.signature, in: shape.faceInfos)
    }

    /// Current index of a referenced edge, if it can still be found.
    public func resolve(_ ref: EdgeRef) -> Int? {
        guard let shape = body(ref.body)?.shape else { return nil }
        return ReferenceResolver.resolve(ref.signature, in: shape.edgeInfos)
    }

    /// Plane of a referenced planar face, if it can be found and is planar.
    public func plane(of ref: FaceRef) -> Plane? {
        guard let shape = body(ref.body)?.shape, let i = resolve(ref) else { return nil }
        return shape.facePlane(i)
    }
}
