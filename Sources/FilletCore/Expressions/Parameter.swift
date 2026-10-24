import Foundation

/// A named user parameter, e.g. `width = 40 mm`, usable in any expression.
public struct Parameter: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// Identifier used in expressions: letters, digits and `_`, not starting with a digit.
    public var name: String
    public var expression: Expr
    public var comment: String

    public init(id: UUID = UUID(), name: String, expression: Expr, comment: String = "") {
        self.id = id
        self.name = name
        self.expression = expression
        self.comment = comment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        expression = try c.decode(Expr.self, forKey: .expression)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
    }

    /// Why `name` cannot be used as a parameter name, or nil when it is valid.
    public static func validationError(forName name: String) -> String? {
        guard let first = name.first else { return "Name is empty" }
        guard first.isLetter || first == "_" else { return "Name must start with a letter or '_'" }
        guard name.allSatisfy({ $0.isLetter || ($0.isASCII && $0.isNumber) || $0 == "_" }) else {
            return "Name may only contain letters, digits and '_'"
        }
        if ExprFunctions.reserved.contains(name) { return "'\(name)' is a reserved word" }
        return nil
    }
}
