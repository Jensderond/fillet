import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// Fillet's MCP server: the modeling tools bound to a ``WorkspaceHost``.
@MainActor
public enum FilletMCP {
    public static let version = "1.0.0"

    /// A server whose tools act on `host`'s current design. `extraTools` are added as is
    /// (the headless command adds opening and saving files).
    public static func makeServer(host: WorkspaceHost, extraTools: [MCPTool] = []) -> MCPServer {
        let tools = FilletTools(host: host)
        let server = MCPServer(
            name: "fillet", version: version, instructions: instructions(host: host),
            tools: tools.all + extraTools)
        server.onToolCall = { [weak host] tool, args in
            guard let host else { return }
            host.agentActivity(args.map { activityText(tool, $0) })
        }
        return server
    }

    /// "Fillet 2 · Hat brim" style text for the activity indicator.
    static func activityText(_ tool: MCPTool, _ args: JSONValue) -> String {
        if let name = args["name"]?.string, !tool.readOnly { return "\(tool.title) · \(name)" }
        return tool.title
    }

    static func instructions(host: WorkspaceHost) -> String {
        """
        You are connected to Fillet, a parametric CAD app for 3D-printable parts (OpenCascade kernel). \
        Connected to: \(host.hostDescription). In the app, the user watches every change land in their window, \
        and each tool call that changes the design is one step they can undo.

        COORDINATES: millimetres and degrees. Z is up; the printer bed is the XY plane at z = 0, centred on the origin \
        (the default bed is 180×180 mm). Model parts standing on the bed (z ≥ 0). Front view looks along +Y.

        HOW A DESIGN WORKS: a timeline of steps (features). Bodies are solids; a body is named after the step that \
        created it ("Frog body") — use that name wherever a tool takes a body. Join/cut/intersect change existing \
        bodies in place. Every value can be a number or an expression using parameters ("width/2 + 3").

        SKETCH PLANES (u, v are sketch coordinates):
        - "xy": u = +X, v = +Y, normal +Z (offset moves it up in Z).
        - "xz": u = +X, v = +Z, normal −Y (front plane; offset 10 puts it at y = −10).
        - "yz": u = +Y, v = +Z, normal +X.
        - a flat face: {"body": "Base", "face": 3} or {"body": "Base", "face": {"extreme": "+z"}}.

        BUILDING SHAPES:
        - primitive: box (centred on the position, standing on the plane), cylinder/cone (base centred on the position, \
          axis along the plane normal), sphere (centred on the position), torus (centred, lying in the plane). \
          Shortcut: "at": [x, y, z] places it on the XY plane at height z.
        - Organic, round forms: sketch HALF a profile on "xz" with u ≥ 0 (u = radius, v = height), close it along the \
          v axis, then revolve around axis "y" (the world Z axis). Splines give smooth curves.
        - Prismatic parts: sketch on a plane, then extrude (new_body, join, cut or intersect).
        - loft: a smooth solid through circle/ellipse sections placed anywhere (center + normal + size); a 0 size at \
          an end makes a point. Sections along an arc with shrinking sizes make horns, curled hat tips, tails, limbs.
        - scale_bodies: non-uniform scale about a centre — squash a sphere into a mochi-like head or a flat foot. \
          With `axes` ({"z": [0, -0.5, 0.87]}) the factors apply along tilted directions: a disc on a sloped cheek \
          in one step, no squash-then-rotate.
        - Then fillet/chamfer edges, shell, hole (drilled, counterbored or countersunk holes in a flat face), press_pull faces (move them in or out), combine, move_bodies (rotate about a centre, translate), mirror, pattern.
        - Soft, organic characters: overlap rounded parts and join them (combine), then fillet the seams where they \
          meet (edges {"created_by": "<the join step>"}) with small radii.
        - set_body_color gives bodies display colours (hex like "#4CAF50" or a name like "green").
        - render_view with presentation: true shows a clean product shot (no edges or grid).

        PICKING FACES AND EDGES: list_faces / list_edges show indices and geometry. Tools accept indices, "all", or a \
        filter object: {"type": "circle"|"line"|"plane"|"cylinder"…, "normal"/"parallel_to": [x,y,z], \
        "near": [x,y,z], "within": {"min": […], "max": […]}, "extreme": "+z", "radius": r, "limit": n, \
        "created_by": "Join arm"}. Indices change after every step; filters don't, so prefer them. "created_by" picks \
        what that step made (edges/faces of the body after it that no body had before it): \
        {"created_by": "Join arm"} is the seam the join left, ready to fillet, however the numbering shifts.

        CHECK YOUR WORK: call render_view often (it returns an image) and get_design for bounds. A step that fails, \
        or leaves a body that isn't a valid closed solid, is not added (you get the reason); fix the input and retry. \
        A change that makes later steps fail is refused too. When a change makes a later fillet, chamfer, shell, hole, \
        press pull or lay-flat find its edges/faces somewhere else, it is made, but the result has "warnings" naming that step: \
        check it, and redo it if it went wrong. Big booleans and fillets on detailed bodies can take tens of seconds; \
        if a call times out it may still have been made, so call get_design before you retry.

        FILLETS AND BOOLEANS: fillet radii must be smaller than the faces they round; boolean tools must overlap \
        their targets. Fillet seams one join at a time (join a part, fillet {"created_by": that join}, then join the \
        next part): where many parts meet in one spot, or a seam runs into a thin sliver, fillets fail. A failed \
        fillet or chamfer says which edges are the trouble and the largest size the others take; a failed cut says \
        whether cutting the other way round works.

        UNDO: undo takes back the last change, whatever it was (a new step, an edit, a parameter, a colour), and \
        says what. Pass expect ("New Hat", "Edit Hat", or the step name) to be sure. In the app the user shares the \
        undo history: undo refuses to take back their changes unless you name them in expect.
        """
    }
}

/// Builds the tool list for a host.
@MainActor
struct FilletTools {
    let host: WorkspaceHost

    var all: [MCPTool] {
        [getDesign, getFeature, listFaces, listEdges, measure, checkPrint, renderView, setView,
         newDesign, listDesigns, selectDesign]
            + historyTools + modelingTools
    }

    // MARK: Schema helpers

    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }

    /// A number or an expression string.
    static func expr(_ description: String) -> JSONValue {
        ["type": ["number", "string"], "description": .string(description + " (number or expression)")]
    }

    static func vec3(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": ["number", "string"]], "minItems": 3, "maxItems": 3,
         "description": .string(description)]
    }

    static let body = string("Body name: the name of the step that created it (see get_design)")
    static let bodies: JSONValue = [
        "type": ["string", "array"], "items": ["type": "string"],
        "description": "One body name or a list of them",
    ]
    static let name = string("Name for the new step (and the body it creates), e.g. \"Hat brim\"")
    static let allowFailures = boolean("Apply even if other steps start failing (default false: such a change is refused)")
    static let filter: JSONValue = [
        "type": "object",
        "description": "Geometric filter: type, normal/parallel_to [x,y,z], near [x,y,z], within {min,max}, extreme \"+z\"…, radius, min_length/min_area, max_length/max_area, limit, created_by \"step name\" (only what that step made, e.g. the seam of a join)",
    ]
    static let selection: JSONValue = [
        "description": "Indices (from list_faces/list_edges), \"all\", or a filter object",
        "anyOf": [["type": "array", "items": ["type": "integer"]], ["type": "string", "enum": ["all"]], filter],
    ]
    static let plane: JSONValue = [
        "description": "\"xy\" | \"xz\" | \"yz\" (see instructions for their u/v axes) or a flat face {\"body\": name, \"face\": index or filter}",
        "anyOf": [["type": "string", "enum": ["xy", "xz", "yz"]],
                  ["type": "object", "properties": ["body": ["type": "string"], "face": [:]], "required": ["body", "face"]]],
    ]
    static let axis: JSONValue = [
        "description": "\"x\" | \"y\" | \"z\" (world axes) or a straight/circular edge {\"body\": name, \"edge\": index or filter}",
        "anyOf": [["type": "string", "enum": ["x", "y", "z"]],
                  ["type": "object", "properties": ["body": ["type": "string"], "edge": [:]], "required": ["body", "edge"]]],
    ]
    static let operation = string("How the result combines with existing bodies", enum: ["new_body", "join", "cut", "intersect"])

    // MARK: Inspect

    private var getDesign: MCPTool {
        MCPTool(
            name: "get_design", title: "Read design",
            description: "Overview of the open design: parameters, the timeline of steps (with status and errors) and the bodies with their bounds.",
            inputSchema: Self.object(["detail": Self.boolean("Include volume, area and face/edge counts per body")]),
            readOnly: true
        ) { args in
            let ws = try host.requireCurrent()
            let model = await ws.evaluated()
            return .json(Report.design(ws, model, detail: Args(args).bool("detail", default: false)))
        }
    }

    private var getFeature: MCPTool {
        MCPTool(
            name: "get_feature", title: "Read step",
            description: "Full definition of one step as JSON (the format edit_feature patches). Sketches also list their shapes, plane axes and closed regions.",
            inputSchema: Self.object(["feature": Self.string("Step name or id")], required: ["feature"]),
            readOnly: true
        ) { args in
            let ws = try host.requireCurrent()
            let model = await ws.evaluated()
            let r = Resolver(document: ws.document, model: model)
            let f = try r.feature(try Args(args).string("feature"))
            return .json(try Report.feature(f, r))
        }
    }

    private var listFaces: MCPTool {
        MCPTool(
            name: "list_faces", title: "List faces",
            description: "Faces of a body with index, surface type, centre, outward normal, area and bounds. Optionally filtered.",
            inputSchema: Self.object(["body": Self.body, "filter": Self.filter, "limit": Self.integer("Max faces to return (default 60)")],
                                     required: ["body"]),
            readOnly: true
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let b = try r.body(try a.string("body"))
            let infos = b.shape.faceInfos
            let indices = try a["filter"].map { try r.filter($0, .faces, on: b).faces(infos) } ?? Array(infos.indices)
            let limit = try a.int("limit", default: 60)
            return .json(["body": .string(r.bodyLabel(b)), "total_faces": .number(Double(infos.count)),
                          "matching": .number(Double(indices.count)),
                          "faces": .array(indices.prefix(limit).map { Describe.face($0, infos[$0]) })])
        }
    }

    private var listEdges: MCPTool {
        MCPTool(
            name: "list_edges", title: "List edges",
            description: "Edges of a body with index, curve type, start/mid/end points, length, direction (lines) and radius (circles). Seams (where a round face closes on itself) are marked; they can't be filleted. Optionally filtered.",
            inputSchema: Self.object(["body": Self.body, "filter": Self.filter, "limit": Self.integer("Max edges to return (default 80)")],
                                     required: ["body"]),
            readOnly: true
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let b = try r.body(try a.string("body"))
            let infos = b.shape.edgeInfos
            let seams = b.shape.seamEdges
            let indices = try a["filter"].map { try r.filter($0, .edges, on: b).edges(infos) } ?? Array(infos.indices)
            let limit = try a.int("limit", default: 80)
            return .json(["body": .string(r.bodyLabel(b)), "total_edges": .number(Double(infos.count)),
                          "matching": .number(Double(indices.count)),
                          "edges": .array(indices.prefix(limit).map { Describe.edge($0, infos[$0], seam: seams[$0]) })])
        }
    }

    private var checkPrint: MCPTool {
        MCPTool(
            name: "check_print", title: "Check printability",
            description: "Print check for the visible bodies on the selected printer: fits on the bed, size, overhang area beyond the angle, watertightness, estimated PLA grams.",
            inputSchema: Self.object(["overhang_angle": Self.number("Overhang threshold in degrees from vertical (default 45)")]),
            readOnly: true
        ) { args in
            let ws = try host.requireCurrent()
            let model = await ws.evaluated()
            let meshes = model.bodies.filter { !ws.hiddenBodies.contains($0.ref) }.compactMap { model.meshes[$0.ref] }
            let preset = ws.document.printerPreset
            let p = PrintAnalysis.analyze(meshes: meshes, preset: preset,
                                          overhangAngleDegrees: Args(args).double("overhang_angle") ?? 45)
            return .json([
                "printer": .string(preset.name), "bed": .vec(preset.bedSize, 0),
                "size": .vec(p.size, 2), "fits_on_bed": .bool(p.fitsOnBed), "fits_only_rotated": .bool(p.fitsOnlyRotated),
                "lowest_z": p.boundsMin.map { .rounded($0.z, 3) } ?? .null,
                "overhang_area_mm2": .rounded(p.overhangArea, 1), "watertight": .bool(p.isWatertight),
                "volume_mm3": .rounded(p.volume, 1), "pla_grams": .rounded(p.grams(.pla), 1),
            ])
        }
    }

    // MARK: View

    private static let viewProperties: [String: JSONValue] = [
        "view": string("Standard view (default iso)", enum: ["iso", "front", "back", "left", "right", "top", "bottom"]),
        "yaw": number("Degrees around Z, overrides the view's (0 = front, 90 = right side, 45 = iso)"),
        "pitch": number("Degrees of elevation, overrides the view's (0 = level, 90 = from above)"),
        "focus": bodies,
        "zoom": number("1 = fit (default); 2 = twice as close"),
    ]

    private var renderView: MCPTool {
        var props = Self.viewProperties
        props["width"] = Self.integer("Pixels (default 900, max 2048)")
        props["height"] = Self.integer("Pixels (default 700, max 2048)")
        props["highlight"] = [
            "type": "object", "description": "Faces/edges drawn as selected: {\"body\": name, \"faces\": selection, \"edges\": selection}",
            "properties": ["body": ["type": "string"], "faces": [:], "edges": [:]],
        ]
        props["sketch"] = Self.string("Overlay this sketch's curves and profiles")
        props["hide"] = Self.bodies
        props["style"] = Self.string("Visual style (default shaded_edges)", enum: ["shaded_edges", "shaded", "xray", "wireframe", "hidden_line"])
        props["show_user"] = Self.boolean("Also turn the user's live view to this camera")
        props["presentation"] = Self.boolean("Product-shot look: smooth shading without edges, no bed or grid, warm studio backdrop")
        return MCPTool(
            name: "render_view", title: "Render view",
            description: "Renders the design to a PNG image you can look at, like a screenshot of the viewport (bed included). Use it after changes to check the shape.",
            inputSchema: Self.object(props), readOnly: true
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let model = r.model
            var options = DesignRendering.Options()
            options.hidden = ws.hiddenBodies
            if let hide = a["hide"] { options.hidden.formUnion(try r.bodies(hide, key: "hide").map(\.ref)) }
            if let h = a["highlight"], let bodyName = h["body"]?.string {
                let b = try r.body(bodyName)
                if let faces = h["faces"] { options.highlight.formUnion(try r.faces(of: b, faces, key: "highlight.faces").map { .face(body: b.ref.feature, index: $0) }) }
                if let edges = h["edges"] { options.highlight.formUnion(try r.edges(of: b, edges, key: "highlight.edges").map { .edge(body: b.ref.feature, index: $0) }) }
                if h["faces"] == nil, h["edges"] == nil { options.highlightBodies = [b.ref] }
            }
            if let s = a.optionalString("sketch") { options.sketch = try r.sketch(s).0.id }
            if let style = a.optionalString("style") { options.visualStyle = try Self.visualStyle(style) }
            options.presentation = a.bool("presentation", default: false)
            let width = min(max(try a.int("width", default: 900), 64), 2048)
            let height = min(max(try a.int("height", default: 700), 64), 2048)
            let scene = DesignRendering.scene(document: ws.document, model: model, options: options)
            let camera = try Self.camera(a, r, scene: scene, sketch: options.sketch.flatMap { model.sketches[$0] },
                                         aspect: Double(width) / Double(height))
            let png = try DesignRendering.png(scene: scene, camera: camera, size: CGSize(width: width, height: height),
                                              palette: options.presentation ? DesignRendering.presentationPalette : nil)
            if a.bool("show_user", default: false) { ws.show(camera) }
            let visible = model.bodies.filter { !options.hidden.contains($0.ref) }.count
            return ToolResult([.image(png), .text("\(visible) visible bodies; view yaw \(Int((camera.yaw * 180 / .pi).rounded()))°, pitch \(Int((camera.pitch * 180 / .pi).rounded()))°")])
        }
    }

    private var setView: MCPTool {
        MCPTool(
            name: "set_view", title: "Show view",
            description: "Turns the user's view of the design (in the app) to a standard view or angle, framed on the given bodies. Use it to show the user what you are working on.",
            inputSchema: Self.object(Self.viewProperties), readOnly: true
        ) { args in
            let ws = try host.requireCurrent()
            let model = await ws.evaluated()
            let r = Resolver(document: ws.document, model: model)
            var options = DesignRendering.Options()
            options.hidden = ws.hiddenBodies
            let scene = DesignRendering.scene(document: ws.document, model: model, options: options)
            ws.show(try Self.camera(Args(args), r, scene: scene, sketch: nil, aspect: ws.viewAspect))
            return .text("View updated")
        }
    }

    static func visualStyle(_ s: String) throws -> VisualStyle {
        switch s {
        case "shaded_edges": .shadedWithEdges
        case "shaded": .shaded
        case "xray": .xray
        case "wireframe": .wireframe
        case "hidden_line": .hiddenLine
        default: throw ToolError("Unknown style '\(s)'")
        }
    }

    /// The camera for a view request, framed on the focus bodies (or everything visible).
    static func camera(_ a: Args, _ r: Resolver, scene: ViewportScene, sketch: EvaluatedSketch?, aspect: Double) throws -> Camera {
        let viewName = a.optionalString("view") ?? "iso"
        guard let view = Camera.StandardView(rawValue: viewName) else { throw ToolError("Unknown view '\(viewName)'") }
        var camera = Camera().viewing(view)
        if let yaw = a.double("yaw") { camera.yaw = yaw * .pi / 180 }
        if let pitch = a.double("pitch") { camera.pitch = max(-90, min(90, pitch)) * .pi / 180 }
        var bounds: Bounds3?
        func add(_ lo: Vec3, _ hi: Vec3) {
            let b = Bounds3(min: lo, max: hi)
            bounds = bounds.map { $0.union(b) } ?? b
        }
        if let focus = a["focus"] {
            for b in try r.bodies(focus, key: "focus") { if let bb = b.shape.bounds { add(bb.min, bb.max) } }
        } else {
            if let m = scene.modelBounds { add(m.min, m.max) }
            if let sketch {
                for poly in sketch.curves.values.flatMap({ $0 }) {
                    for p in poly { let w = sketch.plane.point(p); add(w, w) }
                }
            }
        }
        if let bounds = bounds ?? scene.fitBounds { camera.fit(bounds: bounds, aspect: aspect, margin: 1.15) }
        if let zoom = a.double("zoom"), zoom > 0 { camera.distance /= zoom }
        return camera
    }

    // MARK: Documents

    private var newDesign: MCPTool {
        MCPTool(
            name: "new_design", title: "New design",
            description: "Starts a new, empty design. On the Mac this opens a new window; on iPad (or headless) it clears the current design, which needs replace_current: true when it has steps (the user can still undo it).",
            inputSchema: Self.object([
                "name": Self.string("Design name"),
                "printer": Self.string("Printer preset id", enum: PrinterPreset.all.map(\.id)),
                "replace_current": Self.boolean("Clear the current design instead of opening a new one"),
            ])
        ) { args in
            let a = Args(args)
            var ws: (any DesignWorkspace)?
            if !a.bool("replace_current", default: false) { ws = try await host.openNewDesign() }
            let target: any DesignWorkspace
            if let ws {
                target = ws
            } else {
                let current = try host.requireCurrent()
                guard current.document.features.isEmpty || a.bool("replace_current", default: false) else {
                    throw ToolError("The open design “\(current.title)” has \(current.document.features.count) steps. Pass replace_current: true to clear it (the user can undo that), or keep working in it.")
                }
                target = current
            }
            var doc = Document()
            doc.name = a.optionalString("name")
            if let printer = a.optionalString("printer") {
                guard PrinterPreset.preset(id: printer) != nil else { throw ToolError("Unknown printer '\(printer)'") }
                doc.printer = printer
            } else {
                doc.printer = target.document.printer
            }
            if doc != target.document { _ = await target.commit(doc, action: "New Design") }
            return .json(["design": .string(target.title), "id": .string(target.id.uuidString),
                          "printer": .string(doc.printerPreset.name), "bed": .vec(doc.printerPreset.bedSize, 0)])
        }
    }

    private var listDesigns: MCPTool {
        MCPTool(
            name: "list_designs", title: "List designs",
            description: "The designs open in Fillet and which one the tools act on.",
            inputSchema: Self.object([:]), readOnly: true
        ) { _ in
            let current = host.current?.id
            return .json(["connected_to": .string(host.hostDescription),
                          "designs": .array(host.workspaces.map { ws in
                              ["id": .string(ws.id.uuidString), "title": .string(ws.title),
                               "steps": .number(Double(ws.document.features.count)), "current": .bool(ws.id == current)]
                          })])
        }
    }

    private var selectDesign: MCPTool {
        MCPTool(
            name: "select_design", title: "Select design",
            description: "Makes another open design (from list_designs) the one the tools act on.",
            inputSchema: Self.object(["id": Self.string("Design id or title")], required: ["id"]), readOnly: true
        ) { args in
            let key = try Args(args).string("id")
            guard let ws = host.workspaces.first(where: { $0.id.uuidString.lowercased() == key.lowercased() || $0.title == key }),
                  host.select(ws.id) else { throw ToolError("No open design “\(key)”") }
            return .text("Now working on “\(ws.title)”")
        }
    }
}
