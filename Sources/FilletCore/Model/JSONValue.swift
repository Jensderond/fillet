import Foundation

/// An arbitrary JSON value. Used to carry data this version of the app does
/// not understand (e.g. a feature type added in a later version) through a
/// load/save round trip unchanged.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A coding key for the `"type"` discriminator of tagged enums.
enum TypeCodingKey: String, CodingKey {
    case type
}

extension Decoder {
    /// Reads the `"type"` discriminator of a tagged enum object.
    func decodeTypeTag() throws -> String {
        try container(keyedBy: TypeCodingKey.self).decode(String.self, forKey: .type)
    }
}

extension Encoder {
    /// Writes `{"type": tag, ...payload fields}` into one flat JSON object.
    func encodeTagged(_ tag: String, _ payload: (any Encodable)? = nil) throws {
        var c = container(keyedBy: TypeCodingKey.self)
        try c.encode(tag, forKey: .type)
        try payload?.encode(to: self)
    }
}
