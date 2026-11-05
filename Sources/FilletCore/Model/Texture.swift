import Foundation

/// Identifies a surface texture pattern in ``TextureCatalog`` ("knit", "dots"). Stored as a plain
/// string, so files keep their pattern when newer versions add patterns, and a file naming a
/// pattern this version doesn't know still opens (the step then reports it can't be recomputed).
public struct TexturePatternID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let knit: TexturePatternID = "knit"
    public static let dots: TexturePatternID = "dots"
}

/// Puts a surface texture (a knitted stitch pattern, dots, …) on faces of a body. The B-rep is
/// left alone: the texture is a displacement of the body's mesh, applied to what the viewport
/// shows and to every exported 3MF/STL (see ``TextureEngine``). Its faces are found again by
/// signature on recompute, like a press pull's.
///
/// Encodes as `{"type": "texture", "body": …, "faces": […], "pattern": "knit", "values": {"depth": "0.6", …}}`.
/// `values` holds the pattern's own parameters by id (see ``TexturePattern/parameters``), as
/// expressions; a value missing from the file takes the pattern's default, and values a pattern
/// doesn't declare are kept untouched, so files stay stable as patterns gain parameters.
public struct Texture: Hashable, Sendable, Codable, FeatureReferencing {
    public var body: BodyRef
    /// Faces to texture. Empty: every face except the ones the body rests on (the bed face).
    public var faces: [FaceRef]
    public var pattern: TexturePatternID
    /// Parameter values by ``TextureParameter/id``.
    public var values: [String: Expr]

    public init(body: BodyRef, faces: [FaceRef] = [], pattern: TexturePatternID, values: [String: Expr] = [:]) {
        self.body = body; self.faces = faces; self.pattern = pattern; self.values = values
    }

    public var referencedFeatures: Set<UUID> { Set(faces.map(\.body.feature)).union([body.feature]) }

    /// The value for parameter `id`: the stored expression, else the catalogue default (nil for
    /// a parameter neither the file nor the pattern knows).
    public func value(_ id: String) -> Expr? {
        values[id] ?? TextureCatalog.parameters(for: pattern).first { $0.id == id }.map { Expr($0.defaultValue) }
    }

    private enum CodingKeys: String, CodingKey { case body, faces, pattern, values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decode(BodyRef.self, forKey: .body)
        faces = try c.decodeIfPresent([FaceRef].self, forKey: .faces) ?? []
        pattern = try c.decode(TexturePatternID.self, forKey: .pattern)
        values = try c.decodeIfPresent([String: Expr].self, forKey: .values) ?? [:]
    }
}
