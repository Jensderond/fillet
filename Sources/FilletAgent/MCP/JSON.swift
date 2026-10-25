import FilletCore
import FilletKernel
import Foundation

/// Convenience access to JSON values arriving from (and going to) agents.
extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }

    /// An integer, also from a numeric string ("3").
    public var int: Int? {
        if let n = number { return Int(exactly: n) }
        if let s = string { return Int(s) }
        return nil
    }

    /// Converts any `Encodable` value through JSON.
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a `Decodable` value from this JSON.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(self))
    }

    /// Compact JSON text (sorted keys, so output is stable).
    public func serialized(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// RFC 7396 merge patch: objects merge key by key, `null` deletes, anything else replaces.
    public func merging(patch: JSONValue) -> JSONValue {
        guard case .object(let p) = patch else { return patch }
        var result = object ?? [:]
        for (k, v) in p {
            if v == .null {
                result[k] = nil
            } else {
                result[k] = (result[k] ?? .null).merging(patch: v)
            }
        }
        return .object(result)
    }
}

extension JSONValue {
    /// A number rounded to `places` decimals, so tool output stays short.
    static func rounded(_ v: Double, _ places: Int = 3) -> JSONValue {
        let f = pow(10, Double(places))
        let r = (v * f).rounded() / f
        return .number(r == 0 ? 0 : r)  // no "-0"
    }

    static func vec(_ v: Vec3Like, _ places: Int = 3) -> JSONValue {
        [rounded(v.vx, places), rounded(v.vy, places), rounded(v.vz, places)]
    }

    static func point(_ p: SIMD2<Double>, _ places: Int = 3) -> JSONValue {
        [rounded(p.x, places), rounded(p.y, places)]
    }
}

/// Anything with three coordinates (kernel `Vec3`, `SIMD3`).
protocol Vec3Like {
    var vx: Double { get }
    var vy: Double { get }
    var vz: Double { get }
}

extension Vec3: Vec3Like {
    var vx: Double { x }
    var vy: Double { y }
    var vz: Double { z }
}

extension SIMD3: Vec3Like where Scalar == Double {
    var vx: Double { x }
    var vy: Double { y }
    var vz: Double { z }
}
