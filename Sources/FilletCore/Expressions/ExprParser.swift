import Foundation

/// Parsed expression tree. Positions are character offsets into the source.
indirect enum ExprNode: Sendable, Equatable {
    case number(Double, unit: Quantity?, position: Int)
    case identifier(String, position: Int)
    case negate(ExprNode, position: Int)
    case binary(Character, ExprNode, ExprNode, position: Int)
    case call(String, [ExprNode], position: Int)
    /// A unit suffix applied to a non-literal, e.g. `pi rad` or `(a + b) mm`.
    case unit(ExprNode, Quantity, position: Int)

    /// All identifiers referenced (parameter or constant names, not function names).
    var identifiers: Set<String> {
        switch self {
        case .number: return []
        case .identifier(let name, _): return ExprFunctions.constants[name] == nil ? [name] : []
        case .negate(let n, _): return n.identifiers
        case .binary(_, let l, let r, _): return l.identifiers.union(r.identifiers)
        case .call(_, let args, _): return args.reduce(into: Set()) { $0.formUnion($1.identifiers) }
        case .unit(let n, _, _): return n.identifiers
        }
    }
}

private enum Token: Equatable {
    case number(Double)
    case identifier(String)
    case symbol(Character)
    case end
}

/// Recursive-descent parser for the expression language.
///
/// Grammar (lowest to highest precedence):
/// ```
/// sum     := product (('+' | '-') product)*
/// product := unary (('*' | '/') unary)*
/// unary   := ('-' | '+') unary | power
/// power   := primary ('^' unary)?          // right associative, -2^2 = -4
/// primary := number unit? | (name '(' args ')' | name | '(' sum ')') unit?
/// ```
enum ExprParser {
    static func parse(_ source: String) throws(EvalError) -> ExprNode {
        var parser = Parser(source: source)
        return try parser.parseAll()
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var token: Token = .end
        var tokenStart = 0

        init(source: String) { chars = Array(source) }

        mutating func parseAll() throws(EvalError) -> ExprNode {
            try advance()
            if token == .end { throw EvalError("Expression is empty", position: 0) }
            let node = try parseSum()
            guard token == .end else { throw EvalError("Unexpected \(describe(token))", position: tokenStart) }
            return node
        }

        // MARK: Grammar

        mutating func parseSum() throws(EvalError) -> ExprNode {
            var lhs = try parseProduct()
            while case .symbol(let op) = token, op == "+" || op == "-" {
                let pos = tokenStart
                try advance()
                lhs = .binary(op, lhs, try parseProduct(), position: pos)
            }
            return lhs
        }

        mutating func parseProduct() throws(EvalError) -> ExprNode {
            var lhs = try parseUnary()
            while case .symbol(let op) = token, op == "*" || op == "/" {
                let pos = tokenStart
                try advance()
                lhs = .binary(op, lhs, try parseUnary(), position: pos)
            }
            return lhs
        }

        mutating func parseUnary() throws(EvalError) -> ExprNode {
            if case .symbol(let op) = token, op == "-" || op == "+" {
                let pos = tokenStart
                try advance()
                let operand = try parseUnary()
                return op == "-" ? .negate(operand, position: pos) : operand
            }
            return try parsePower()
        }

        mutating func parsePower() throws(EvalError) -> ExprNode {
            let base = try parsePrimary()
            if token == .symbol("^") {
                let pos = tokenStart
                try advance()
                return .binary("^", base, try parseUnary(), position: pos)
            }
            return base
        }

        mutating func parsePrimary() throws(EvalError) -> ExprNode {
            let pos = tokenStart
            switch token {
            case .number(let value):
                try advance()
                var unit: Quantity?
                if case .identifier(let name) = token, let u = ExprUnit.table[name] {
                    unit = u
                    try advance()
                } else if case .identifier(let name) = token {
                    throw EvalError("Unknown unit '\(name)'", position: tokenStart)
                } else if case .number = token {
                    throw EvalError("Missing operator between numbers", position: tokenStart)
                }
                return .number(value, unit: unit, position: pos)
            case .identifier(let name):
                try advance()
                if token == .symbol("(") {
                    try advance()
                    var args: [ExprNode] = []
                    if token != .symbol(")") {
                        args.append(try parseSum())
                        while token == .symbol(",") {
                            try advance()
                            args.append(try parseSum())
                        }
                    }
                    try expect(")", openedAt: pos)
                    return try parseUnitSuffix(.call(name, args, position: pos))
                }
                return try parseUnitSuffix(.identifier(name, position: pos))
            case .symbol("("):
                try advance()
                let inner = try parseSum()
                try expect(")", openedAt: pos)
                return try parseUnitSuffix(inner)
            case .end:
                throw EvalError("Unexpected end of expression", position: pos)
            default:
                throw EvalError("Unexpected \(describe(token))", position: pos)
            }
        }

        /// Wraps `node` in a unit conversion when a unit name follows.
        mutating func parseUnitSuffix(_ node: ExprNode) throws(EvalError) -> ExprNode {
            guard case .identifier(let name) = token, let unit = ExprUnit.table[name] else { return node }
            let pos = tokenStart
            try advance()
            return .unit(node, unit, position: pos)
        }

        mutating func expect(_ symbol: Character, openedAt: Int) throws(EvalError) {
            guard token == .symbol(symbol) else {
                throw EvalError("Missing '\(symbol)'", position: token == .end ? chars.count : tokenStart)
            }
            try advance()
        }

        func describe(_ t: Token) -> String {
            switch t {
            case .number(let v): return "number \(Expr.format(v))"
            case .identifier(let s): return "'\(s)'"
            case .symbol(let c): return "'\(c)'"
            case .end: return "end of expression"
            }
        }

        // MARK: Lexer

        mutating func advance() throws(EvalError) {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            tokenStart = index
            guard index < chars.count else { token = .end; return }
            let c = chars[index]
            if c.isASCIIDigit || (c == "." && index + 1 < chars.count && chars[index + 1].isASCIIDigit) {
                token = .number(try lexNumber())
            } else if c.isLetter || c == "_" {
                var name = ""
                while index < chars.count, chars[index].isLetter || chars[index].isASCIIDigit || chars[index] == "_" {
                    name.append(chars[index])
                    index += 1
                }
                token = .identifier(name)
            } else if c == "°" {
                index += 1
                token = .identifier("°")
            } else if "+-*/^(),".contains(c) {
                index += 1
                token = .symbol(c)
            } else {
                throw EvalError("Unexpected character '\(c)'", position: index)
            }
        }

        mutating func lexNumber() throws(EvalError) -> Double {
            let start = index
            while index < chars.count, chars[index].isASCIIDigit { index += 1 }
            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isASCIIDigit { index += 1 }
            }
            // Exponent only when followed by digits, so "2e" is not swallowed.
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                var j = index + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isASCIIDigit {
                    index = j
                    while index < chars.count, chars[index].isASCIIDigit { index += 1 }
                }
            }
            guard let value = Double(String(chars[start..<index])) else {
                throw EvalError("Invalid number", position: start)
            }
            return value
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
