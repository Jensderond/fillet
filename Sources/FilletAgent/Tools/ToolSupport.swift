import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// Reading tool arguments.
struct Args {
    let json: JSONValue

    init(_ json: JSONValue) { self.json = json }

    subscript(key: String) -> JSONValue? {
        guard let v = json[key], !v.isNull else { return nil }
        return v
    }

    func string(_ key: String) throws -> String {
        guard let s = self[key]?.string, !s.isEmpty else { throw ToolError("`\(key)` is required (a string)") }
        return s
    }

    func optionalString(_ key: String) -> String? { self[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }

    func bool(_ key: String, default d: Bool) -> Bool { self[key]?.bool ?? d }

    func int(_ key: String, default d: Int) throws -> Int {
        guard let v = self[key] else { return d }
        guard let i = v.int else { throw ToolError("`\(key)` must be an integer") }
        return i
    }

    func double(_ key: String) -> Double? { self[key]?.number }

    /// A required expression: a number (mm / degrees) or an expression string ("width/2 + 3").
    func expr(_ key: String) throws -> Expr {
        guard let v = self[key] else { throw ToolError("`\(key)` is required (a number or an expression string)") }
        return try Args.expr(v, key)
    }

    func optionalExpr(_ key: String) throws -> Expr? {
        try self[key].map { try Args.expr($0, key) }
    }

    func expr(_ key: String, default d: Expr) throws -> Expr { try optionalExpr(key) ?? d }

    static func expr(_ v: JSONValue, _ key: String) throws -> Expr {
        if let n = v.number { return Expr(n) }
        if let s = v.string, !s.trimmingCharacters(in: .whitespaces).isEmpty { return Expr(s) }
        throw ToolError("`\(key)` must be a number or an expression string")
    }

    /// `[x, y, z]` of expressions.
    func vec3(_ key: String) throws -> Vec3Expr? {
        guard let v = self[key] else { return nil }
        guard let a = v.array, a.count == 3 else { throw ToolError("`\(key)` must be [x, y, z]") }
        return Vec3Expr(try Args.expr(a[0], key), try Args.expr(a[1], key), try Args.expr(a[2], key))
    }

    /// `[x, y, z]` of plain numbers.
    static func point3(_ v: JSONValue?, _ key: String) throws -> Vec3? {
        guard let v, !v.isNull else { return nil }
        guard let a = v.array, a.count == 3, let x = a[0].number, let y = a[1].number, let z = a[2].number else {
            throw ToolError("`\(key)` must be [x, y, z] numbers")
        }
        return Vec3(x, y, z)
    }

    /// `[u, v]` of expressions.
    func point2(_ key: String) throws -> Point2Expr? {
        guard let v = self[key] else { return nil }
        return try Args.point2(v, key)
    }

    static func point2(_ v: JSONValue, _ key: String) throws -> Point2Expr {
        if let a = v.array, a.count == 2 { return Point2Expr(try expr(a[0], key), try expr(a[1], key)) }
        if let x = v["x"], let y = v["y"] { return Point2Expr(try expr(x, key), try expr(y, key)) }
        throw ToolError("`\(key)` must be [u, v]")
    }

    func operation(default d: FilletCore.Operation) throws -> FilletCore.Operation {
        guard let s = optionalString("operation") else { return d }
        return try Args.operation(s)
    }

    static func operation(_ s: String) throws -> FilletCore.Operation {
        switch s.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "") {
        case "new", "newbody", "body": .newBody
        case "join", "add", "union", "fuse": .join
        case "cut", "subtract", "remove", "difference": .cut
        case "intersect", "common", "intersection": .intersect
        default: throw ToolError("Unknown operation '\(s)': use new_body, join, cut or intersect")
        }
    }
}

// MARK: - Resolving references

/// Resolves the names agents use for bodies, features, faces and edges against a design.
struct Resolver {
    let document: Document
    let model: EvaluatedModel
    /// Bodies around the steps that `created_by` filters name (see ``load(_:_:)``).
    var steps: [UUID: StepBodies] = [:]

    init(document: Document, model: EvaluatedModel) {
        self.document = document
        self.model = model
    }

    /// The bodies just before and just after one step.
    struct StepBodies {
        var before: [EvaluatedBody]
        var after: [EvaluatedBody]
    }

    /// A resolver for the workspace's current design that can also answer the `created_by`
    /// filters found anywhere in `args` (they need the bodies around that step, evaluated here;
    /// the steps are cached, so that costs no kernel work).
    @MainActor
    static func load(_ ws: any DesignWorkspace, _ args: JSONValue? = nil) async throws -> Resolver {
        let model = await ws.evaluated()
        let doc = ws.document
        var r = Resolver(document: doc, model: model)
        for name in args.map(createdByNames) ?? [] {
            let f = try r.feature(name)
            guard r.steps[f.id] == nil else { continue }
            let active = doc.activeFeatures
            guard let i = active.firstIndex(where: { $0.id == f.id }) else {
                throw ToolError("`created_by`: “\(f.name)” is suppressed or after the rollback marker, so it made nothing")
            }
            if case .failed(let reason) = model.status[f.id] {
                throw ToolError("`created_by`: “\(f.name)” failed (\(reason)), so it made nothing")
            }
            let before = await ws.preview(doc, before: f.id).bodiesBefore ?? []
            let after = i + 1 < active.count ? await ws.preview(doc, before: active[i + 1].id).bodiesBefore ?? [] : model.bodies
            r.steps[f.id] = StepBodies(before: before, after: after)
        }
        return r
    }

    /// Every `"created_by"` string in a tool's arguments.
    static func createdByNames(_ v: JSONValue) -> [String] {
        if let o = v.object {
            return o.flatMap { key, value in key == "created_by" ? (value.string.map { [$0] } ?? []) : createdByNames(value) }
        }
        return v.array?.flatMap(createdByNames) ?? []
    }

    /// A body by the name of the feature that made it ("Frog body"), its display name
    /// ("Body 2"), or its id (or an id prefix).
    func body(_ name: String) throws -> EvaluatedBody {
        let n = name.trimmingCharacters(in: .whitespaces)
        let lower = n.lowercased()
        if let id = UUID(uuidString: n), let b = model.body(BodyRef(id)) { return b }
        if let f = document.features.first(where: { $0.name.lowercased() == lower }), let b = model.body(BodyRef(f.id)) {
            return b
        }
        if let b = model.bodies.first(where: { $0.name.lowercased() == lower }) { return b }
        if n.count >= 4 {
            let matches = model.bodies.filter { $0.ref.feature.uuidString.lowercased().hasPrefix(lower) }
            if matches.count == 1 { return matches[0] }
        }
        if let f = document.features.first(where: { $0.name.lowercased() == lower }) {
            // Named a feature that doesn't own a body: say which body it changed, if any.
            let changed = model.bodies.filter { $0.lastFeature == f.id }.map { bodyLabel($0) }
            throw ToolError("“\(f.name)” is a \(f.kind.typeName) step, not a body"
                + (changed.isEmpty ? "" : " (it changed \(changed.joined(separator: ", ")))") + ". Bodies: \(bodyList)")
        }
        throw ToolError("No body named “\(name)”. Bodies: \(bodyList)")
    }

    func bodies(_ value: JSONValue?, key: String) throws -> [EvaluatedBody] {
        guard let value else { throw ToolError("`\(key)` is required (a body name or a list of them)") }
        if let s = value.string { return [try body(s)] }
        guard let a = value.array, !a.isEmpty else { throw ToolError("`\(key)` must be a body name or a list of them") }
        return try a.map { v in
            guard let s = v.string else { throw ToolError("`\(key)` must list body names") }
            return try body(s)
        }
    }

    var bodyList: String {
        model.bodies.isEmpty ? "(none yet)" : model.bodies.map { "“\(bodyLabel($0))”" }.joined(separator: ", ")
    }

    /// The name agents should use for a body: its creating feature's name.
    func bodyLabel(_ b: EvaluatedBody) -> String {
        document.feature(b.ref.feature)?.name ?? b.name
    }

    /// A feature by name, id or id prefix.
    func feature(_ name: String) throws -> Feature {
        let n = name.trimmingCharacters(in: .whitespaces)
        let lower = n.lowercased()
        if let id = UUID(uuidString: n), let f = document.feature(id) { return f }
        if let f = document.features.first(where: { $0.name.lowercased() == lower }) { return f }
        if n.count >= 4 {
            let matches = document.features.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            if matches.count == 1 { return matches[0] }
        }
        let names = document.features.map { "“\($0.name)”" }.joined(separator: ", ")
        throw ToolError("No step named “\(name)”. Steps: \(names.isEmpty ? "(none)" : names)")
    }

    func sketch(_ name: String) throws -> (Feature, Sketch, EvaluatedSketch?) {
        let f = try feature(name)
        guard case .sketch(let s) = f.kind else { throw ToolError("“\(f.name)” is a \(f.kind.typeName) step, not a sketch") }
        return (f, s, model.sketches[f.id])
    }

    // MARK: Faces and edges

    /// Face indices from `[indices]`, `"all"`, or a filter object (see ``GeometryFilter``).
    func faces(of body: EvaluatedBody, _ value: JSONValue?, key: String) throws -> [Int] {
        let infos = body.shape.faceInfos
        guard let value else { throw ToolError("`\(key)` is required: face indices from list_faces, or a filter object") }
        if value.string == "all" { return Array(infos.indices) }
        if let a = value.array {
            return try a.map { v in
                guard let i = v.int, infos.indices.contains(i) else {
                    throw ToolError("Face \(v.serialized()) doesn't exist on “\(bodyLabel(body))” (it has \(infos.count) faces, 0–\(infos.count - 1))")
                }
                return i
            }
        }
        if value.object != nil {
            let found = try filter(value, .faces, on: body).faces(infos)
            guard !found.isEmpty else { throw ToolError("No face of “\(bodyLabel(body))” matches \(value.serialized())") }
            return found
        }
        throw ToolError("`\(key)` must be face indices, \"all\", or a filter object")
    }

    /// Edge indices from `[indices]`, `"all"`, or a filter object. With `forRounding` (fillet,
    /// chamfer), seams and degenerate edges are left out of "all" and filters, and refused by index.
    func edges(of body: EvaluatedBody, _ value: JSONValue?, key: String, forRounding: Bool = false) throws -> [Int] {
        let infos = body.shape.edgeInfos
        guard let value else { throw ToolError("`\(key)` is required: edge indices from list_edges, \"all\", or a filter object") }
        let seams = forRounding ? body.shape.seamEdges : []
        func usable(_ i: Int) -> Bool { !forRounding || !seams[i] }
        if value.string == "all" {
            let found = infos.indices.filter(usable)
            guard !found.isEmpty else { throw ToolError("“\(bodyLabel(body))” has no edges to round (a plain sphere or ellipsoid has only seams)") }
            return found
        }
        if let a = value.array {
            return try a.map { v in
                guard let i = v.int, infos.indices.contains(i) else {
                    throw ToolError("Edge \(v.serialized()) doesn't exist on “\(bodyLabel(body))” (it has \(infos.count) edges, 0–\(infos.count - 1))")
                }
                guard usable(i) else { throw ToolError("Edge \(i) of “\(bodyLabel(body))” is a seam (list_edges marks them); it can't be rounded") }
                return i
            }
        }
        if value.object != nil {
            let found = try filter(value, .edges, on: body).edges(infos).filter(usable)
            guard !found.isEmpty else { throw ToolError("No \(forRounding ? "roundable " : "")edge of “\(bodyLabel(body))” matches \(value.serialized())") }
            return found
        }
        throw ToolError("`\(key)` must be edge indices, \"all\", or a filter object")
    }

    enum Topology { case faces, edges }

    /// A filter object, with its `created_by` resolved on `body`.
    func filter(_ value: JSONValue, _ kind: Topology, on body: EvaluatedBody) throws -> GeometryFilter {
        var filter = try GeometryFilter(value)
        if let step = value["created_by"] {
            guard let name = step.string else { throw ToolError("`created_by` must be a step name") }
            filter.only = try created(kind, on: body, by: name)
        }
        return filter
    }

    /// Faces or edges of `body` (current indices) that step `name` made: those of the body
    /// just after the step that no body had just before it (seams of a join, the walls of a
    /// cut, faces of a fillet; edges it trimmed count too). When later steps changed the body,
    /// only those still there unchanged are returned.
    func created(_ kind: Topology, on body: EvaluatedBody, by name: String) throws -> Set<Int> {
        let f = try feature(name)
        guard let step = steps[f.id] else { throw ToolError("`created_by` “\(name)” wasn't prepared (internal error)") }
        guard let after = step.after.first(where: { $0.ref == body.ref }) else {
            throw ToolError("“\(bodyLabel(body))” didn't exist yet after “\(f.name)”")
        }
        let made: Int
        var found = Set<Int>()
        switch kind {
        case .edges:
            let old = step.before.flatMap { $0.shape.edgeInfos }
            let new = after.shape.edgeInfos
            let tol = Self.matchTolerance(old.map(\.mid) + new.map(\.mid))
            let fresh = new.indices.filter { i in !old.contains { Self.same($0, new[i], tol) } }
            made = fresh.count
            if after.shape === body.shape {
                found = Set(fresh)
            } else {
                let current = body.shape.edgeInfos
                for i in fresh { if let j = current.firstIndex(where: { Self.same($0, new[i], tol) }) { found.insert(j) } }
            }
        case .faces:
            let old = step.before.flatMap { $0.shape.faceInfos }
            let new = after.shape.faceInfos
            let tol = Self.matchTolerance(old.map(\.centroid) + new.map(\.centroid))
            let fresh = new.indices.filter { i in !old.contains { Self.same($0, new[i], tol) } }
            made = fresh.count
            if after.shape === body.shape {
                found = Set(fresh)
            } else {
                let current = body.shape.faceInfos
                for i in fresh { if let j = current.firstIndex(where: { Self.same($0, new[i], tol) }) { found.insert(j) } }
            }
        }
        let noun = kind == .faces ? "faces" : "edges"
        guard !found.isEmpty else {
            if made > 0, let later = document.feature(body.lastFeature) {
                throw ToolError("The \(made) \(noun) “\(f.name)” made on “\(bodyLabel(body))” were all changed by later steps (last: “\(later.name)”)")
            }
            let changed = step.after.filter { $0.lastFeature == f.id }.map { "“\(bodyLabel($0))”" }
            throw ToolError("“\(f.name)” made no \(noun) on “\(bodyLabel(body))”"
                + (changed.isEmpty ? "" : " (it made or changed \(changed.joined(separator: ", ")))"))
        }
        return found
    }

    /// Distance under which two points count as the same: a millionth of the model size, at least 1 µm.
    private static func matchTolerance(_ points: [Vec3]) -> Double {
        guard var lo = points.first else { return 1e-3 }
        var hi = lo
        for p in points { lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)) }
        return max(1e-3, lo.distance(to: hi) * 1e-6)
    }

    private static func same(_ a: EdgeInfo, _ b: EdgeInfo, _ tol: Double) -> Bool {
        guard a.curve == b.curve, a.mid.distance(to: b.mid) <= tol, abs(a.length - b.length) <= tol else { return false }
        return (a.start.distance(to: b.start) <= tol && a.end.distance(to: b.end) <= tol)
            || (a.start.distance(to: b.end) <= tol && a.end.distance(to: b.start) <= tol)
    }

    private static func same(_ a: FaceInfo, _ b: FaceInfo, _ tol: Double) -> Bool {
        a.surface == b.surface && a.centroid.distance(to: b.centroid) <= tol && abs(a.area - b.area) <= max(tol, a.area * 1e-6)
            && a.boundsMin.distance(to: b.boundsMin) <= tol && a.boundsMax.distance(to: b.boundsMax) <= tol
    }

    /// A single face given as `{"body": …, "face": index or filter}`.
    func faceRef(_ value: JSONValue?, key: String) throws -> (EvaluatedBody, Int, FaceRef) {
        guard let value, let bodyName = value["body"]?.string else {
            throw ToolError("`\(key)` must be {\"body\": name, \"face\": index or filter}")
        }
        let b = try body(bodyName)
        let faceValue = value["face"].map { $0.int != nil ? JSONValue.array([$0]) : $0 }
        let indices = try faces(of: b, faceValue, key: "\(key).face")
        guard let i = indices.first else { throw ToolError("No face given in `\(key)`") }
        guard let ref = model.faceRef(body: b.ref, face: i) else { throw ToolError("Face \(i) can't be referenced") }
        return (b, i, ref)
    }

    /// A plane: "xy" / "xz" / "yz" (with `offset`), or a flat face `{"body", "face"}`.
    func plane(_ value: JSONValue?, offset: Expr?, key: String = "plane") throws -> SketchPlaneRef {
        guard let value else { return .standard(.xy, offset: offset ?? 0) }
        if let s = value.string {
            guard let p = StandardPlane(rawValue: s.lowercased()) else {
                throw ToolError("`\(key)` must be \"xy\", \"xz\", \"yz\" or {\"body\", \"face\"}")
            }
            return .standard(p, offset: offset ?? 0)
        }
        let (b, i, ref) = try faceRef(value, key: key)
        guard let plane = b.shape.facePlane(i, anchor: .world) else {
            throw ToolError("Face \(i) of “\(bodyLabel(b))” isn't flat; pick a planar face (list_faces with {\"type\": \"plane\"})")
        }
        return .face(ref, fallback: plane, anchor: .world)
    }

    /// An axis: "x" / "y" / "z" (world axes through the origin) or `{"body", "edge"}`.
    func axis(_ value: JSONValue?, key: String) throws -> AxisRef {
        guard let value else { throw ToolError("`\(key)` is required: \"x\", \"y\", \"z\" or {\"body\", \"edge\"}") }
        if let s = value.string {
            switch s.lowercased() {
            case "x": return .x
            case "y": return .y
            case "z": return .z
            default: throw ToolError("`\(key)` must be \"x\", \"y\", \"z\" or {\"body\", \"edge\"}")
            }
        }
        guard let bodyName = value["body"]?.string else { throw ToolError("`\(key)` must be \"x\", \"y\", \"z\" or {\"body\", \"edge\"}") }
        let b = try body(bodyName)
        let edgeValue = value["edge"].map { $0.int != nil ? JSONValue.array([$0]) : $0 }
        guard let i = try edges(of: b, edgeValue, key: "\(key).edge").first, let ref = model.edgeRef(body: b.ref, edge: i) else {
            throw ToolError("No edge given in `\(key)`")
        }
        return .edge(ref)
    }

    /// Profile regions of a sketch: "all", indices, or `[[u, v]]` points inside them.
    func regions(_ value: JSONValue?, sketch: EvaluatedSketch?, name: String) throws -> [RegionRef] {
        guard let regions = sketch?.regions, regions.count > 0 else {
            throw ToolError("Sketch “\(name)” has no closed profiles. Closed shapes (circle, rectangle, closed polyline…) make profiles.")
        }
        let value = value ?? "all"
        if value.string == "all" { return (0..<regions.count).map { RegionRef(regions.interiorPoint($0)) } }
        guard let a = value.array, !a.isEmpty else { throw ToolError("`regions` must be \"all\", region indices, or [[u, v]] points") }
        return try a.map { v in
            if let i = v.int {
                guard (0..<regions.count).contains(i) else {
                    throw ToolError("Sketch “\(name)” has regions 0–\(regions.count - 1), not \(i)")
                }
                return RegionRef(regions.interiorPoint(i))
            }
            if let p = v.array, p.count == 2, let u = p[0].number, let w = p[1].number {
                guard regions.region(containing: SIMD2(u, w)) != nil else {
                    throw ToolError("No profile of “\(name)” contains the point [\(u), \(w)]")
                }
                return RegionRef(x: u, y: w)
            }
            throw ToolError("`regions` must be \"all\", region indices, or [[u, v]] points")
        }
    }
}

/// Picks faces or edges by geometry, so agents needn't know indices:
/// `{"type": "circle", "parallel_to": [0,0,1], "near": [x,y,z], "within": {"min": [...], "max": [...]},
///   "normal": [0,0,1], "min_length": 5, "radius": 3, "limit": 4, "extreme": "+z"}`.
struct GeometryFilter {
    var type: String?
    /// Faces: outward normal direction. Edges: tangent direction (either sign).
    var direction: Vec3?
    var near: Vec3?
    var withinMin: Vec3?
    var withinMax: Vec3?
    var minSize: Double?
    var maxSize: Double?
    var radius: Double?
    var limit: Int?
    /// "+z", "-x"…: keep only the items furthest along that direction.
    var extreme: (axis: Vec3, sign: Double)?
    var toleranceDegrees = 5.0
    /// Candidates to choose from (`created_by`); nil = all.
    var only: Set<Int>?

    init(_ v: JSONValue) throws {
        type = v["type"]?.string?.lowercased()
        direction = try Args.point3(v["normal"] ?? v["parallel_to"] ?? v["direction"], "normal")
        near = try Args.point3(v["near"], "near")
        withinMin = try Args.point3(v["within"]?["min"], "within.min")
        withinMax = try Args.point3(v["within"]?["max"], "within.max")
        minSize = v["min_length"]?.number ?? v["min_area"]?.number
        maxSize = v["max_length"]?.number ?? v["max_area"]?.number
        radius = v["radius"]?.number
        limit = v["limit"]?.int
        if let t = v["angle_tolerance"]?.number { toleranceDegrees = t }
        if let e = v["extreme"]?.string?.lowercased() {
            let sign: Double = e.hasPrefix("-") ? -1 : 1
            switch e.trimmingCharacters(in: CharacterSet(charactersIn: "+-")) {
            case "x": extreme = (.unitX, sign)
            case "y": extreme = (.unitY, sign)
            case "z": extreme = (.unitZ, sign)
            default: throw ToolError("`extreme` must be one of +x, -x, +y, -y, +z, -z")
            }
        }
    }

    private func inside(_ p: Vec3) -> Bool {
        if let lo = withinMin, p.x < lo.x - 1e-6 || p.y < lo.y - 1e-6 || p.z < lo.z - 1e-6 { return false }
        if let hi = withinMax, p.x > hi.x + 1e-6 || p.y > hi.y + 1e-6 || p.z > hi.z + 1e-6 { return false }
        return true
    }

    private func finish(_ items: [(index: Int, point: Vec3)]) -> [Int] {
        var items = items
        if let (axis, sign) = extreme, let best = items.map({ $0.point.dot(axis) * sign }).max() {
            items = items.filter { $0.point.dot(axis) * sign >= best - 1e-3 }
        }
        if let near { items.sort { $0.point.distance(to: near) < $1.point.distance(to: near) } }
        if let limit { items = Array(items.prefix(max(0, limit))) }
        return items.map(\.index)
    }

    func faces(_ infos: [FaceInfo]) throws -> [Int] {
        let cosTol = cos(toleranceDegrees * .pi / 180)
        var found: [(Int, Vec3)] = []
        for (i, f) in infos.enumerated() {
            if let only, !only.contains(i) { continue }
            if let type, Describe.surfaceName(f.surface) != type { continue }
            if let d = direction, f.normal.normalized.dot(d.normalized) < cosTol { continue }
            if !inside(f.centroid) { continue }
            if let m = minSize, f.area < m { continue }
            if let m = maxSize, f.area > m { continue }
            found.append((i, f.centroid))
        }
        return finish(found.map { (index: $0.0, point: $0.1) })
    }

    func edges(_ infos: [EdgeInfo]) throws -> [Int] {
        let cosTol = cos(toleranceDegrees * .pi / 180)
        var found: [(index: Int, point: Vec3)] = []
        for (i, e) in infos.enumerated() {
            if let only, !only.contains(i) { continue }
            if let type, Describe.curveName(e.curve) != type { continue }
            if let d = direction, abs(e.tangentAtMid.normalized.dot(d.normalized)) < cosTol { continue }
            if !inside(e.mid) { continue }
            if let m = minSize, e.length < m { continue }
            if let m = maxSize, e.length > m { continue }
            if let r = radius, abs(e.radius - r) > max(0.01, r * 0.01) { continue }
            found.append((i, e.mid))
        }
        return finish(found)
    }
}

// MARK: - Describing the design

enum Describe {
    static func surfaceName(_ s: SurfaceType) -> String {
        switch s {
        case .plane: "plane"
        case .cylinder: "cylinder"
        case .cone: "cone"
        case .sphere: "sphere"
        case .torus: "torus"
        case .bspline: "bspline"
        default: "other"
        }
    }

    static func curveName(_ c: CurveType) -> String {
        switch c {
        case .line: "line"
        case .circle: "circle"
        case .ellipse: "ellipse"
        case .bspline: "bspline"
        default: "other"
        }
    }

    static func face(_ i: Int, _ f: FaceInfo) -> JSONValue {
        [
            "index": .number(Double(i)), "type": .string(surfaceName(f.surface)), "center": .vec(f.centroid),
            "normal": .vec(f.normal.normalized), "area": .rounded(f.area, 2),
            "bounds": ["min": .vec(f.boundsMin, 2), "max": .vec(f.boundsMax, 2)],
        ]
    }

    static func edge(_ i: Int, _ e: EdgeInfo, seam: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "index": .number(Double(i)), "type": .string(curveName(e.curve)), "start": .vec(e.start, 2),
            "mid": .vec(e.mid, 2), "end": .vec(e.end, 2), "length": .rounded(e.length, 2),
        ]
        if e.curve == .line { o["direction"] = .vec(e.tangentAtMid.normalized) }
        if e.radius > 0 { o["radius"] = .rounded(e.radius, 3) }
        if seam { o["seam"] = true }
        return .object(o)
    }

    static func bounds(_ shape: Shape) -> JSONValue {
        guard let b = shape.bounds else { return .null }
        return ["min": .vec(b.min, 2), "max": .vec(b.max, 2), "size": .vec(b.max - b.min, 2)]
    }

    static func body(_ b: EvaluatedBody, _ r: Resolver, detail: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(r.bodyLabel(b)), "id": .string(b.ref.feature.uuidString),
            "bounds": bounds(b.shape),
        ]
        if let c = r.document.bodyColors[b.ref] { o["color"] = .string(c) }
        // Hidden by the user (saved in the file): renders and exports leave it out.
        if r.document.hiddenBodies.contains(b.ref) { o["hidden"] = true }
        if let f = r.document.feature(b.lastFeature), b.lastFeature != b.ref.feature { o["last_changed_by"] = .string(f.name) }
        if detail {
            o["volume_mm3"] = .rounded(b.shape.volume, 1)
            o["area_mm2"] = .rounded(b.shape.surfaceArea, 1)
            o["faces"] = .number(Double(b.shape.faceCount))
            o["edges"] = .number(Double(b.shape.edgeCount))
            o["solids"] = .number(Double(b.shape.solidCount))
            o["valid"] = .bool(b.shape.isValid)
        }
        return .object(o)
    }

    static func plane(_ p: Plane) -> JSONValue {
        ["origin": .vec(p.origin), "normal": .vec(p.normal), "u_axis": .vec(p.xDir), "v_axis": .vec(p.yDir)]
    }

    static func status(_ s: FeatureStatus?) -> JSONValue {
        switch s {
        case .ok: "ok"
        case .failed(let m): .string("failed: \(m)")
        case .inactive, nil: "inactive (rolled back or suppressed)"
        }
    }

    static func regions(_ sketch: EvaluatedSketch) -> JSONValue {
        guard let r = sketch.regions else { return [] }
        return .array((0..<r.count).map { i in
            let boundary = r.boundary(i).flatMap { $0 }
            var o: [String: JSONValue] = ["index": .number(Double(i)), "area": .rounded(r.area(i), 2),
                                          "inside_point": .point(r.interiorPoint(i))]
            if let first = boundary.first {
                var lo = first, hi = first
                for p in boundary { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
                o["uv_min"] = .point(lo, 2)
                o["uv_max"] = .point(hi, 2)
            }
            return .object(o)
        })
    }

    /// A one-line summary of what a feature does.
    static func summary(_ f: Feature, _ r: Resolver) -> String {
        func body(_ ref: BodyRef) -> String { r.document.feature(ref.feature)?.name ?? "?" }
        func name(_ id: UUID) -> String { r.document.feature(id)?.name ?? "?" }
        switch f.kind {
        case .sketch(let s):
            let plane: String = switch s.plane {
            case .standard(let p, let o): o.source == "0" ? p.rawValue.uppercased() : "\(p.rawValue.uppercased()) offset \(o)"
            case .face(let ref, _, _): "a face of \(body(ref.body))"
            }
            return "\(s.shapes.count) shapes on \(plane)"
        case .extrude(let e):
            return "\(e.operation.rawValue) from \(name(e.sketch)), distance \(e.distance)\(e.symmetric ? " symmetric" : "")"
        case .revolve(let rv): return "\(rv.operation.rawValue) from \(name(rv.sketch)), \(rv.angle)°"
        case .fillet(let e): return "radius \(e.size) on \(e.edges.count) edges of \(body(e.body))"
        case .chamfer(let e): return "distance \(e.size) on \(e.edges.count) edges of \(body(e.body))"
        case .shell(let s): return "thickness \(s.thickness) on \(body(s.body))"
        case .primitive(let p):
            return "\(p.kind.rawValue) \(zip(p.kind.dimensionNames, p.dimensions).map { "\($0)=\($1)" }.joined(separator: " ")), \(p.operation.rawValue)"
        case .combine(let c): return "\(c.operation.rawValue) \(c.tools.map(body).joined(separator: ", ")) into \(body(c.target))"
        case .move(let m):
            return "move \(m.bodies.map(body).joined(separator: ", ")) by (\(m.translation.x), \(m.translation.y), \(m.translation.z)), rotate \(m.rotationAngle)°"
        case .scale(let sc):
            let turned = sc.orientation.map { " along axes turned \($0.angle)° about (\($0.axis.x), \($0.axis.y), \($0.axis.z))" } ?? ""
            return "scale \(sc.bodies.map(body).joined(separator: ", ")) by (\(sc.factors.x), \(sc.factors.y), \(sc.factors.z))\(turned)"
        case .loft(let l): return "\(l.operation.rawValue) loft through \(l.sections.count) sections"
        case .mirror(let m): return "mirror \(m.bodies.map(body).joined(separator: ", "))\(m.merge ? " merged" : "")"
        case .pattern(let p):
            return switch p.objects {
            case .bodies: "pattern \(p.bodies.map(body).joined(separator: ", "))"
            case .features: "pattern steps \(p.features.map(name).joined(separator: ", "))"
            }
        case .importedSTEP(let s): return "imported \(s.name)"
        case .layFlat(let l): return "lay \(body(l.body)) flat"
        case .hole(let h):
            let extent = h.extent == .throughAll ? "through all" : "depth \(h.depth)"
            return "\(h.centers.count) \(h.holeType.rawValue) holes ⌀\(h.diameter), \(extent)\(h.face.map { " in a face of \(body($0.body))" } ?? "")"
        case .pressPull(let p): return "distance \(p.distance) on \(p.faces.count) faces of \(body(p.body))"
        case .unknown(let t, _): return "unsupported \(t)"
        }
    }
}
