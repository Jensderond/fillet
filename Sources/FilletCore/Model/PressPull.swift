import Foundation

/// Moves faces of a body along their normals, like Fusion's Press Pull on a face (offset face):
/// pulling a box's top face up 5 makes the box 5 taller, pushing a hole's wall back widens the
/// hole. Neighbouring faces stretch to follow and the body stays one body.
public struct PressPull: Hashable, Sendable, Codable, FeatureReferencing {
    public var body: BodyRef
    public var faces: [FaceRef]
    /// Distance along the faces' outward normals: positive adds material, negative removes it.
    public var distance: Expr

    public init(body: BodyRef, faces: [FaceRef], distance: Expr) {
        self.body = body; self.faces = faces; self.distance = distance
    }

    public var referencedFeatures: Set<UUID> { Set(faces.map(\.body.feature)).union([body.feature]) }
}
