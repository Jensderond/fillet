import Foundation

/// Evaluates ``Expr`` values against a set of already-evaluated parameters.
///
/// Values are returned in base units: millimetres for lengths, degrees for
/// angles. A bare number is read as mm in a length context and as degrees in
/// an angle context. Units: `mm cm m in` and `deg rad °`.
public struct Evaluator: Sendable {
    /// Evaluated parameter values by name.
    public var values: [String: Quantity]
    /// Parameters that failed to evaluate; referencing one reports its error.
    public var failedParameters: [String: EvalError]

    public init(values: [String: Quantity] = [:], failedParameters: [String: EvalError] = [:]) {
        self.values = values
        self.failedParameters = failedParameters
    }

    /// An evaluator without any parameters.
    public static let empty = Evaluator()

    // MARK: Typed entry points

    /// Evaluates `expr`, checks it matches `kind`, and returns the value in
    /// base units (mm or degrees).
    public func evaluate(_ expr: Expr, as kind: QuantityKind) throws(EvalError) -> Double {
        let q = try quantity(expr)
        switch kind {
        case .length:
            guard q.dimension.isNone || q.dimension == .length else {
                throw EvalError("Expected a length, got \(q.dimension)")
            }
        case .angle:
            guard q.dimension.isNone || q.dimension == .angle else {
                throw EvalError("Expected an angle, got \(q.dimension)")
            }
        case .scalar:
            guard q.dimension.isNone else {
                throw EvalError("Expected a plain number, got \(q.dimension)")
            }
        }
        guard q.value.isFinite else { throw EvalError("Result is not a finite number") }
        return q.value
    }

    /// A length in millimetres.
    public func length(_ expr: Expr) throws(EvalError) -> Double { try evaluate(expr, as: .length) }
    /// An angle in degrees.
    public func angleDegrees(_ expr: Expr) throws(EvalError) -> Double { try evaluate(expr, as: .angle) }
    /// An angle in radians (what the kernel expects).
    public func angleRadians(_ expr: Expr) throws(EvalError) -> Double { try evaluate(expr, as: .angle) * .pi / 180 }
    /// A unitless number.
    public func scalar(_ expr: Expr) throws(EvalError) -> Double { try evaluate(expr, as: .scalar) }

    /// A unitless whole number (counts, polygon sides); rounds to nearest.
    public func integer(_ expr: Expr) throws(EvalError) -> Int {
        let v = try scalar(expr).rounded()
        guard abs(v) < 1e9 else { throw EvalError("Number is too large") }
        return Int(v)
    }

    /// Evaluates without a kind check, keeping the dimension.
    public func quantity(_ expr: Expr) throws(EvalError) -> Quantity {
        try evaluate(try ExprParser.parse(expr.source))
    }

    // MARK: Tree walk

    func evaluate(_ node: ExprNode) throws(EvalError) -> Quantity {
        switch node {
        case .number(let v, let unit, _):
            guard let unit else { return Quantity(v) }
            return Quantity(v * unit.value, unit.dimension)
        case .identifier(let name, let pos):
            if let c = ExprFunctions.constants[name] { return c }
            if let v = values[name] { return v }
            if failedParameters[name] != nil {
                throw EvalError("Parameter '\(name)' has an error", position: pos)
            }
            if ExprFunctions.names.contains(name) {
                throw EvalError("Function '\(name)' needs parentheses", position: pos)
            }
            throw EvalError("Unknown parameter '\(name)'", position: pos)
        case .negate(let n, _):
            let q = try evaluate(n)
            return Quantity(-q.value, q.dimension)
        case .binary(let op, let l, let r, let pos):
            return try binary(op, try evaluate(l), try evaluate(r), position: pos)
        case .unit(let n, let unit, let pos):
            let q = try evaluate(n)
            guard q.dimension.isNone else {
                throw EvalError("Value already has a unit (\(q.dimension))", position: pos)
            }
            return Quantity(q.value * unit.value, unit.dimension)
        case .call(let name, let args, let pos):
            var values: [Quantity] = []
            for a in args { values.append(try evaluate(a)) }
            return try ExprFunctions.call(name, values, position: pos)
        }
    }

    private func binary(_ op: Character, _ a: Quantity, _ b: Quantity, position: Int) throws(EvalError) -> Quantity {
        switch op {
        case "+", "-":
            let dim = try Evaluator.unify(a.dimension, b.dimension, op: String(op), position: position)
            return Quantity(op == "+" ? a.value + b.value : a.value - b.value, dim)
        case "*":
            return Quantity(a.value * b.value, a.dimension * b.dimension)
        case "/":
            guard b.value != 0 else { throw EvalError("Division by zero", position: position) }
            return Quantity(a.value / b.value, a.dimension / b.dimension)
        case "^":
            guard b.dimension.isNone else { throw EvalError("Exponent must be a plain number", position: position) }
            if a.dimension.isNone { return Quantity(pow(a.value, b.value)) }
            guard b.value == b.value.rounded(), abs(b.value) <= 16 else {
                throw EvalError("A value with units can only be raised to a whole power", position: position)
            }
            let n = Int(b.value)
            return Quantity(
                pow(a.value, b.value),
                Dimension(length: a.dimension.length * n, angle: a.dimension.angle * n))
        default:
            throw EvalError("Unknown operator '\(op)'", position: position)
        }
    }

    /// Dimension of a sum: a bare number adopts the other side's dimension.
    static func unify(_ a: Dimension, _ b: Dimension, op: String, position: Int) throws(EvalError) -> Dimension {
        if a.isNone { return b }
        if b.isNone || a == b { return a }
        throw EvalError("Cannot combine \(a) and \(b) with '\(op)'", position: position)
    }
}
