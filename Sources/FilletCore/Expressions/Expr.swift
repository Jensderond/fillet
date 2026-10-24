import Foundation

/// A user-entered numeric expression such as `"width/2 + 3 mm"`.
///
/// `Expr` only stores the source text; it is evaluated against a parameter
/// table by an ``Evaluator``. It encodes to JSON as a plain string (decoding
/// also accepts a JSON number for hand-written files).
public struct Expr: Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral
{
    /// The expression exactly as the user typed it.
    public var source: String

    public init(_ source: String) { self.source = source }

    /// An expression holding a plain number (formatted without a trailing `.0`).
    public init(_ value: Double) { self.source = Expr.format(value) }

    public init(floatLiteral value: Double) { self.init(value) }
    public init(integerLiteral value: Int) { self.source = String(value) }
    public init(stringLiteral value: String) { self.source = value }

    public static let zero: Expr = 0

    public var description: String { source }

    /// Names of the identifiers (parameters) referenced by this expression,
    /// or an empty set when it does not parse.
    public var referencedNames: Set<String> {
        (try? ExprParser.parse(source))?.identifiers ?? []
    }

    /// True when the expression parses and references no parameters (e.g. `"10 mm"`, `"2 * 3"`).
    public var isLiteral: Bool {
        guard let node = try? ExprParser.parse(source) else { return false }
        return node.identifiers.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            source = s
        } else {
            source = Expr.format(try c.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source)
    }

    /// Shortest round-tripping decimal form, without a trailing `.0`.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

/// A 2D point whose coordinates are expressions (sketch-plane mm).
public struct Point2Expr: Hashable, Sendable, Codable {
    public var x: Expr
    public var y: Expr

    public init(_ x: Expr, _ y: Expr) { self.x = x; self.y = y }
    public init(x: Expr, y: Expr) { self.x = x; self.y = y }
    public init(_ p: SIMD2<Double>) { self.init(Expr(p.x), Expr(p.y)) }

    public static let origin = Point2Expr(0, 0)

    /// Evaluates both coordinates as lengths (mm).
    public func evaluate(using evaluator: Evaluator) throws -> SIMD2<Double> {
        SIMD2(try evaluator.length(x), try evaluator.length(y))
    }
}

/// A 3D vector whose components are expressions (mm).
public struct Vec3Expr: Hashable, Sendable, Codable {
    public var x: Expr
    public var y: Expr
    public var z: Expr

    public init(_ x: Expr, _ y: Expr, _ z: Expr) { self.x = x; self.y = y; self.z = z }

    public static let zero = Vec3Expr(0, 0, 0)

    /// Evaluates all components as lengths (mm).
    public func evaluate(using evaluator: Evaluator) throws -> SIMD3<Double> {
        SIMD3(try evaluator.length(x), try evaluator.length(y), try evaluator.length(z))
    }
}
