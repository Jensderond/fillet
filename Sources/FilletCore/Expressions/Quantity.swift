import Foundation

/// What an expression is expected to produce. Decides how bare numbers are read
/// (mm for lengths, degrees for angles) and which units are acceptable.
public enum QuantityKind: String, Sendable, Codable, CaseIterable {
    /// Millimetres. Accepts `mm cm m in` or bare numbers.
    case length
    /// Degrees. Accepts `deg rad °` or bare numbers.
    case angle
    /// A unitless number such as a count or ratio.
    case scalar
}

/// Physical dimension of an intermediate value, tracked as integer exponents
/// so `sqrt(a*a + b*b)` of two lengths is again a length.
public struct Dimension: Hashable, Sendable, CustomStringConvertible {
    public var length: Int
    public var angle: Int

    public init(length: Int = 0, angle: Int = 0) { self.length = length; self.angle = angle }

    public static let none = Dimension()
    public static let length = Dimension(length: 1)
    public static let angle = Dimension(angle: 1)

    public var isNone: Bool { length == 0 && angle == 0 }

    public var description: String {
        if isNone { return "unitless" }
        var parts: [String] = []
        if length != 0 { parts.append(length == 1 ? "length" : "length^\(length)") }
        if angle != 0 { parts.append(angle == 1 ? "angle" : "angle^\(angle)") }
        return parts.joined(separator: "·")
    }

    static func * (a: Dimension, b: Dimension) -> Dimension {
        Dimension(length: a.length + b.length, angle: a.angle + b.angle)
    }

    static func / (a: Dimension, b: Dimension) -> Dimension {
        Dimension(length: a.length - b.length, angle: a.angle - b.angle)
    }
}

/// A value in base units (mm, degrees) together with its dimension.
/// A bare number has dimension `.none` and adopts whatever it is combined with.
public struct Quantity: Hashable, Sendable {
    public var value: Double
    public var dimension: Dimension

    public init(_ value: Double, _ dimension: Dimension = .none) {
        self.value = value
        self.dimension = dimension
    }
}

/// Unit suffixes, converting to base units (mm / degrees).
enum ExprUnit {
    static let table: [String: Quantity] = [
        "mm": Quantity(1, .length),
        "cm": Quantity(10, .length),
        "m": Quantity(1000, .length),
        "in": Quantity(25.4, .length),
        "deg": Quantity(1, .angle),
        "°": Quantity(1, .angle),
        "rad": Quantity(180 / Double.pi, .angle),
    ]
}

/// An error parsing or evaluating an expression.
public struct EvalError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Human-readable explanation, e.g. `Unknown parameter 'widht'`.
    public var message: String
    /// Character offset in the expression source where the problem is, if known.
    public var position: Int?

    public init(_ message: String, position: Int? = nil) {
        self.message = message
        self.position = position
    }

    public var description: String {
        if let position { return "\(message) (at \(position))" }
        return message
    }
}
