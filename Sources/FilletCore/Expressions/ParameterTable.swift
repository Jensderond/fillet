import Foundation

/// Evaluates a document's parameters in dependency order.
///
/// Parameters may reference each other in any order of declaration. Cycles,
/// unknown names, invalid/duplicate names and evaluation errors are recorded
/// per parameter in ``errors``; the remaining parameters still evaluate.
public struct ParameterTable: Sendable {
    /// Evaluated values by parameter name (base units: mm / degrees).
    public private(set) var values: [String: Quantity] = [:]
    /// Errors by parameter id.
    public private(set) var errors: [UUID: EvalError] = [:]
    /// Ids of successfully evaluated parameters, in evaluation (dependency) order.
    public private(set) var order: [UUID] = []

    /// An evaluator for feature expressions using these parameters.
    public let evaluator: Evaluator

    public init(_ parameters: [Parameter]) {
        var byName: [String: Parameter] = [:]
        var parsed: [UUID: ExprNode] = [:]
        var errors: [UUID: EvalError] = [:]

        for p in parameters {
            if let problem = Parameter.validationError(forName: p.name) {
                errors[p.id] = EvalError(problem)
            } else if byName[p.name] != nil {
                errors[p.id] = EvalError("Another parameter is already named '\(p.name)'")
            } else {
                byName[p.name] = p
            }
            do throws(EvalError) {
                parsed[p.id] = try ExprParser.parse(p.expression.source)
            } catch {
                if errors[p.id] == nil { errors[p.id] = error }
            }
        }

        var values: [String: Quantity] = [:]
        var failed: [String: EvalError] = [:]
        var order: [UUID] = []
        var visiting: [String] = []  // current DFS stack, for cycle reporting

        func visit(_ name: String) {
            guard values[name] == nil, failed[name] == nil, let p = byName[name] else { return }
            if let existing = errors[p.id] { failed[name] = existing; return }
            guard let node = parsed[p.id] else { return }
            if let start = visiting.firstIndex(of: name) {
                let chain = (visiting[start...] + [name]).joined(separator: " → ")
                for n in visiting[start...] {
                    if let q = byName[n] { errors[q.id] = EvalError("Circular reference: \(chain)") }
                    failed[n] = EvalError("Circular reference: \(chain)")
                }
                return
            }
            visiting.append(name)
            for dep in node.identifiers.sorted() where byName[dep] != nil { visit(dep) }
            visiting.removeLast()
            if failed[name] != nil { return }  // marked as part of a cycle
            let ev = Evaluator(values: values, failedParameters: failed)
            do throws(EvalError) {
                values[name] = try ev.evaluate(node)
                order.append(p.id)
            } catch {
                errors[p.id] = error
                failed[name] = error
            }
        }

        for p in parameters where byName[p.name]?.id == p.id { visit(p.name) }

        self.values = values
        self.errors = errors
        self.order = order
        self.evaluator = Evaluator(values: values, failedParameters: failed)
    }
}
