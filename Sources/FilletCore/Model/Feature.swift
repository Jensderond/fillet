import Foundation

/// One step of the design timeline.
public struct Feature: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// Display name, e.g. "Extrude 2".
    public var name: String
    /// Suppressed features are skipped by recompute but kept in the timeline.
    public var suppressed: Bool
    public var kind: FeatureKind

    public init(id: UUID = UUID(), name: String, suppressed: Bool = false, _ kind: FeatureKind) {
        self.id = id
        self.name = name
        self.suppressed = suppressed
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, name, suppressed, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(FeatureKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.typeName
        suppressed = try c.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
    }

    /// Ids of the features this one directly depends on (sketches and bodies it uses).
    public var referencedFeatures: Set<UUID> { kind.referencedFeatures.subtracting([id]) }

    /// True when this feature creates a new body (whose ``BodyRef`` is this feature's id).
    /// An unmerged mirror creates its copies as new bodies too.
    public var createsBody: Bool {
        switch kind {
        case .extrude(let e): e.operation == .newBody
        case .revolve(let r): r.operation == .newBody
        case .primitive(let p): p.operation == .newBody
        case .loft(let l): l.operation == .newBody
        case .mirror(let m): !m.merge
        case .importedSTEP: true
        default: false
        }
    }
}

/// What a feature does, with its parameters. Encodes as a flat JSON object
/// with a `"type"` discriminator, e.g. `{"type": "extrude", "distance": "10", ...}`.
public enum FeatureKind: Hashable, Sendable, Codable {
    case sketch(Sketch)
    case extrude(Extrude)
    case revolve(Revolve)
    case fillet(EdgeFeature)
    case chamfer(EdgeFeature)
    case shell(Shell)
    case primitive(Primitive)
    case combine(Combine)
    case move(Move)
    case scale(Scale)
    case loft(Loft)
    case mirror(Mirror)
    case pattern(Pattern)
    case importedSTEP(ImportedSTEP)
    case layFlat(LayFlat)
    case pressPull(PressPull)
    /// A feature type from a newer app version, preserved verbatim (never recomputed).
    case unknown(type: String, fields: [String: JSONValue])

    /// Name of the case as written in JSON (`"type"`).
    public var typeName: String {
        switch self {
        case .sketch: "sketch"
        case .extrude: "extrude"
        case .revolve: "revolve"
        case .fillet: "fillet"
        case .chamfer: "chamfer"
        case .shell: "shell"
        case .primitive: "primitive"
        case .combine: "combine"
        case .move: "move"
        case .scale: "scale"
        case .loft: "loft"
        case .mirror: "mirror"
        case .pattern: "pattern"
        case .importedSTEP: "importedSTEP"
        case .layFlat: "layFlat"
        case .pressPull: "pressPull"
        case .unknown(let type, _): type
        }
    }

    /// The payload, for generic access.
    var payload: (any Encodable & FeatureReferencing)? {
        switch self {
        case .sketch(let s): s
        case .extrude(let p): p
        case .revolve(let p): p
        case .fillet(let p), .chamfer(let p): p
        case .shell(let p): p
        case .primitive(let p): p
        case .combine(let p): p
        case .move(let p): p
        case .scale(let p): p
        case .loft(let p): p
        case .mirror(let p): p
        case .pattern(let p): p
        case .importedSTEP(let p): p
        case .layFlat(let p): p
        case .pressPull(let p): p
        case .unknown: nil
        }
    }

    /// Ids of features this one directly depends on.
    public var referencedFeatures: Set<UUID> { payload?.referencedFeatures ?? [] }

    public init(from decoder: Decoder) throws {
        let type = try decoder.decodeTypeTag()
        switch type {
        case "sketch": self = .sketch(try Sketch(from: decoder))
        case "extrude": self = .extrude(try Extrude(from: decoder))
        case "revolve": self = .revolve(try Revolve(from: decoder))
        case "fillet": self = .fillet(try EdgeFeature(from: decoder))
        case "chamfer": self = .chamfer(try EdgeFeature(from: decoder))
        case "shell": self = .shell(try Shell(from: decoder))
        case "primitive": self = .primitive(try Primitive(from: decoder))
        case "combine": self = .combine(try Combine(from: decoder))
        case "move": self = .move(try Move(from: decoder))
        case "scale": self = .scale(try Scale(from: decoder))
        case "loft": self = .loft(try Loft(from: decoder))
        case "mirror": self = .mirror(try Mirror(from: decoder))
        case "pattern": self = .pattern(try Pattern(from: decoder))
        case "importedSTEP": self = .importedSTEP(try ImportedSTEP(from: decoder))
        case "layFlat": self = .layFlat(try LayFlat(from: decoder))
        case "pressPull": self = .pressPull(try PressPull(from: decoder))
        default:
            var fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
            fields["type"] = nil
            self = .unknown(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(let type, let fields) = self {
            var all = fields
            all["type"] = .string(type)
            var c = encoder.singleValueContainer()
            try c.encode(all)
        } else {
            try encoder.encodeTagged(typeName, payload)
        }
    }
}

extension Sketch: FeatureReferencing {
    public var referencedFeatures: Set<UUID> { plane.referencedBodies.featureIDs }
}
