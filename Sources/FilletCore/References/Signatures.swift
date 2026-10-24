import FilletKernel
import Foundation

/// Geometric fingerprint of a B-rep face, used to find "the same" face again
/// after the model is recomputed (topological naming).
public struct FaceSignature: Hashable, Sendable, Codable {
    public var surface: SurfaceType
    public var centroid: Vec3
    /// Outward normal near the centroid.
    public var normal: Vec3
    public var area: Double
    /// Size of the face's bounding box (max - min), a cheap shape descriptor.
    public var extent: Vec3

    public init(surface: SurfaceType, centroid: Vec3, normal: Vec3, area: Double, extent: Vec3) {
        self.surface = surface
        self.centroid = centroid
        self.normal = normal
        self.area = area
        self.extent = extent
    }

    /// Captures the signature of a face.
    public init(_ info: FaceInfo) {
        self.init(
            surface: info.surface, centroid: info.centroid, normal: info.normal.normalized,
            area: info.area, extent: info.boundsMax - info.boundsMin)
    }
}

/// Geometric fingerprint of a B-rep edge.
public struct EdgeSignature: Hashable, Sendable, Codable {
    public var curve: CurveType
    public var start: Vec3
    public var mid: Vec3
    public var end: Vec3
    /// Tangent at the midpoint; compared sign-agnostically.
    public var tangent: Vec3
    public var length: Double
    /// Circle radius, 0 for other curves.
    public var radius: Double

    public init(curve: CurveType, start: Vec3, mid: Vec3, end: Vec3, tangent: Vec3, length: Double, radius: Double) {
        self.curve = curve
        self.start = start
        self.mid = mid
        self.end = end
        self.tangent = tangent
        self.length = length
        self.radius = radius
    }

    /// Captures the signature of an edge.
    public init(_ info: EdgeInfo) {
        self.init(
            curve: info.curve, start: info.start, mid: info.mid, end: info.end,
            tangent: info.tangentAtMid.normalized, length: info.length, radius: info.radius)
    }
}

// MARK: - Readable coding (type names instead of the kernel's raw integers)

extension SurfaceType {
    static let names: [SurfaceType: String] = [
        .plane: "plane", .cylinder: "cylinder", .cone: "cone", .sphere: "sphere", .torus: "torus",
        .bspline: "bspline", .other: "other",
    ]
}

extension CurveType {
    static let names: [CurveType: String] = [
        .line: "line", .circle: "circle", .ellipse: "ellipse", .bspline: "bspline", .other: "other",
    ]
}

/// Decodes a type stored as its name (or, leniently, as the raw integer).
private func decodeNamed<T: RawRepresentable<Int32>>(
    _ names: [T: String], from c: KeyedDecodingContainer<SignatureCodingKeys>, key: SignatureCodingKeys, fallback: T
) throws -> T {
    if let name = try? c.decode(String.self, forKey: key) {
        return names.first { $0.value == name }?.key ?? fallback
    }
    return T(rawValue: try c.decode(Int32.self, forKey: key)) ?? fallback
}

private enum SignatureCodingKeys: String, CodingKey {
    case surface, centroid, normal, area, extent
    case curve, start, mid, end, tangent, length, radius
}

extension FaceSignature {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SignatureCodingKeys.self)
        self.init(
            surface: try decodeNamed(SurfaceType.names, from: c, key: .surface, fallback: .other),
            centroid: try c.decode(Vec3.self, forKey: .centroid), normal: try c.decode(Vec3.self, forKey: .normal),
            area: try c.decode(Double.self, forKey: .area),
            extent: try c.decodeIfPresent(Vec3.self, forKey: .extent) ?? .zero)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SignatureCodingKeys.self)
        try c.encode(SurfaceType.names[surface] ?? "other", forKey: .surface)
        try c.encode(centroid, forKey: .centroid)
        try c.encode(normal, forKey: .normal)
        try c.encode(area, forKey: .area)
        try c.encode(extent, forKey: .extent)
    }
}

extension EdgeSignature {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SignatureCodingKeys.self)
        self.init(
            curve: try decodeNamed(CurveType.names, from: c, key: .curve, fallback: .other),
            start: try c.decode(Vec3.self, forKey: .start), mid: try c.decode(Vec3.self, forKey: .mid),
            end: try c.decode(Vec3.self, forKey: .end), tangent: try c.decode(Vec3.self, forKey: .tangent),
            length: try c.decode(Double.self, forKey: .length),
            radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SignatureCodingKeys.self)
        try c.encode(CurveType.names[curve] ?? "other", forKey: .curve)
        try c.encode(start, forKey: .start)
        try c.encode(mid, forKey: .mid)
        try c.encode(end, forKey: .end)
        try c.encode(tangent, forKey: .tangent)
        try c.encode(length, forKey: .length)
        try c.encode(radius, forKey: .radius)
    }
}
