import Foundation

extension Document {
    /// Keys whose string values are never expressions.
    private static let nonExpressionKeys: Set<String> = ["name", "type", "id", "comment", "brep", "printer", "units"]

    /// Rewrites every expression in the document (parameters and feature
    /// dimensions) that references `old` to use `new` instead.
    public mutating func renameParameterReferences(from old: String, to new: String) {
        guard old != new, let data = try? encoded(),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        let rewritten = Self.rename(json, key: nil, old: old, new: new)
        guard rewritten != json, let out = try? JSONEncoder().encode(rewritten), let doc = try? Document(data: out) else { return }
        self = doc
    }

    private static func rename(_ value: JSONValue, key: String?, old: String, new: String) -> JSONValue {
        switch value {
        case .string(let s):
            guard let key, !nonExpressionKeys.contains(key), Expr(stringLiteral: s).referencedNames.contains(old) else { return value }
            return .string(replacingIdentifier(old, with: new, in: s))
        case .array(let items):
            return .array(items.map { rename($0, key: key, old: old, new: new) })
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, rename($0.value, key: $0.key, old: old, new: new)) }))
        default:
            return value
        }
    }

    /// Replaces whole-word occurrences of an identifier.
    static func replacingIdentifier(_ old: String, with new: String, in source: String) -> String {
        var result = ""
        var token = ""
        func flush() {
            result += token == old ? new : token
            token = ""
        }
        for ch in source {
            if ch.isLetter || ch.isNumber || ch == "_" {
                token.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }
}
