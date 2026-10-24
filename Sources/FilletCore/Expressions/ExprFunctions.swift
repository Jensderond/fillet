import Foundation

/// Built-in constants and functions of the expression language.
///
/// Angles are in degrees (the base angle unit): `sin(30)` is 0.5, and
/// `asin(0.5)` is the angle 30°. Use the `rad` suffix for radians: `sin(pi/6 rad)`.
enum ExprFunctions {
    static let constants: [String: Quantity] = [
        "pi": Quantity(Double.pi),
        "π": Quantity(Double.pi),
    ]

    static let names: Set<String> = [
        "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "abs", "min", "max", "round", "floor", "ceil",
    ]

    /// Names a parameter may not use.
    static var reserved: Set<String> {
        names.union(constants.keys).union(ExprUnit.table.keys)
    }

    static func call(_ name: String, _ args: [Quantity], position: Int) throws(EvalError) -> Quantity {
        func arity(_ n: Int) throws(EvalError) {
            guard args.count == n else {
                throw EvalError("\(name)() takes \(n) argument\(n == 1 ? "" : "s"), got \(args.count)", position: position)
            }
        }
        func angleArg() throws(EvalError) -> Double {
            try arity(1)
            let a = args[0]
            guard a.dimension.isNone || a.dimension == .angle else {
                throw EvalError("\(name)() expects an angle, got \(a.dimension)", position: position)
            }
            return a.value * .pi / 180
        }
        func ratioArg() throws(EvalError) -> Double {
            try arity(1)
            guard args[0].dimension.isNone else {
                throw EvalError("\(name)() expects a unitless number, got \(args[0].dimension)", position: position)
            }
            return args[0].value
        }
        func inverse(_ f: (Double) -> Double) throws(EvalError) -> Quantity {
            let x = try ratioArg()
            let r = f(x)
            guard r.isFinite else { throw EvalError("\(name)(\(Expr.format(x))) is undefined", position: position) }
            return Quantity(r * 180 / .pi, .angle)
        }

        switch name {
        case "sqrt":
            try arity(1)
            let a = args[0]
            guard a.value >= 0 else { throw EvalError("sqrt() of a negative number", position: position) }
            guard a.dimension.length % 2 == 0, a.dimension.angle % 2 == 0 else {
                throw EvalError("sqrt() of \(a.dimension) has no unit", position: position)
            }
            return Quantity(a.value.squareRoot(), Dimension(length: a.dimension.length / 2, angle: a.dimension.angle / 2))
        case "sin": return Quantity(sin(try angleArg()))
        case "cos": return Quantity(cos(try angleArg()))
        case "tan": return Quantity(tan(try angleArg()))
        case "asin": return try inverse(asin)
        case "acos": return try inverse(acos)
        case "atan": return try inverse(atan)
        case "abs", "round", "floor", "ceil":
            try arity(1)
            let a = args[0]
            let f: (Double) -> Double =
                switch name {
                case "abs": { Swift.abs($0) }
                case "round": { $0.rounded(.toNearestOrAwayFromZero) }
                case "floor": { $0.rounded(.down) }
                default: { $0.rounded(.up) }
                }
            return Quantity(f(a.value), a.dimension)
        case "min", "max":
            guard !args.isEmpty else { throw EvalError("\(name)() needs at least one argument", position: position) }
            var result = args[0]
            for a in args.dropFirst() {
                let dim = try Evaluator.unify(result.dimension, a.dimension, op: name, position: position)
                let v = name == "min" ? Swift.min(result.value, a.value) : Swift.max(result.value, a.value)
                result = Quantity(v, dim)
            }
            return result
        default:
            throw EvalError("Unknown function '\(name)'", position: position)
        }
    }
}
