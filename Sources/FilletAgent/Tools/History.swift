import FilletCore
import Foundation

/// The undo and redo tools: they say exactly what they took back, and refuse to take back the
/// user's own changes (or anything other than what the agent expects) by accident.
extension FilletTools {
    var historyTools: [MCPTool] { [undo, redo] }

    private static let expect = string(
        "The action you mean to undo/redo, e.g. \"New Hat\", \"Edit Hat\", \"Set width\", \"Delete Hat\" (or just the step name). If the next one differs, nothing happens. Needed to undo a change the user made.")

    private var undo: MCPTool {
        MCPTool(
            name: "undo", title: "Undo",
            description: """
                Takes back the last change to the design: a new step, but also an edit, a parameter change, a deletion \
                or a colour. The result says what was taken back. In the app the history is shared with the user: \
                their own changes are only undone when you name them in `expect`.
                """,
            inputSchema: Self.object(["expect": Self.expect])
        ) { args in
            let ws = try host.requireCurrent()
            guard let next = ws.nextUndo() else { return .error("Nothing to undo") }
            let expect = Args(args).optionalString("expect")
            if let expect, !History.matches(expect, next.action) {
                return .error("The last change is “\(next.action)”\(next.byAgent ? "" : ", made by the user"), not “\(expect)”. Nothing was undone.")
            }
            if !next.byAgent, expect == nil {
                return .error("The last change, “\(next.action)”, is the user's own, not yours. Nothing was undone. To undo it anyway, call undo with expect: \"\(next.action)\".")
            }
            let before = ws.document
            guard let action = await ws.undo() else { return .error("Nothing to undo") }
            let model = await ws.evaluated()
            return .json(["undone": .string(action), "by": next.byAgent ? "you" : "the user",
                          "effect": .array(History.effects(from: before, to: ws.document, undo: true).map { .string($0) }),
                          "design": Report.brief(ws, model)])
        }
    }

    private var redo: MCPTool {
        MCPTool(
            name: "redo", title: "Redo", description: "Brings back the last undone change. The result says what it was.",
            inputSchema: Self.object(["expect": Self.expect])
        ) { args in
            let ws = try host.requireCurrent()
            guard let next = ws.nextRedo() else { return .error("Nothing to redo") }
            if let expect = Args(args).optionalString("expect"), !History.matches(expect, next) {
                return .error("The next change to redo is “\(next)”, not “\(expect)”. Nothing was redone.")
            }
            let before = ws.document
            guard let action = await ws.redo() else { return .error("Nothing to redo") }
            let model = await ws.evaluated()
            return .json(["redone": .string(action),
                          "effect": .array(History.effects(from: before, to: ws.document, undo: false).map { .string($0) }),
                          "design": Report.brief(ws, model)])
        }
    }
}

enum History {
    /// Whether `expect` names `action`: the same name, or the step name inside it ("Hat" for
    /// "New Hat"), ignoring case.
    static func matches(_ expect: String, _ action: String) -> Bool {
        let e = expect.trimmingCharacters(in: .whitespaces).lowercased()
        let a = action.lowercased()
        if e == a { return true }
        for prefix in ["new ", "edit ", "delete ", "set ", "color "] where a.hasPrefix(prefix) {
            if String(a.dropFirst(prefix.count)) == e { return true }
        }
        return false
    }

    /// What going from `old` to `new` changed, in sentences: "Removed step “Hat”", "Reverted the
    /// edit of “Peg”"…
    static func effects(from old: Document, to new: Document, undo: Bool) -> [String] {
        var out: [String] = []
        let oldIDs = Set(old.features.map(\.id)), newIDs = Set(new.features.map(\.id))
        for f in old.features where !newIDs.contains(f.id) { out.append("Removed step “\(f.name)”") }
        for f in new.features where !oldIDs.contains(f.id) { out.append("Added step “\(f.name)” back") }
        for f in new.features {
            guard let o = old.feature(f.id), o != f else { continue }
            let name = o.name == f.name ? "“\(f.name)”" : "“\(o.name)” (now “\(f.name)”)"
            out.append(undo ? "Reverted the edit of \(name): its earlier definition is back"
                            : "Redid the edit of \(name)")
        }
        let oldParams = Dictionary(old.parameters.map { ($0.name, $0.expression.source) }, uniquingKeysWith: { a, _ in a })
        let newParams = Dictionary(new.parameters.map { ($0.name, $0.expression.source) }, uniquingKeysWith: { a, _ in a })
        for p in old.parameters {
            if let n = newParams[p.name] {
                if n != p.expression.source { out.append("Parameter \(p.name): \(p.expression.source) → \(n)") }
            } else {
                out.append("Removed parameter \(p.name)")
            }
        }
        for p in new.parameters where oldParams[p.name] == nil { out.append("Added parameter \(p.name) = \(p.expression.source)") }
        let colored = Set(old.bodyColors.keys).union(new.bodyColors.keys).filter { old.bodyColors[$0] != new.bodyColors[$0] }
        for ref in colored {
            let name = new.feature(ref.feature)?.name ?? old.feature(ref.feature)?.name ?? "a body"
            out.append("Colour of “\(name)”: \(old.bodyColors[ref] ?? "default") → \(new.bodyColors[ref] ?? "default")")
        }
        if out.isEmpty, old.features.map(\.id) != new.features.map(\.id) { out.append("Reordered steps") }
        if old.rollbackIndex != new.rollbackIndex { out.append("Moved the rollback marker") }
        if old.name != new.name {
            out.append("Design name: \(old.name.map { "“\($0)”" } ?? "none") → \(new.name.map { "“\($0)”" } ?? "none") (the file keeps its current name)")
        }
        if out.isEmpty, old != new { out.append("Changed design settings (printer or units)") }
        return out
    }
}
