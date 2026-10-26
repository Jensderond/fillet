import FilletCore
import FilletKernel
import Foundation

extension FilletTools {
    var modelingTools: [MCPTool] {
        [setParameter, deleteParameter, createSketch, addSketchShapes, extrude, revolve, primitive,
         loft, fillet, chamfer, shell, combine, moveBodies, scaleBodies, mirror, pattern, layFlat,
         editFeature, deleteFeature, setBodyColor, export]
    }

    // MARK: Parameters

    private var setParameter: MCPTool {
        MCPTool(
            name: "set_parameter", title: "Set parameter",
            description: "Creates or changes a named parameter (e.g. width = 40 mm) that any value can use in an expression.",
            inputSchema: Self.object([
                "name": Self.string("Parameter name (letters, digits, underscore)"),
                "expression": Self.expr("Value, e.g. 40, \"40 mm\", \"width/2\", \"30 deg\""),
                "comment": Self.string("What it controls"),
                "allow_failures": Self.allowFailures,
            ], required: ["name", "expression"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let name = try a.string("name")
            if let problem = Parameter.validationError(forName: name) { throw ToolError(problem) }
            let expression = try a.expr("expression")
            let (model, warnings) = try await Change.apply(ws, action: "Set \(name)", allowFailures: a.bool("allow_failures", default: false)) { doc in
                if let i = doc.parameters.firstIndex(where: { $0.name == name }) {
                    doc.parameters[i].expression = expression
                    if let c = a.optionalString("comment") { doc.parameters[i].comment = c }
                } else {
                    doc.parameters.append(Parameter(name: name, expression: expression, comment: a.optionalString("comment") ?? ""))
                }
            }
            guard let p = ws.document.parameters.first(where: { $0.name == name }) else { return .error("Parameter not saved") }
            if let e = model.parameters.errors[p.id] { return .error("\(name) = \(expression): \(e.message)") }
            let value = model.parameters.values[name].map { JSONValue.rounded($0.value, 4) } ?? .null
            return .json(["parameter": .string(name), "value": value, "design": Report.brief(ws, model, warnings: warnings)])
        }
    }

    private var deleteParameter: MCPTool {
        MCPTool(
            name: "delete_parameter", title: "Delete parameter", description: "Removes a parameter.",
            inputSchema: Self.object(["name": Self.string("Parameter name"), "allow_failures": Self.allowFailures], required: ["name"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let name = try a.string("name")
            guard ws.document.parameters.contains(where: { $0.name == name }) else { throw ToolError("No parameter named \(name)") }
            let (model, warnings) = try await Change.apply(ws, action: "Delete \(name)", allowFailures: a.bool("allow_failures", default: false)) {
                $0.parameters.removeAll { $0.name == name }
            }
            return .json(["deleted": .string(name), "design": Report.brief(ws, model, warnings: warnings)])
        }
    }

    // MARK: Sketches

    private static let shapesSchema: JSONValue = [
        "type": "array",
        "description": """
            Sketch shapes in sketch coordinates [u, v] (mm). Each is an object with "type" and its fields; every number \
            may be an expression; add "construction": true for reference geometry that makes no profiles:
            {"type":"line","a":[u,v],"b":[u,v]}
            {"type":"rectangle","anchor":"corner"|"center","position":[u,v],"width":w,"height":h,"angle":deg}
            {"type":"circle","center":[u,v],"diameter":d}
            {"type":"arc","start":[u,v],"through":[u,v],"end":[u,v]}
            {"type":"polygon","center":[u,v],"sides":6,"radius":r,"inscribed":true,"angle":deg}
            {"type":"slot","a":[u,v],"b":[u,v],"width":w}
            {"type":"polyline","vertices":[[u,v],[u,v,bulge],…],"closed":true}  (bulge: signed arc sagitta in mm for the segment leaving that vertex, + bulges left)
            {"type":"spline","points":[[u,v],…]}  (smooth curve through the points; close the profile with lines or other shapes that share its end points)
            {"type":"point","position":[u,v]}
            Closed loops (and loops formed by shapes meeting end to end) become profile regions.
            """,
        "items": ["type": "object", "properties": ["type": ["type": "string"]], "required": ["type"]],
    ]

    private var createSketch: MCPTool {
        MCPTool(
            name: "create_sketch", title: "Sketch",
            description: "Creates a sketch of 2D shapes on a plane or flat face. Returns its closed regions (profiles) with index, area and an inside point, ready for extrude or revolve.",
            inputSchema: Self.object([
                "name": Self.name, "plane": Self.plane,
                "offset": Self.expr("Offset of an origin plane along its normal (xz's normal is −Y)"),
                "shapes": Self.shapesSchema,
            ], required: ["shapes"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let plane = try r.plane(a["plane"], offset: try a.optionalExpr("offset"))
            let shapes = try ShapeInput.shapes(a["shapes"])
            let feature = Feature(name: Change.uniqueName(a.optionalString("name"), base: "Sketch", in: ws.document),
                                  .sketch(Sketch(plane: plane, shapes: shapes)))
            let (model, warnings) = try await Change.apply(ws, action: "New \(feature.name)", newFeature: feature.id) { _ = $0.addFeature(feature) }
            return Report.added(ws, model, warnings: warnings, feature: feature.id, extra: Self.sketchInfo(feature, model))
        }
    }

    private var addSketchShapes: MCPTool {
        MCPTool(
            name: "add_sketch_shapes", title: "Add to sketch",
            description: "Adds shapes to an existing sketch. Steps that use the sketch's profiles keep their regions by inside point.",
            inputSchema: Self.object(["sketch": Self.string("Sketch name"), "shapes": Self.shapesSchema,
                                      "allow_failures": Self.allowFailures], required: ["sketch", "shapes"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            var (feature, sketch, _) = try r.sketch(try a.string("sketch"))
            sketch.shapes += try ShapeInput.shapes(a["shapes"])
            feature.kind = .sketch(sketch)
            let (model, warnings) = try await Change.apply(ws, action: "Edit \(feature.name)", newFeature: feature.id,
                                               allowFailures: a.bool("allow_failures", default: false)) { try $0.updateFeature(feature) }
            return Report.added(ws, model, warnings: warnings, feature: feature.id, extra: Self.sketchInfo(feature, model))
        }
    }

    static func sketchInfo(_ f: Feature, _ model: EvaluatedModel) -> [String: JSONValue] {
        guard case .sketch(let s) = f.kind, let e = model.sketches[f.id] else { return [:] }
        return [
            "plane": Describe.plane(e.plane),
            "shapes": .array(s.shapes.enumerated().map { i, shape in
                ["index": .number(Double(i)), "id": .string(shape.id.uuidString), "type": .string(shape.kind.typeName)]
            }),
            "regions": Describe.regions(e),
        ]
    }

    // MARK: Solids from sketches

    private static let regions: JSONValue = [
        "description": "\"all\" (default), region indices from the sketch, or [[u, v]] points inside the wanted profiles. With nested shapes, \"all\" fills the holes too — pick the ring's index to keep a hole.",
        "anyOf": [["type": "string", "enum": ["all"]], ["type": "array"]],
    ]

    private var extrude: MCPTool {
        MCPTool(
            name: "extrude", title: "Extrude",
            description: "Extrudes sketch profiles along the sketch normal into a new body, or joins/cuts/intersects existing bodies.",
            inputSchema: Self.object([
                "sketch": Self.string("Sketch name"), "regions": Self.regions,
                "distance": Self.expr("Along the sketch normal; negative goes the other way"),
                "back": Self.expr("Optional extra distance in the opposite direction"),
                "symmetric": Self.boolean("Split the distance equally to both sides"),
                "taper": Self.expr("Draft angle in degrees"),
                "operation": Self.operation, "targets": Self.bodies, "name": Self.name,
            ], required: ["sketch", "distance"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let (sk, _, eval) = try r.sketch(try a.string("sketch"))
            let regions = try r.regions(a["regions"], sketch: eval, name: sk.name)
            let targets = try a["targets"].map { try r.bodies($0, key: "targets").map(\.ref) } ?? []
            let e = Extrude(sketch: sk.id, regions: regions, distance: try a.expr("distance"), back: try a.optionalExpr("back"),
                            symmetric: a.bool("symmetric", default: false), taper: try a.expr("taper", default: 0),
                            operation: try a.operation(default: .newBody), targets: targets)
            return try await add(ws, .extrude(e), base: "Extrude", a)
        }
    }

    private var revolve: MCPTool {
        MCPTool(
            name: "revolve", title: "Revolve",
            description: "Revolves sketch profiles around an axis in the sketch. For round parts, sketch half the profile on \"xz\" (u ≥ 0) and revolve around \"y\" (= world Z).",
            inputSchema: Self.object([
                "sketch": Self.string("Sketch name"), "regions": Self.regions,
                "axis": ["description": "\"x\" (sketch u axis), \"y\" (sketch v axis), or {\"line\": index or id of a line shape in the sketch}",
                         "anyOf": [["type": "string", "enum": ["x", "y"]], ["type": "object"]]],
                "angle": Self.expr("Degrees (default 360)"), "operation": Self.operation, "targets": Self.bodies, "name": Self.name,
            ], required: ["sketch", "axis"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let (sk, sketch, eval) = try r.sketch(try a.string("sketch"))
            let regions = try r.regions(a["regions"], sketch: eval, name: sk.name)
            let axis: RevolveAxis
            switch a["axis"] {
            case .string("x"): axis = .x
            case .string("y"): axis = .y
            case .some(let v) where v["line"] != nil:
                let line = v["line"]!
                let shape: SketchShape? = line.int.flatMap { sketch.shapes.indices.contains($0) ? sketch.shapes[$0] : nil }
                    ?? line.string.flatMap(UUID.init(uuidString:)).flatMap(sketch.shape)
                guard let shape, case .line = shape.kind else { throw ToolError("`axis.line` must be the index or id of a line in \(sk.name)") }
                axis = .sketchLine(shape.id)
            default: throw ToolError("`axis` must be \"x\", \"y\" or {\"line\": index}")
            }
            let targets = try a["targets"].map { try r.bodies($0, key: "targets").map(\.ref) } ?? []
            let rv = Revolve(sketch: sk.id, regions: regions, axis: axis, angle: try a.expr("angle", default: 360),
                             operation: try a.operation(default: .newBody), targets: targets)
            return try await add(ws, .revolve(rv), base: "Revolve", a)
        }
    }

    // MARK: Primitives

    private var primitive: MCPTool {
        MCPTool(
            name: "primitive", title: "Primitive",
            description: """
                Adds a box, cylinder, sphere, cone or torus. Dimensions: box {width, depth, height}; cylinder {diameter, height}; \
                sphere {diameter}; cone {bottom_diameter, top_diameter, height} (top 0 = pointed); torus {major_diameter, minor_diameter}. \
                "radius" may stand in for a diameter. Box is centred on the position and stands on the plane; cylinder/cone bases are \
                centred on it with the axis along the plane normal; sphere and torus are centred on it.
                """,
            inputSchema: Self.object([
                "kind": Self.string("Solid", enum: PrimitiveKind.allCases.map(\.rawValue)),
                "dimensions": ["type": "object", "description": "Named dimensions (numbers or expressions)"],
                "at": Self.vec3("Shortcut: place on the XY plane at [x, y, z] (z = height of the base / centre)"),
                "plane": Self.plane, "offset": Self.expr("Origin-plane offset along its normal"),
                "position": ["type": "array", "description": "[u, v] on the plane (default [0, 0])"],
                "operation": Self.operation, "targets": Self.bodies, "name": Self.name,
            ], required: ["kind", "dimensions"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            guard let kind = PrimitiveKind(rawValue: try a.string("kind")) else {
                throw ToolError("`kind` must be one of box, cylinder, sphere, cone, torus")
            }
            let dims = try Self.dimensions(kind, a["dimensions"])
            var plane: SketchPlaneRef
            var position = Point2Expr.origin
            if let at = try a.vec3("at") {
                plane = .standard(.xy, offset: at.z)
                position = Point2Expr(at.x, at.y)
            } else {
                plane = try r.plane(a["plane"], offset: try a.optionalExpr("offset"))
                if let p = try a.point2("position") { position = p }
            }
            let targets = try a["targets"].map { try r.bodies($0, key: "targets").map(\.ref) } ?? []
            let p = Primitive(kind: kind, plane: plane, position: position, dimensions: dims,
                              operation: try a.operation(default: .newBody), targets: targets)
            return try await add(ws, .primitive(p), base: kind.rawValue.capitalized, a)
        }
    }

    static func dimensions(_ kind: PrimitiveKind, _ value: JSONValue?) throws -> [Expr] {
        if let array = value?.array {
            guard array.count == kind.dimensionNames.count else {
                throw ToolError("\(kind.rawValue) needs \(kind.dimensionNames.count) dimensions: \(kind.dimensionNames.joined(separator: ", "))")
            }
            return try array.map { try Args.expr($0, "dimensions") }
        }
        guard let o = value?.object else { throw ToolError("`dimensions` must be an object like {\"diameter\": 10}") }
        let d = Args(.object(o))
        func diameter(_ key: String, radiusKey: String) throws -> Expr {
            if let e = try d.optionalExpr(key) { return e }
            if let v = d[radiusKey] {
                if let n = v.number { return Expr(n * 2) }
                return Expr("2 * (\(try Args.expr(v, radiusKey).source))")
            }
            throw ToolError("\(kind.rawValue) needs `\(key)` (or `\(radiusKey)`)")
        }
        switch kind {
        case .box: return [try d.expr("width"), try d.expr("depth"), try d.expr("height")]
        case .cylinder: return [try diameter("diameter", radiusKey: "radius"), try d.expr("height")]
        case .sphere: return [try diameter("diameter", radiusKey: "radius")]
        case .cone:
            return [try diameter("bottom_diameter", radiusKey: "bottom_radius"),
                    (try? diameter("top_diameter", radiusKey: "top_radius")) ?? 0, try d.expr("height")]
        case .torus:
            return [try diameter("major_diameter", radiusKey: "major_radius"), try diameter("minor_diameter", radiusKey: "minor_radius")]
        }
    }

    // MARK: Loft

    private var loft: MCPTool {
        MCPTool(
            name: "loft", title: "Loft",
            description: """
                Skins a smooth solid through cross-sections in order. Each section: {"center": [x,y,z], "diameter": d} for a \
                circle, or {"width": w, "height": h} for an ellipse ("angle" turns the width direction around the normal). \
                "normal" [x,y,z] is the direction the loft travels through the section; leave it out and it follows the line \
                through the neighbouring centres. A first or last section with diameter 0 ends in a point. For a curl, put \
                sections along an arc with shrinking sizes, close enough together that neighbours don't cross.
                """,
            inputSchema: Self.object([
                "sections": ["type": "array", "minItems": 2, "items": ["type": "object"], "description": "Sections in order"],
                "ruled": Self.boolean("Straight between sections (default false: one smooth surface)"),
                "operation": Self.operation, "targets": Self.bodies, "name": Self.name,
            ], required: ["sections"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            guard let list = a["sections"]?.array, list.count >= 2 else { throw ToolError("`sections` needs at least two sections") }
            let sections = try list.enumerated().map { i, v -> Loft.Section in
                let s = Args(v)
                let key = "sections[\(i)]"
                guard let center = try s.vec3("center") else { throw ToolError("\(key).center is required ([x, y, z])") }
                let width: Expr
                var height: Expr?
                if let d = try s.optionalExpr("diameter") {
                    width = d
                } else if let r = s["radius"] {
                    if let n = r.number { width = Expr(n * 2) } else { width = Expr("2 * (\(try Args.expr(r, key).source))") }
                } else if let w = try s.optionalExpr("width") {
                    width = w
                    height = try s.optionalExpr("height")
                } else {
                    throw ToolError("\(key) needs a diameter, or a width and height")
                }
                return Loft.Section(center: center, normal: try s.vec3("normal") ?? Self.travelDirection(list, at: i), width: width,
                                    height: height, angle: try s.optionalExpr("angle"))
            }
            let targets = try a["targets"].map { try r.bodies($0, key: "targets").map(\.ref) } ?? []
            let l = Loft(sections: sections, ruled: a.bool("ruled", default: false),
                         operation: try a.operation(default: .newBody), targets: targets)
            return try await add(ws, .loft(l), base: "Loft", a)
        }
    }

    /// A section's default normal: the way the loft travels there, from the previous to the next
    /// section centre (numeric centres only; otherwise straight up).
    static func travelDirection(_ sections: [JSONValue], at i: Int) -> Vec3Expr {
        func center(_ j: Int) -> Vec3? { try? Args.point3(sections[j]["center"], "center") }
        guard let a = center(max(i - 1, 0)), let b = center(min(i + 1, sections.count - 1)) else { return Vec3Expr(0, 0, 1) }
        let d = b - a
        guard d.length > 1e-9 else { return Vec3Expr(0, 0, 1) }
        let n = d.normalized
        func r(_ v: Double) -> Expr { Expr((v * 10_000).rounded() / 10_000) }
        return Vec3Expr(r(n.x), r(n.y), r(n.z))
    }

    // MARK: Modify

    private var fillet: MCPTool {
        MCPTool(
            name: "fillet", title: "Fillet",
            description: "Rounds edges of a body. The radius must fit the faces next to the edges (use a smaller one if it fails).",
            inputSchema: Self.object(["body": Self.body, "edges": Self.selection, "radius": Self.expr("Fillet radius"), "name": Self.name],
                                     required: ["body", "edges", "radius"])
        ) { args in try await edgeFeature(args, fillet: true) }
    }

    private var chamfer: MCPTool {
        MCPTool(
            name: "chamfer", title: "Chamfer", description: "Bevels edges of a body.",
            inputSchema: Self.object(["body": Self.body, "edges": Self.selection, "distance": Self.expr("Chamfer distance"), "name": Self.name],
                                     required: ["body", "edges", "distance"])
        ) { args in try await edgeFeature(args, fillet: false) }
    }

    private func edgeFeature(_ args: JSONValue, fillet: Bool) async throws -> ToolResult {
        let a = Args(args)
        let ws = try host.requireCurrent()
        let r = try await Resolver.load(ws, args)
        let b = try r.body(try a.string("body"))
        let refs = try r.edges(of: b, a["edges"], key: "edges", forRounding: true).compactMap { r.model.edgeRef(body: b.ref, edge: $0) }
        let e = EdgeFeature(body: b.ref, edges: refs, size: try a.expr(fillet ? "radius" : "distance"))
        return try await add(ws, fillet ? .fillet(e) : .chamfer(e), base: fillet ? "Fillet" : "Chamfer", a)
    }

    private var shell: MCPTool {
        MCPTool(
            name: "shell", title: "Shell",
            description: "Hollows a body to a wall thickness, opening the given faces (none = closed hollow).",
            inputSchema: Self.object(["body": Self.body, "remove_faces": Self.selection,
                                      "thickness": Self.expr("Wall thickness (inward)"), "name": Self.name],
                                     required: ["body", "thickness"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let b = try r.body(try a.string("body"))
            let faces = try a["remove_faces"].map { try r.faces(of: b, $0, key: "remove_faces") } ?? []
            let refs = faces.compactMap { r.model.faceRef(body: b.ref, face: $0) }
            return try await add(ws, .shell(Shell(body: b.ref, removeFaces: refs, thickness: try a.expr("thickness"))), base: "Shell", a)
        }
    }

    private var combine: MCPTool {
        MCPTool(
            name: "combine", title: "Combine",
            description: "Boolean of bodies: joins the tools into the target, cuts them from it, or keeps the intersection.",
            inputSchema: Self.object([
                "target": Self.body, "tools": Self.bodies,
                "operation": Self.string("Default join", enum: ["join", "cut", "intersect"]),
                "keep_tools": Self.boolean("Keep the tool bodies (default false)"), "name": Self.name,
            ], required: ["target", "tools"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let target = try r.body(try a.string("target"))
            let tools = try r.bodies(a["tools"], key: "tools").map(\.ref).filter { $0 != target.ref }
            guard !tools.isEmpty else { throw ToolError("`tools` must name bodies other than the target") }
            let c = Combine(target: target.ref, tools: tools, operation: try a.operation(default: .join),
                            keepTools: a.bool("keep_tools", default: false))
            return try await add(ws, .combine(c), base: "Combine", a)
        }
    }

    private var moveBodies: MCPTool {
        MCPTool(
            name: "move_bodies", title: "Move",
            description: "Rotates and/or translates bodies. Rotations run first, in order, each about an axis through `center` (default the origin); then the translation.",
            inputSchema: Self.object([
                "bodies": Self.bodies, "translate": Self.vec3("[x, y, z] offset in mm"),
                "rotate": [
                    "description": "One rotation {\"axis\": \"x\"|\"y\"|\"z\"|{body, edge}, \"angle\": degrees, \"center\": [x,y,z]} or a list of them",
                    "anyOf": [["type": "object"], ["type": "array", "items": ["type": "object"]]],
                ],
                "name": Self.name,
            ], required: ["bodies"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let bodies = try r.bodies(a["bodies"], key: "bodies").map(\.ref)
            let rotations = a["rotate"].map { $0.array ?? [$0] } ?? []
            var moves: [Move] = try rotations.map { rot in
                let ra = Args(rot)
                return Move(bodies: bodies, rotationAxis: try r.axis(ra["axis"], key: "rotate.axis"),
                            rotationAngle: try ra.expr("angle"), rotationCenter: try ra.vec3("center"))
            }
            let translation = try a.vec3("translate") ?? .zero
            if moves.isEmpty { moves = [Move(bodies: bodies)] }
            moves[moves.count - 1].translation = translation
            if moves.count == 1, translation == .zero, moves[0].rotationAngle.source == "0" {
                throw ToolError("Give `translate` and/or `rotate`")
            }
            // One step per rotation ("Hat tilt", "Hat tilt 2", …), added as one undoable change.
            var scratch = ws.document
            var features: [Feature] = []
            for m in moves {
                let name = Change.uniqueName(features.first?.name ?? a.optionalString("name"), base: "Move", in: scratch)
                let f = Feature(name: name, .move(m))
                scratch.features.append(f)
                features.append(f)
            }
            let (model, warnings) = try await Change.apply(ws, action: features[0].name, newFeature: features.last?.id) { d in
                for f in features { _ = d.addFeature(f) }
            }
            return Report.added(ws, model, warnings: warnings, feature: features.last!.id,
                                extra: ["steps_added": .array(features.map { .string($0.name) })])
        }
    }

    private var scaleBodies: MCPTool {
        MCPTool(
            name: "scale_bodies", title: "Scale",
            description: "Scales bodies about a centre point, separately along X, Y and Z if you like (a sphere becomes an ellipsoid). The centre defaults to the middle of the bodies' bounds.",
            inputSchema: Self.object([
                "bodies": Self.bodies,
                "factors": ["description": "One factor for all axes, or [x, y, z] factors (1 = unchanged)",
                            "anyOf": [["type": "number"], ["type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 3]]],
                "center": Self.vec3("Point that stays put"), "name": Self.name,
            ], required: ["bodies", "factors"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let bodies = try r.bodies(a["bodies"], key: "bodies")
            let factors: Vec3Expr
            if let f = a["factors"], f.array == nil {
                let e = try Args.expr(f, "factors")
                factors = Vec3Expr(e, e, e)
            } else {
                guard let f = try a.vec3("factors") else { throw ToolError("`factors` is required") }
                factors = f
            }
            var center = try a.vec3("center")
            if center == nil {
                var lo: Vec3?, hi: Vec3?
                for b in bodies {
                    guard let bb = b.shape.bounds else { continue }
                    lo = lo.map { Vec3(min($0.x, bb.min.x), min($0.y, bb.min.y), min($0.z, bb.min.z)) } ?? bb.min
                    hi = hi.map { Vec3(max($0.x, bb.max.x), max($0.y, bb.max.y), max($0.z, bb.max.z)) } ?? bb.max
                }
                if let lo, let hi {
                    let c = (lo + hi) / 2
                    center = Vec3Expr(Expr((c.x * 1000).rounded() / 1000), Expr((c.y * 1000).rounded() / 1000), Expr((c.z * 1000).rounded() / 1000))
                }
            }
            let sc = Scale(bodies: bodies.map(\.ref), factors: factors, center: center ?? .zero)
            return try await add(ws, .scale(sc), base: "Scale", a)
        }
    }

    private var mirror: MCPTool {
        MCPTool(
            name: "mirror", title: "Mirror",
            description: "Mirrors bodies across a plane. merge (default true) fuses each copy with its original; false makes the copies new bodies.",
            inputSchema: Self.object([
                "bodies": Self.bodies, "plane": Self.plane,
                "offset": Self.expr("Origin-plane offset along its normal (\"yz\" with offset 0 mirrors left↔right across x = 0)"),
                "merge": Self.boolean("Fuse copies with the originals (default true)"), "name": Self.name,
            ], required: ["bodies", "plane"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let m = Mirror(bodies: try r.bodies(a["bodies"], key: "bodies").map(\.ref),
                           plane: try r.plane(a["plane"], offset: try a.optionalExpr("offset")),
                           merge: a.bool("merge", default: true))
            return try await add(ws, .mirror(m), base: "Mirror", a)
        }
    }

    private var pattern: MCPTool {
        MCPTool(
            name: "pattern", title: "Pattern",
            description: "Repeats bodies along a direction (linear) or around an axis through the origin (circular); copies fuse with the originals.",
            inputSchema: Self.object([
                "bodies": Self.bodies, "layout": Self.string("Pattern type", enum: ["linear", "circular"]),
                "axis": Self.axis, "count": Self.expr("Total count including the original"),
                "spacing": Self.expr("Linear: distance between copies"),
                "angle": Self.expr("Circular: total angle (default 360)"), "name": Self.name,
            ], required: ["bodies", "layout", "axis", "count"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let axis = try r.axis(a["axis"], key: "axis")
            let layout: PatternLayout = switch try a.string("layout") {
            case "linear": .linear(direction: axis, count: try a.expr("count"), spacing: try a.expr("spacing"))
            case "circular": .circular(axis: axis, count: try a.expr("count"), angle: try a.expr("angle", default: 360))
            default: throw ToolError("`layout` must be linear or circular")
            }
            let p = Pattern(bodies: try r.bodies(a["bodies"], key: "bodies").map(\.ref), layout: layout)
            return try await add(ws, .pattern(p), base: "Pattern", a)
        }
    }

    private var layFlat: MCPTool {
        MCPTool(
            name: "lay_flat", title: "Lay flat",
            description: "Rotates a body so a flat face lies on the bed (z = 0), for printing.",
            inputSchema: Self.object(["body": Self.body, "face": [
                "description": "Face index or filter", "anyOf": [["type": "integer"], Self.filter]], "name": Self.name],
                                     required: ["body", "face"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let (b, _, ref) = try r.faceRef(["body": .string(try a.string("body")), "face": a["face"] ?? .null], key: "face")
            return try await add(ws, .layFlat(LayFlat(body: b.ref, face: ref)), base: "Lay Flat", a)
        }
    }

    // MARK: Editing

    private var editFeature: MCPTool {
        MCPTool(
            name: "edit_feature", title: "Edit step",
            description: """
                Changes an existing step with a JSON merge patch against its definition from get_feature, e.g. \
                {"kind": {"distance": "25"}} or {"name": "Hat", "suppressed": true}. Arrays (like sketch shapes) are replaced \
                whole. To use different faces or edges, delete the step and add a new one.
                """,
            inputSchema: Self.object(["feature": Self.string("Step name or id"),
                                      "changes": ["type": "object", "description": "Merge patch for the step's JSON"],
                                      "allow_failures": Self.allowFailures], required: ["feature", "changes"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let old = try r.feature(try a.string("feature"))
            guard let changes = a["changes"], changes.object != nil else { throw ToolError("`changes` must be an object") }
            var patched = try JSONValue(encoding: old).merging(patch: changes)
            if var o = patched.object, var kind = o["kind"]?.object, kind["type"] == "sketch", let shapes = kind["shapes"] {
                kind["shapes"] = try ShapeInput.normalized(shapes)
                o["kind"] = .object(kind)
                patched = .object(o)
            }
            var f: Feature
            do { f = try patched.decode(Feature.self) } catch {
                throw ToolError("The patched step isn't valid: \(Self.decodingMessage(error))")
            }
            f.id = old.id
            let allow = a.bool("allow_failures", default: false)
            let (model, warnings) = try await Change.apply(ws, action: "Edit \(f.name)", newFeature: allow || f.suppressed ? nil : f.id,
                                               allowFailures: allow) { try $0.updateFeature(f) }
            return Report.added(ws, model, warnings: warnings, feature: f.id, extra: Self.sketchInfo(f, model))
        }
    }

    private var deleteFeature: MCPTool {
        MCPTool(
            name: "delete_feature", title: "Delete step",
            description: "Deletes a step. With cascade, the steps that depend on it go too; otherwise they would break, which is refused unless allow_failures.",
            inputSchema: Self.object(["feature": Self.string("Step name or id"),
                                      "cascade": Self.boolean("Also delete dependent steps"),
                                      "allow_failures": Self.allowFailures], required: ["feature"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let f = try r.feature(try a.string("feature"))
            var removed: [UUID] = []
            let (model, warnings) = try await Change.apply(ws, action: "Delete \(f.name)", allowFailures: a.bool("allow_failures", default: false)) { doc in
                removed = try doc.deleteFeature(f.id, cascade: a.bool("cascade", default: false)).removed
                for id in removed { doc.bodyColors[BodyRef(id)] = nil }
            }
            let names = removed.compactMap { id in r.document.feature(id)?.name }
            return .json(["deleted": .array(names.map { .string($0) }), "design": Report.brief(ws, model, warnings: warnings)])
        }
    }

    // MARK: Appearance and output

    private var setBodyColor: MCPTool {
        MCPTool(
            name: "set_body_color", title: "Color",
            description: "Sets the display colour of bodies (shown in the viewport and renders): \"#RRGGBB\", a colour name (\(NamedColor.names.joined(separator: ", "))), or \"default\".",
            inputSchema: Self.object(["bodies": Self.bodies, "color": Self.string("Hex or colour name")], required: ["bodies", "color"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let bodies = try r.bodies(a["bodies"], key: "bodies")
            let input = try a.string("color")
            let hex = try NamedColor.hex(input)
            let (model, warnings) = try await Change.apply(ws, action: "Color \(bodies.count == 1 ? r.bodyLabel(bodies[0]) : "Bodies")") { doc in
                for b in bodies { doc.bodyColors[b.ref] = hex }
            }
            return .json(["colored": .array(bodies.map { .string(r.bodyLabel($0)) }), "color": hex.map { .string($0) } ?? "default",
                          "design": Report.brief(ws, model, warnings: warnings)])
        }
    }

    private var export: MCPTool {
        MCPTool(
            name: "export", title: "Export",
            description: "Writes the visible bodies to a 3MF (for Bambu Studio, one object per body), STL or STEP file, or the whole design to a .fillet file, and returns its path.",
            inputSchema: Self.object(["format": Self.string("File format", enum: ["3mf", "stl", "step", "fillet"]),
                                      "path": Self.string("Where to write (default: a temporary folder)")], required: ["format"]),
            readOnly: true
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let model = await ws.evaluated()
            let r = Resolver(document: ws.document, model: model)
            let bodies = model.bodies.filter { !ws.hiddenBodies.contains($0.ref) }
            let format = try a.string("format").lowercased()
            guard !bodies.isEmpty || format == "fillet" else { throw ToolError("There are no visible bodies to export") }
            let base = (ws.document.name ?? ws.title).replacingOccurrences(of: "/", with: "-")
            let ext = format == "step" ? "step" : format
            let url = a.optionalString("path").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(base).\(ext)")
            switch format {
            case "3mf":
                let objects = try bodies.map { (name: r.bodyLabel($0), mesh: try $0.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)) }
                try ThreeMFWriter.write(objects: objects, preset: ws.document.printerPreset, title: base).write(to: url, options: .atomic)
            case "stl":
                let meshes = try bodies.map { try $0.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1) }
                try STLWriter.binary(meshes: meshes).write(to: url, options: .atomic)
            case "step":
                try Shape.exportSTEP(bodies.map { ($0.shape, r.bodyLabel($0)) }, url: url)
            case "fillet":
                try ws.document.encoded().write(to: url, options: .atomic)
            default:
                throw ToolError("`format` must be 3mf, stl, step or fillet")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return .json(["path": .string(url.path), "bytes": .number(Double(size)), "bodies": .number(Double(bodies.count))])
        }
    }

    // MARK: Helpers

    /// Adds a feature built by a tool (named from `name` or `base`) and reports it.
    private func add(_ ws: any DesignWorkspace, _ kind: FeatureKind, base: String, _ a: Args) async throws -> ToolResult {
        let feature = Feature(name: Change.uniqueName(a.optionalString("name"), base: base, in: ws.document), kind)
        let (model, warnings) = try await Change.apply(ws, action: "New \(feature.name)", newFeature: feature.id) { _ = $0.addFeature(feature) }
        return Report.added(ws, model, warnings: warnings, feature: feature.id)
    }

    nonisolated static func decodingMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): c.debugDescription
        case DecodingError.keyNotFound(let k, _): "missing \(k.stringValue)"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        default: String(describing: error)
        }
    }
}

/// Turns agent-friendly sketch shapes (`[u, v]` points, no ids) into the document format.
enum ShapeInput {
    static func shapes(_ value: JSONValue?) throws -> [SketchShape] {
        guard let value, let array = value.array, !array.isEmpty else { throw ToolError("`shapes` must be a non-empty list") }
        let normalized = try normalized(.array(array))
        return try normalized.array!.enumerated().map { i, s in
            do { return try s.decode(SketchShape.self) } catch {
                throw ToolError("Shape \(i) (\(array[i]["type"]?.string ?? "?")) isn't valid: \(FilletTools.decodingMessage(error))")
            }
        }
    }

    /// Each shape as `{"id", "construction", "kind": {"type", …}}` with `{"x", "y"}` points.
    static func normalized(_ value: JSONValue) throws -> JSONValue {
        guard let array = value.array else { throw ToolError("`shapes` must be a list") }
        return .array(try array.enumerated().map { i, s in
            guard var o = s.object else { throw ToolError("Shape \(i) must be an object") }
            if let kind = o["kind"]?.object {
                o["kind"] = .object(try points(kind))
                if o["id"] == nil { o["id"] = .string(UUID().uuidString) }
                return .object(o)
            }
            guard o["type"]?.string != nil else { throw ToolError("Shape \(i) needs a \"type\"") }
            let construction = o.removeValue(forKey: "construction") ?? false
            let id = o.removeValue(forKey: "id") ?? .string(UUID().uuidString)
            return ["id": id, "construction": construction, "kind": .object(try points(o))]
        })
    }

    private static let pointKeys = ["a", "b", "position", "center", "start", "through", "end"]

    private static func points(_ shape: [String: JSONValue]) throws -> [String: JSONValue] {
        var o = shape
        for k in pointKeys { if let v = o[k] { o[k] = point(v) } }
        if let pts = o["points"]?.array { o["points"] = .array(pts.map(point)) }
        if let vs = o["vertices"]?.array {
            o["vertices"] = .array(vs.map { v in
                guard let a = v.array, a.count >= 2 else { return v }
                var vertex: [String: JSONValue] = ["x": a[0], "y": a[1]]
                if a.count > 2, !a[2].isNull { vertex["bulge"] = a[2] }
                return .object(vertex)
            })
        }
        return o
    }

    private static func point(_ v: JSONValue) -> JSONValue {
        if let a = v.array, a.count == 2 { return ["x": a[0], "y": a[1]] }
        return v
    }
}

/// Colour names agents can use.
enum NamedColor {
    static let table: [(String, String)] = [
        ("red", "#E53935"), ("orange", "#FB8C00"), ("yellow", "#FDD835"), ("lime", "#9CCC65"), ("green", "#43A047"),
        ("dark_green", "#2E7D32"), ("teal", "#00897B"), ("cyan", "#00ACC1"), ("blue", "#1E88E5"), ("navy", "#283593"),
        ("purple", "#8E24AA"), ("violet", "#7E57C2"), ("pink", "#EC407A"), ("brown", "#8D6E63"), ("dark_brown", "#5D4037"),
        ("tan", "#D7B48A"), ("gold", "#F9A825"), ("white", "#F5F5F5"), ("gray", "#9E9E9E"), ("black", "#263238"),
        ("cream", "#FFF3D6"),
    ]

    static var names: [String] { table.map(\.0) }

    /// `nil` = back to the default colour.
    static func hex(_ input: String) throws -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        if s == "default" || s == "none" { return nil }
        if let named = table.first(where: { $0.0 == s || $0.0.replacingOccurrences(of: "_", with: "") == s }) { return named.1 }
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, UInt32(hex, radix: 16) != nil else {
            throw ToolError("Colour must be \"#RRGGBB\" or one of: \(names.joined(separator: ", "))")
        }
        return "#" + hex.uppercased()
    }
}
