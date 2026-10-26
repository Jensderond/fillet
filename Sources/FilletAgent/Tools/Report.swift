import FilletCore
import FilletKernel
import Foundation

/// Applies a change the safe way: evaluate it first, refuse it when it breaks something,
/// then commit it as one undoable step.
@MainActor
enum Change {
    /// - Parameters:
    ///   - newFeature: a step being added; it must evaluate cleanly.
    ///   - allowFailures: commit even when other steps start failing.
    ///
    /// Checking takes time, and in the app the user can edit meanwhile; the change is then
    /// rebuilt on their edit instead of overwriting it.
    static func apply(
        _ ws: any DesignWorkspace, action: String, newFeature: UUID? = nil, allowFailures: Bool = false,
        _ mutate: (inout Document) throws -> Void
    ) async throws -> (model: EvaluatedModel, warnings: [String]) {
        for _ in 0..<5 {
            let base = ws.document
            let before = await ws.evaluated()
            guard base == ws.document else { continue }
            var doc = base
            try mutate(&doc)
            guard doc != base else { return (before, []) }
            let candidate = await ws.preview(doc)
            guard base == ws.document else { continue }
            try check(candidate, before: before, doc: doc, newFeature: newFeature, allowFailures: allowFailures)
            let warnings = drift(candidate, before: before, doc: doc, newFeature: newFeature)
            // No suspension between the check above and the commit's write, so nothing slips in between.
            return (await ws.commit(doc, action: action), warnings)
        }
        throw ToolError("The design kept changing while this step was checked (is the user editing?). Try again.")
    }

    private static func check(
        _ candidate: EvaluatedModel, before: EvaluatedModel, doc: Document, newFeature: UUID?, allowFailures: Bool
    ) throws {
        if let id = newFeature, case .failed(let reason) = candidate.status[id] {
            let name = doc.feature(id)?.name ?? "The step"
            throw ToolError("\(name) failed: \(reason). Nothing was changed.")
        }
        if let id = newFeature, let problem = brokenBody(candidate, before: before, step: id, doc: doc) {
            throw ToolError("\(doc.feature(id)?.name ?? "The step") failed: \(problem). Nothing was changed.")
        }
        let broken = doc.features.compactMap { f -> String? in
            guard f.id != newFeature, case .failed(let reason) = candidate.status[f.id] else { return nil }
            if case .failed = before.status[f.id] { return nil }
            return "\(f.name): \(reason)"
        }
        if !broken.isEmpty, !allowFailures {
            throw ToolError("Refused: this change makes \(broken.count == 1 ? "a step" : "\(broken.count) steps") fail — "
                + broken.joined(separator: "; ") + ". Nothing was changed. Pass allow_failures: true to apply it anyway.")
        }
    }

    /// A body the step left broken (no solid, or not a valid one) although it was fine before:
    /// the kernel sometimes returns such a result without failing.
    private static func brokenBody(_ candidate: EvaluatedModel, before: EvaluatedModel, step: UUID, doc: Document) -> String? {
        for b in candidate.bodies where b.lastFeature == step {
            let noSolid = b.shape.solidCount == 0
            guard noSolid || !b.shape.isValid else { continue }
            // Only blame the step for what it broke.
            if let old = before.body(b.ref), old.shape.solidCount == 0 || !old.shape.isValid { continue }
            let name = doc.feature(b.ref.feature)?.name ?? b.name
            return noSolid ? "it would leave “\(name)” without a closed solid" : "it would leave “\(name)” an invalid solid"
        }
        return nil
    }

    /// Steps that still work but whose face/edge references now land somewhere else, or only
    /// vaguely: a found face/edge much further from where it was picked than before the change,
    /// a match that has become ambiguous, or two references that now find the same edge.
    static func drift(_ candidate: EvaluatedModel, before: EvaluatedModel, doc: Document, newFeature: UUID?) -> [String] {
        doc.features.compactMap { f -> String? in
            guard f.id != newFeature, candidate.status[f.id] == .ok, before.status[f.id] == .ok,
                  let now = candidate.references[f.id], let was = before.references[f.id], now.count == was.count
            else { return nil }
            var moved: [Double] = [], ambiguous = 0
            for (n, w) in zip(now, was) {
                guard let n, let w else { continue }
                if n.score > w.score + driftScore { moved.append(n.offset) }
                if n.isAmbiguous, !w.isAmbiguous { ambiguous += 1 }
            }
            let distinct = { (refs: [ResolvedReference?]) in Set(refs.compactMap { $0?.index }).count }
            let merged = distinct(was) - distinct(now)
            var problems: [String] = []
            let noun = ["shell", "layFlat", "hole", "pressPull"].contains(f.kind.typeName) ? "face" : "edge"
            if !moved.isEmpty {
                let far = String(format: "%.1f", moved.max() ?? 0)
                problems.append(now.count == 1 ? "its \(noun) is now found \(far) mm from where it was picked"
                    : "\(moved.count) of its \(now.count) \(noun)s \(moved.count == 1 ? "is" : "are") now found up to \(far) mm from where \(moved.count == 1 ? "it was" : "they were") picked")
            }
            if ambiguous > 0 { problems.append("\(ambiguous) \(noun)\(ambiguous == 1 ? " has" : "s have") two equally good matches") }
            if merged > 0 { problems.append("\(merged + 1) of its \(noun)s now find the same \(noun)") }
            guard !problems.isEmpty else { return nil }
            return "“\(f.name)” may now work on different \(noun)s: " + problems.joined(separator: "; ")
                + ". Check it with render_view; to pick them again, delete it and add it anew (e.g. with {\"created_by\": …})."
        }
    }

    /// How much worse a reference's match score may get before it counts as landing elsewhere
    /// (a quarter of the model's size away costs 1).
    static let driftScore = 0.3

    /// A name for a new step: the agent's choice (made unique) or "Base N".
    static func uniqueName(_ requested: String?, base: String, in doc: Document) -> String {
        let names = Set(doc.features.map { $0.name.lowercased() })
        if let requested = requested?.trimmingCharacters(in: .whitespaces), !requested.isEmpty {
            if !names.contains(requested.lowercased()) { return requested }
            var n = 2
            while names.contains("\(requested) \(n)".lowercased()) { n += 1 }
            return "\(requested) \(n)"
        }
        var n = 1
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

/// JSON the tools send back.
@MainActor
enum Report {
    static func design(_ ws: any DesignWorkspace, _ model: EvaluatedModel, detail: Bool) -> JSONValue {
        let doc = ws.document
        let r = Resolver(document: doc, model: model)
        let params: [JSONValue] = doc.parameters.map { p in
            var o: [String: JSONValue] = ["name": .string(p.name), "expression": .string(p.expression.source)]
            if let v = model.parameters.values[p.name] { o["value"] = .rounded(v.value, 4) }
            if let e = model.parameters.errors[p.id] { o["error"] = .string(e.message) }
            if !p.comment.isEmpty { o["comment"] = .string(p.comment) }
            return .object(o)
        }
        let steps: [JSONValue] = doc.features.enumerated().map { i, f in
            var o: [String: JSONValue] = [
                "index": .number(Double(i)), "name": .string(f.name), "type": .string(f.kind.typeName),
                "status": Describe.status(model.status[f.id]), "summary": .string(Describe.summary(f, r)),
            ]
            if f.suppressed { o["suppressed"] = true }
            return .object(o)
        }
        var out: [String: JSONValue] = [
            "design": .string(ws.title), "printer": .string(doc.printerPreset.name),
            "bed_size": .vec(doc.printerPreset.bedSize, 0), "parameters": .array(params), "steps": .array(steps),
            "bodies": .array(model.bodies.map { Describe.body($0, r, detail: detail) }),
        ]
        if let i = doc.rollbackIndex { out["rollback_marker"] = .string("only the first \(i) steps are active") }
        return .object(out)
    }

    /// Body names and failures after a change, kept short (get_design has the details), and
    /// warnings about steps the change may have thrown off.
    static func brief(_ ws: any DesignWorkspace, _ model: EvaluatedModel, warnings: [String] = []) -> JSONValue {
        let r = Resolver(document: ws.document, model: model)
        var out: [String: JSONValue] = [
            "steps": .number(Double(ws.document.features.count)),
            "bodies": .array(model.bodies.map { .string(r.bodyLabel($0)) }),
        ]
        let failed = ws.document.features.compactMap { f -> JSONValue? in
            guard case .failed(let reason) = model.status[f.id] else { return nil }
            return .string("\(f.name): \(reason)")
        }
        if !failed.isEmpty { out["failed_steps"] = .array(failed) }
        if !warnings.isEmpty { out["warnings"] = .array(warnings.map { .string($0) }) }
        return .object(out)
    }

    /// What a modeling tool returns: the step it made, the bodies it made or changed, and the body names now.
    static func added(_ ws: any DesignWorkspace, _ model: EvaluatedModel, warnings: [String] = [], feature id: UUID,
                      extra: [String: JSONValue] = [:]) -> ToolResult {
        let r = Resolver(document: ws.document, model: model)
        var out = extra
        if let f = ws.document.feature(id) {
            out["step"] = ["name": .string(f.name), "type": .string(f.kind.typeName), "status": Describe.status(model.status[id])]
            let changed = model.bodies.filter { $0.lastFeature == id }
            if !changed.isEmpty { out["changed_bodies"] = .array(changed.map { Describe.body($0, r, detail: true) }) }
        }
        out["design"] = brief(ws, model, warnings: warnings)
        return .json(.object(out))
    }

    static func feature(_ f: Feature, _ r: Resolver) throws -> JSONValue {
        var out: [String: JSONValue] = [
            "feature": try JSONValue(encoding: f), "status": Describe.status(r.model.status[f.id]),
            "summary": .string(Describe.summary(f, r)),
        ]
        if case .sketch(let s) = f.kind {
            out["shapes"] = .array(s.shapes.enumerated().map { i, shape in
                ["index": .number(Double(i)), "id": .string(shape.id.uuidString), "type": .string(shape.kind.typeName),
                 "construction": .bool(shape.construction)]
            })
            if let e = r.model.sketches[f.id] {
                out["plane"] = Describe.plane(e.plane)
                out["regions"] = Describe.regions(e)
                if !e.shapeErrors.isEmpty {
                    out["shape_errors"] = .object(Dictionary(uniqueKeysWithValues: e.shapeErrors.map { ($0.key.uuidString, .string($0.value)) }))
                }
            }
        }
        if let b = r.model.body(BodyRef(f.id)) { out["body"] = Describe.body(b, r, detail: true) }
        return .object(out)
    }
}
