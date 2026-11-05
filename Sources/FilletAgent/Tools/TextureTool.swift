import FilletCore
import Foundation

extension FilletTools {
    /// Puts a surface texture on faces of a body. Built from ``TextureCatalog``: a new pattern
    /// shows up here (in the enum, the description and `values`) without changes to this file.
    var texture: MCPTool {
        let description = """
                Puts a surface texture on faces of a body, e.g. knitted stitches around a vase or dots on a box. \
                The texture displaces the printed mesh (3MF/STL export and the view), not the solid, so later \
                steps still work on the plain body. `faces` omitted or "sides" textures the body's outer side walls \
                (what the app picks by default: never the bed face, a flat top or the inside of a vase); "all" \
                textures every face except the one the body rests on; indices or a filter pick faces. \
                Patterns and their `values` (number or expression; unset ones take the default):
                \(Self.textureCatalogText)
                """
        let patternIDs = TextureCatalog.patterns.map { $0.id.rawValue }
        return MCPTool(
            name: "texture", title: "Texture", description: description,
            inputSchema: Self.object([
                "body": Self.body,
                "faces": Self.textureFaces,
                "pattern": Self.string("Texture pattern", enum: patternIDs),
                "values": Self.textureValuesSchema,
                "name": Self.name,
            ], required: ["body", "pattern"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let b = try r.body(try a.string("body"))
            let pattern = TexturePatternID(try a.string("pattern"))
            guard let displayName = Self.patternName(pattern) else {
                throw ToolError("Unknown pattern “\(pattern)”; use one of \(TextureCatalog.patterns.map { $0.id.rawValue }.joined(separator: ", "))")
            }
            var refs: [FaceRef] = []
            switch a["faces"] {
            case nil, .null, .string("sides"):
                // The app's default; a body without side walls (a flat plate) gets every face but the bed's.
                refs = TextureFaces.outerSides(of: b.shape, mesh: r.model.meshes[b.ref]).compactMap {
                    r.model.faceRef(body: b.ref, face: $0)
                }
            case .string("all"):
                refs = []
            case let faces?:
                for i in try r.faces(of: b, faces, key: "faces") {
                    if let ref = r.model.faceRef(body: b.ref, face: i) { refs.append(ref) }
                }
                if refs.isEmpty { throw ToolError("`faces` matched no faces of \(r.bodyLabel(b))") }
            }
            let values = try Self.textureValues(a["values"], for: pattern)
            return try await add(ws, .texture(Texture(body: b.ref, faces: refs, pattern: pattern, values: values)),
                                 base: displayName, a)
        }
    }

    /// `faces` of the texture tool: the selection forms plus "sides".
    static var textureFaces: JSONValue {
        [
            "description": "\"sides\" (default: the outer side walls), \"all\" (every face but the bed face), indices from list_faces, or a filter object",
            "anyOf": [["type": "array", "items": ["type": "integer"]], ["type": "string", "enum": ["sides", "all"]],
                      filter],
        ]
    }

    static func patternName(_ id: TexturePatternID) -> String? { TextureCatalog.pattern(id)?.displayName }

    /// `values` as expressions, checked against the pattern's parameter ids.
    static func textureValues(_ value: JSONValue?, for pattern: TexturePatternID) throws -> [String: Expr] {
        guard let value, value != .null else { return [:] }
        guard case .object(let fields) = value else { throw ToolError("`values` must be an object of parameter values") }
        let known = TextureCatalog.parameters(for: pattern)
        var out: [String: Expr] = [:]
        for (key, v) in fields {
            guard let p = known.first(where: { $0.id == key }) else {
                throw ToolError("“\(pattern)” has no value `\(key)`; it takes \(known.map(\.id).joined(separator: ", "))")
            }
            if case .bool(let on) = v, p.kind == .toggle { out[key] = on ? 1 : 0; continue }
            if case .string(let s) = v, case .choice(let options) = p.kind, let i = options.firstIndex(of: s) {
                out[key] = Expr(Double(i)); continue
            }
            out[key] = try Args.expr(v, "values.\(key)")
        }
        return out
    }

    /// Every pattern with its parameters, for the tool description.
    static var textureCatalogText: String {
        TextureCatalog.patterns.map { p in
            let params = TextureCatalog.parameters(for: p.id).map(parameterText).joined(separator: "; ")
            return "- \(p.id.rawValue) (\(p.displayName)): \(p.summary) Values: \(params)"
        }.joined(separator: "\n")
    }

    static func parameterText(_ p: TextureParameter) -> String {
        let unit = p.unit.isEmpty ? "" : " \(p.unit)"
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        let kind: String = switch p.kind {
        case .toggle: "true/false, default \(p.defaultValue >= 0.5)"
        case .choice(let options): "one of \(options.joined(separator: "/")), default \(options[Int(p.defaultValue)])"
        default: "\(n(p.range.lowerBound))…\(n(p.range.upperBound))\(unit), default \(n(p.defaultValue))\(unit)"
        }
        return "\(p.id) = \(p.name.lowercased()) (\(kind)\(conditionText(p)))"
    }

    /// ", only when profile = flat disc" for a parameter that applies only with another's values.
    static func conditionText(_ p: TextureParameter) -> String {
        guard let c = p.shownWhen else { return "" }
        let owner = TextureCatalog.patterns.lazy.flatMap { TextureCatalog.parameters(for: $0.id) }
            .first { $0.id == c.parameter }
        let values = c.values.sorted().map { v -> String in
            if case .choice(let options)? = owner?.kind, options.indices.contains(Int(v)) { return options[Int(v)].lowercased() }
            if owner?.kind == .toggle { return v >= 0.5 ? "true" : "false" }
            return v == v.rounded() ? String(Int(v)) : String(v)
        }
        return ", only applies when \(c.parameter) = \(values.joined(separator: " or "))"
    }

    /// One property per parameter id across all patterns.
    static var textureValuesSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for p in TextureCatalog.patterns {
            for q in TextureCatalog.parameters(for: p.id) where properties[q.id] == nil {
                let description = "\(q.name): \(q.help.isEmpty ? "" : q.help + ". ")" + parameterText(q)
                properties[q.id] = switch q.kind {
                case .toggle: ["type": ["boolean", "number", "string"], "description": .string(description)]
                default: ["type": ["number", "string"], "description": .string(description)]
                }
            }
        }
        return ["type": "object", "description": "Pattern values by id (see the pattern list)",
                "properties": .object(properties), "additionalProperties": false]
    }
}
