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

/// How a face or edge reference was found again on recompute.
public struct ResolvedReference: Hashable, Sendable {
    /// Index of the face/edge on the body the step worked on.
    public var index: Int
    /// The resolver's score: 0 = exactly as picked (see ``ReferenceResolver``).
    public var score: Double
    /// Another face/edge matched almost as well.
    public var isAmbiguous: Bool
    /// Distance from where it was picked to the found one (centroid or edge midpoint), mm.
    public var offset: Double

    public init(_ match: ReferenceMatch, offset: Double) {
        index = match.index
        score = match.score
        isAmbiguous = match.isAmbiguous
        self.offset = offset
    }
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
    /// Display tessellation per body (empty mesh when tessellation failed).
    public var meshes: [BodyRef: Mesh] = [:]
    /// Bodies as they were just before the feature passed as `before:` to
    /// `ModelEvaluator.evaluate` (the geometry a feature being edited picks from).
    public var bodiesBefore: [EvaluatedBody]?
    /// Per fillet or chamfer: the edges of the body before it that its references resolved to,
    /// i.e. exactly the edges the kernel was asked to round or bevel. Recorded before the kernel
    /// runs, so a step that failed has them too; references that no longer resolve are absent.
    public var resolvedEdges: [UUID: [EdgeInfo]] = [:]
    /// Per fillet, chamfer, shell or lay-flat: how each of its face/edge references was found
    /// again, in order (nil = not found).
    public var references: [UUID: [ResolvedReference?]] = [:]

    /// The pre-feature version of a body (falls back to the current one).
    public func bodyBefore(_ ref: BodyRef) -> EvaluatedBody? {
        bodiesBefore?.first { $0.ref == ref } ?? body(ref)
    }

    /// Maps an edge picked on the displayed (post-feature) body back to a
    /// persistent reference on the pre-feature body.
    public func edgeRefBefore(body ref: BodyRef, displayedEdge index: Int) -> EdgeRef? {
        guard let shown = body(ref)?.shape.edgeInfoIfValid(index), let before = bodyBefore(ref)?.shape else { return nil }
        guard let i = ReferenceResolver.resolve(EdgeSignature(shown), in: before.edgeInfos) else { return nil }
        return EdgeRef(body: ref, signature: EdgeSignature(before.edgeInfo(i)))
    }

    /// Maps a face picked on the displayed body back to the pre-feature body.
    public func faceRefBefore(body ref: BodyRef, displayedFace index: Int) -> FaceRef? {
        guard let shown = body(ref)?.shape.faceInfoIfValid(index), let before = bodyBefore(ref)?.shape else { return nil }
        guard let i = ReferenceResolver.resolve(FaceSignature(shown), in: before.faceInfos) else { return nil }
        return FaceRef(body: ref, signature: FaceSignature(before.faceInfo(i)))
    }

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
