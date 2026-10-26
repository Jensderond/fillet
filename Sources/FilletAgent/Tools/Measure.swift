import FilletCore
import FilletKernel
import Foundation

/// The `measure` tool: what the app's Measure shows, for agents. Bodies (volume, area, bounds),
/// one face or edge (area, length, radius), and between two things the minimum distance with the
/// closest points, ΔX/ΔY/ΔZ and the angle between flat faces and straight edges.
extension FilletTools {
    private static let element: JSONValue = [
        "type": ["integer", "object"],
        "description": "An index from list_faces/list_edges, or a filter object that matches exactly one",
    ]

    var measure: MCPTool {
        MCPTool(
            name: "measure", title: "Measure",
            description: """
                Measures like the app's Measure tool. Without arguments: volume, area, bounds and validity of every body. \
                With `body`: that body, or one of its faces (`face`) or edges (`edge`): area, length, radius of circular \
                edges and cylindrical/spherical faces. With a second thing (`to` body and/or `to_face`/`to_edge`, which \
                default to the first body): the minimum distance (0 = touching), the closest points, dx/dy/dz between them, \
                and the angle in degrees between flat faces (between their outward normals, 0–180) or straight edges (0–90).
                """,
            inputSchema: Self.object([
                "body": Self.body, "face": Self.element, "edge": Self.element,
                "to": Self.string("Second body (default: the first one, when to_face or to_edge is given)"),
                "to_face": Self.element, "to_edge": Self.element,
            ]),
            readOnly: true
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = Resolver(document: ws.document, model: await ws.evaluated())
            guard let name = a.optionalString("body") else {
                return .json(["bodies": .array(r.model.bodies.map { Describe.body($0, r, detail: true) })])
            }
            let b = try r.body(name)
            let first = try MeasureArgs.element(a, r, b, face: "face", edge: "edge")
            var out: [String: JSONValue] = [:]
            if first == .body { out["body"] = Describe.body(b, r, detail: true) } else { out["first"] = MeasureArgs.describe(b, first, r) }

            let toName = a.optionalString("to")
            guard toName != nil || a["to_face"] != nil || a["to_edge"] != nil else { return .json(.object(out)) }
            let o = try toName.map { try r.body($0) } ?? b
            let second = try MeasureArgs.element(a, r, o, face: "to_face", edge: "to_edge")
            out["second"] = MeasureArgs.describe(o, second, r)
            guard let pair = Measure.pair((b.shape, first), (o.shape, second)) else {
                return .error("Couldn't measure between them")
            }
            out["distance"] = .rounded(pair.distance, 3)
            out["closest_points"] = [.vec(pair.pointA, 3), .vec(pair.pointB, 3)]
            out["dx"] = .rounded(pair.delta.x, 3)
            out["dy"] = .rounded(pair.delta.y, 3)
            out["dz"] = .rounded(pair.delta.z, 3)
            if let angle = pair.angle { out["angle_degrees"] = .rounded(angle * 180 / .pi, 3) }
            return .json(.object(out))
        }
    }
}

enum MeasureArgs {
    /// The face or edge named by `face`/`edge` (an index or a filter matching one), else the body.
    @MainActor static func element(_ a: Args, _ r: Resolver, _ b: EvaluatedBody, face: String, edge: String) throws -> MeasureElement {
        func one(_ v: JSONValue, _ found: [Int], _ key: String, _ noun: String) throws -> Int {
            guard found.count == 1 else {
                throw ToolError("`\(key)` matches \(found.count) \(noun)s of “\(r.bodyLabel(b))”; measure one at a time (add a filter, or give an index)")
            }
            return found[0]
        }
        if let v = a[face] {
            return .face(try one(v, try r.faces(of: b, v.int != nil ? .array([v]) : v, key: face), face, "face"))
        }
        if let v = a[edge] {
            return .edge(try one(v, try r.edges(of: b, v.int != nil ? .array([v]) : v, key: edge), edge, "edge"))
        }
        return .body
    }

    @MainActor static func describe(_ b: EvaluatedBody, _ element: MeasureElement, _ r: Resolver) -> JSONValue {
        guard let m = Measure.item(b.shape, element) else { return .null }
        var o: [String: JSONValue] = ["body": .string(r.bodyLabel(b))]
        switch element {
        case .body: o["what"] = "body"
        case .face(let i): o["face"] = .number(Double(i))
        case .edge(let i): o["edge"] = .number(Double(i))
        case .vertex(let i): o["vertex"] = .number(Double(i))
        }
        if let s = m.surface { o["surface"] = .string(Describe.surfaceName(s)) }
        if let c = m.curve { o["curve"] = .string("\(c)") }
        if let v = m.length { o["length"] = .rounded(v, 3) }
        if let v = m.radius { o["radius"] = .rounded(v, 3) }
        if let v = m.area { o["area"] = .rounded(v, 3) }
        if let v = m.volume { o["volume"] = .rounded(v, 3) }
        if let v = m.size { o["size"] = .vec(v, 3) }
        if let v = m.position { o["position"] = .vec(v, 3) }
        return .object(o)
    }
}
