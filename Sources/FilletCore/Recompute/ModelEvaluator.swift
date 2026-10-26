import FilletKernel
import Foundation
import simd
import Synchronization

/// Error raised while evaluating one feature; its message is shown in the timeline.
public struct FeatureError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Recomputes a document's features into bodies, off the main thread.
///
/// The state after every feature is cached, keyed by a hash of everything
/// that feature depends on (all earlier features + parameter values), so
/// editing the last feature only re-runs that feature.
public actor ModelEvaluator {
    private struct State: Sendable {
        var bodies: [EvaluatedBody] = []
        var sketches: [UUID: EvaluatedSketch] = [:]
        var status: [UUID: FeatureStatus] = [:]
        var resolvedEdges: [UUID: [EdgeInfo]] = [:]
        var references: [UUID: [ResolvedReference?]] = [:]
        var bodyCounter = 0
    }

    private struct CacheEntry: Sendable {
        var key: Int
        var state: State
    }

    private typealias MeshCache = [ObjectIdentifier: (shape: Shape, mesh: Mesh)]

    /// The state after each step of the last evaluated document.
    private var cache: [CacheEntry] = []
    /// The same for the last previewed document, kept apart so a preview that is thrown away
    /// doesn't cost `cache` its entries, and a preview that is then committed is all cache hits.
    private var previewCache: [CacheEntry] = []
    /// Display meshes by shape identity; the shape is retained so the identifier stays unique.
    private var meshCache: MeshCache = [:]
    /// The last preview's display meshes.
    private var previewMeshCache: MeshCache = [:]
    /// `meshCache` as it was before the last `evaluate`, so undoing a step (or setting a value
    /// back) finds the meshes of the bodies it brings back instead of meshing them again.
    private var previousMeshCache: MeshCache = [:]

    /// Wall-clock cost of one recomputed feature (see ``init(recordsTimings:)``).
    public struct StepTiming: Sendable {
        /// Position among the document's active features.
        public var index: Int
        public var feature: UUID
        public var seconds: Double
    }

    private let recordsTimings: Bool
    /// Features the last `evaluate` recomputed (cache hits are left out), in order.
    /// Only recorded when timing is on.
    public private(set) var lastStepTimings: [StepTiming] = []
    /// Time the last `evaluate` spent tessellating display meshes. Only recorded when timing is on.
    public private(set) var lastMeshSeconds: Double = 0
    /// Shapes the last `evaluate` or `preview` had to tessellate (the rest had cached meshes).
    private(set) var lastTessellatedCount = 0

    /// `recordsTimings` makes `evaluate` measure every recomputed feature and the display
    /// tessellation (for benchmarks; off in the app).
    public init(recordsTimings: Bool = false) {
        self.recordsTimings = recordsTimings
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    /// Evaluates all active features of the document. When `before` names a
    /// feature, the bodies just before it are returned in `bodiesBefore`.
    public func evaluate(_ document: Document, before: UUID? = nil) -> EvaluatedModel {
        run(document, before: before, preview: false)
    }

    /// Evaluates a candidate document (to check a change before making it) without replacing
    /// what `evaluate` cached: the steps it shares with the last evaluated document are cache
    /// hits, the rest is kept until the next preview, so evaluating the candidate afterwards
    /// costs nothing, and dropping it costs the cache nothing either.
    public func preview(_ document: Document, before: UUID? = nil) -> EvaluatedModel {
        run(document, before: before, preview: true)
    }

    private func run(_ document: Document, before: UUID?, preview: Bool) -> EvaluatedModel {
        let table = document.parameterTable
        var hasher = Hasher()
        hasher.combine(table.values.mapValues { [$0.value, Double($0.dimension.hashValue)] })
        var key = hasher.finalize()

        var state = State()
        let active = document.activeFeatures
        var newCache: [CacheEntry] = []
        newCache.reserveCapacity(active.count)

        var bodiesBefore: [EvaluatedBody]?
        var timings: [StepTiming] = []
        for (i, feature) in active.enumerated() {
            if feature.id == before { bodiesBefore = state.bodies }
            var h = Hasher()
            h.combine(key)
            h.combine(feature)
            key = h.finalize()

            // Keys chain through every earlier step, so entry i can only match at position i.
            if i < cache.count, cache[i].key == key {
                state = cache[i].state
            } else if i < previewCache.count, previewCache[i].key == key {
                state = previewCache[i].state
            } else {
                let start = recordsTimings ? ContinuousClock.now : nil
                apply(feature, to: &state, evaluator: table.evaluator)
                if let start { timings.append(StepTiming(index: i, feature: feature.id, seconds: Self.seconds(since: start))) }
            }
            newCache.append(CacheEntry(key: key, state: state))
        }
        if preview { previewCache = newCache } else { cache = newCache }

        var model = EvaluatedModel(parameters: table)
        model.bodies = state.bodies
        model.sketches = state.sketches
        model.status = state.status
        model.resolvedEdges = state.resolvedEdges
        model.references = state.references
        let meshStart = recordsTimings ? ContinuousClock.now : nil
        model.meshes = displayMeshes(for: state.bodies, preview: preview)
        if let meshStart {
            lastStepTimings = timings
            lastMeshSeconds = Self.seconds(since: meshStart)
        }
        model.bodiesBefore = bodiesBefore
        for f in document.features where model.status[f.id] == nil {
            model.status[f.id] = .inactive
        }
        return model
    }

    /// Drops all cached results (e.g. after loading a different document).
    public func reset() {
        cache = []
        previewCache = []
        meshCache = [:]
        previewMeshCache = [:]
        previousMeshCache = [:]
    }

    /// Tessellation fine enough to look smooth, scaled to the part size.
    public static func displayDeflection(for shape: Shape) -> (linear: Double, angular: Double) {
        guard let b = shape.bounds else { return (0.05, 0.3) }
        let diagonal = (b.max - b.min).length
        return (min(max(diagonal * 0.0005, 0.005), 0.5), 0.2)
    }

    private func displayMeshes(for bodies: [EvaluatedBody], preview: Bool) -> [BodyRef: Mesh] {
        func cached(_ id: ObjectIdentifier) -> Mesh? {
            meshCache[id]?.mesh ?? previewMeshCache[id]?.mesh ?? previousMeshCache[id]?.mesh
        }
        // Shapes without a cached mesh, each once.
        var pending: [Shape] = []
        var seen = Set<ObjectIdentifier>()
        for body in bodies {
            let id = ObjectIdentifier(body.shape)
            if cached(id) == nil, seen.insert(id).inserted { pending.append(body.shape) }
        }
        let fresh = Self.tessellate(pending)
        lastTessellatedCount = pending.count

        var result: [BodyRef: Mesh] = [:]
        var kept: MeshCache = [:]
        for body in bodies {
            let id = ObjectIdentifier(body.shape)
            let mesh = cached(id) ?? fresh[id] ?? .empty
            kept[id] = (body.shape, mesh)
            result[body.ref] = mesh
        }
        if preview {
            previewMeshCache = kept
        } else {
            previousMeshCache = meshCache
            meshCache = kept
        }
        return result
    }

    /// Display meshes of distinct shapes, tessellated concurrently. The kernel meshes a copy of
    /// each shape, so bodies sharing sub-shapes never write to the same topology, and a mesh is
    /// the same whichever thread makes it.
    ///
    /// Each body also meshes its faces on OCCT's thread pool. The kernel sizes that pool so
    /// concurrent loops each find threads; otherwise whichever body started its loops last would
    /// mesh on one thread. The critical path is then the slowest single face (about 85 ms on the
    /// fixture) rather than a few-face body meshed serially (Body 20: 130 ms).
    private static func tessellate(_ shapes: [Shape]) -> [ObjectIdentifier: Mesh] {
        let meshes = Mutex<[ObjectIdentifier: Mesh]>([:])
        DispatchQueue.concurrentPerform(iterations: shapes.count) { i in
            let shape = shapes[i]
            let d = displayDeflection(for: shape)
            let mesh = (try? shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)) ?? .empty
            meshes.withLock { $0[ObjectIdentifier(shape)] = mesh }
        }
        return meshes.withLock { $0 }
    }

    // MARK: - Features

    private func apply(_ feature: Feature, to state: inout State, evaluator ev: Evaluator) {
        do {
            switch feature.kind {
            case .sketch(let s): try sketch(s, feature, &state, ev)
            case .extrude(let e): try extrude(e, feature, &state, ev)
            case .revolve(let r): try revolve(r, feature, &state, ev)
            case .fillet(let f): try edgeFeature(f, fillet: true, feature, &state, ev)
            case .chamfer(let f): try edgeFeature(f, fillet: false, feature, &state, ev)
            case .shell(let s): try shell(s, feature, &state, ev)
            case .primitive(let p): try primitive(p, feature, &state, ev)
            case .combine(let c): try combine(c, feature, &state)
            case .move(let m): try move(m, feature, &state, ev)
            case .scale(let sc): try scale(sc, feature, &state, ev)
            case .loft(let l): try loft(l, feature, &state, ev)
            case .mirror(let m): try mirror(m, feature, &state, ev)
            case .pattern(let p): try pattern(p, feature, &state, ev)
            case .importedSTEP(let s): try importedSTEP(s, feature, &state)
            case .layFlat(let l): try layFlat(l, feature, &state)
            case .hole(let h): try hole(h, feature, &state, ev)
            case .pressPull(let p): try pressPull(p, feature, &state, ev)
            case .unknown(let type, _):
                throw FeatureError("“\(type)” features need a newer version of Fillet")
            }
            state.status[feature.id] = .ok
        } catch {
            state.status[feature.id] = .failed(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as FeatureError: e.message
        case let e as KernelError: e.message
        case let e as EvalError: e.message
        case let e as SketchError: e.message
        default: String(describing: error)
        }
    }

    private func sketch(_ sketch: Sketch, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let plane = try resolvePlane(sketch.plane, state, ev)
        if case .face(let face, _, _) = sketch.plane { state.references[feature.id] = [faceMatch(face, state)] }
        var curves: [UUID: [[SIMD2<Double>]]] = [:]
        var segments: [Segment2D] = []
        var errors: [UUID: String] = [:]
        for shape in sketch.shapes {
            do {
                segments += try shape.segments(using: ev)
                curves[shape.id] = shape.displayPolyline(using: ev)
            } catch {
                errors[shape.id] = Self.message(for: error)
            }
        }
        var regions: SketchRegions?
        var fills: [[SIMD2<Double>]] = []
        if !segments.isEmpty {
            let r = try SketchRegions(plane: plane, segments: segments)
            regions = r
            fills = (0..<r.count).map { r.outline($0) }
        }
        state.sketches[feature.id] = EvaluatedSketch(
            feature: feature.id, source: sketch, plane: plane, curves: curves, regions: regions,
            regionFills: fills, shapeErrors: errors)
        if let first = errors.values.first {
            throw FeatureError(errors.count == 1 ? first : "\(errors.count) shapes have errors: \(first)")
        }
    }

    private func profile(sketch id: UUID, regions refs: [RegionRef], _ state: State) throws -> (Shape, Plane) {
        guard let sketch = state.sketches[id] else { throw FeatureError("The sketch is missing or failed") }
        guard let regions = sketch.regions, regions.count > 0 else {
            throw FeatureError("The sketch has no closed profiles")
        }
        guard !refs.isEmpty else { throw FeatureError("Select at least one profile") }
        var indices: [Int] = []
        for ref in refs {
            guard let i = regions.region(containing: ref.point) else {
                throw FeatureError("A selected profile no longer exists — reselect it")
            }
            if !indices.contains(i) { indices.append(i) }
        }
        return (try regions.profile(indices: indices), sketch.plane)
    }

    private func extrude(_ e: Extrude, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let (profile, plane) = try profile(sketch: e.sketch, regions: e.regions, state)
        var forward = try ev.length(e.distance)
        var back = try e.back.map { try ev.length($0) } ?? 0
        if e.symmetric {
            back = abs(forward) / 2
            forward = abs(forward) / 2
        }
        var dir = plane.normal
        if forward < 0 && back <= 0 {
            dir = -dir
            forward = -forward
            back = -back
        }
        guard forward + back > 1e-9 else { throw FeatureError("Distance must not be zero") }
        let taper = try ev.angleRadians(e.taper)
        let tool = try profile.extruded(along: dir, distance: forward, back: back, taper: taper)
        try combineTool(tool, operation: e.operation, targets: e.targets, feature, &state)
    }

    private func revolve(_ r: Revolve, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let (profile, plane) = try profile(sketch: r.sketch, regions: r.regions, state)
        let origin: Vec3
        let dir: Vec3
        switch r.axis {
        case .x:
            origin = plane.origin; dir = plane.xDir
        case .y:
            origin = plane.origin; dir = plane.yDir
        case .sketchLine(let shapeID):
            guard let shape = state.sketches[r.sketch]?.source.shape(shapeID) else { throw FeatureError("The revolve axis line is missing") }
            guard case .line(let a, let b) = shape.kind else { throw FeatureError("The revolve axis must be a line") }
            let pa = plane.point(try a.evaluate(using: ev)), pb = plane.point(try b.evaluate(using: ev))
            guard pa.distance(to: pb) > 1e-9 else { throw FeatureError("The revolve axis has zero length") }
            origin = pa; dir = (pb - pa).normalized
        }
        let angle = try ev.angleRadians(r.angle)
        guard abs(angle) > 1e-9 else { throw FeatureError("Angle must not be zero") }
        let tool = try profile.revolved(axisOrigin: origin, axisDir: angle < 0 ? -dir : dir, angle: min(abs(angle), 2 * .pi))
        try combineTool(tool, operation: r.operation, targets: r.targets, feature, &state)
    }

    private func edgeFeature(_ f: EdgeFeature, fillet: Bool, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let (index, body) = try bodyIndex(f.body, state)
        guard !f.edges.isEmpty else { throw FeatureError("Select at least one edge") }
        let infos = body.shape.edgeInfos
        var indices: [Int] = []
        var missing = 0
        var found: [ResolvedReference?] = []
        for ref in f.edges {
            if let m = ReferenceResolver.match(ref.signature, in: infos) {
                if !indices.contains(m.index) { indices.append(m.index) }
                found.append(ResolvedReference(m, offset: ref.signature.mid.distance(to: infos[m.index].mid)))
            } else {
                missing += 1
                found.append(nil)
            }
        }
        // What the kernel is asked to round, recorded before it runs so a failed step shows it too.
        state.resolvedEdges[feature.id] = indices.map { infos[$0] }
        state.references[feature.id] = found
        if missing > 0 {
            throw FeatureError(missing == 1 ? "1 edge can no longer be found — reselect it" : "\(missing) edges can no longer be found — reselect them")
        }
        let size = try ev.length(f.size)
        guard size > 0 else { throw FeatureError("\(fillet ? "Radius" : "Distance") must be greater than zero") }
        let result = fillet
            ? try body.shape.filleted(edges: indices, radius: size)
            : try body.shape.chamfered(edges: indices, distance: size)
        state.bodies[index].shape = result
        state.bodies[index].lastFeature = feature.id
    }

    private func shell(_ s: Shell, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let (index, body) = try bodyIndex(s.body, state)
        let infos = body.shape.faceInfos
        var faces: [Int] = []
        var found: [ResolvedReference?] = []
        for ref in s.removeFaces {
            guard let m = ReferenceResolver.match(ref.signature, in: infos) else {
                throw FeatureError("A selected face can no longer be found — reselect it")
            }
            faces.append(m.index)
            found.append(ResolvedReference(m, offset: ref.signature.centroid.distance(to: infos[m.index].centroid)))
        }
        state.references[feature.id] = found
        let thickness = try ev.length(s.thickness)
        guard thickness != 0 else { throw FeatureError("Thickness must not be zero") }
        state.bodies[index].shape = try body.shape.shelled(removing: faces, thickness: thickness)
        state.bodies[index].lastFeature = feature.id
    }

    private func hole(_ h: Hole, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard let face = h.face else { throw FeatureError("Pick a flat face to drill into") }
        let (index, body) = try bodyIndex(face.body, state)
        let (_, found, plane) = try h.resolveFace(on: body.shape)
        state.references[feature.id] = [found]
        state.bodies[index].shape = try h.drilled(body.shape, plane: plane, using: ev)
    }

    private func pressPull(_ p: PressPull, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let (index, body) = try bodyIndex(p.body, state)
        guard !p.faces.isEmpty else { throw FeatureError("Select at least one face") }
        let infos = body.shape.faceInfos
        var faces: [Int] = []
        var found: [ResolvedReference?] = []
        var missing = 0
        for ref in p.faces {
            if let m = ReferenceResolver.match(ref.signature, in: infos) {
                if !faces.contains(m.index) { faces.append(m.index) }
                found.append(ResolvedReference(m, offset: ref.signature.centroid.distance(to: infos[m.index].centroid)))
            } else {
                missing += 1
                found.append(nil)
            }
        }
        state.references[feature.id] = found
        if missing > 0 {
            throw FeatureError(missing == 1 ? "1 face can no longer be found — reselect it" : "\(missing) faces can no longer be found — reselect them")
        }
        let distance = try ev.length(p.distance)
        guard distance != 0 else { throw FeatureError("Distance must not be zero") }
        state.bodies[index].shape = try body.shape.offsettingFaces(faces, by: distance)
        state.bodies[index].lastFeature = feature.id
    }

    private func primitive(_ p: Primitive, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        let plane = try resolvePlane(p.plane, state, ev)
        let base = Plane(origin: plane.point(try p.position.evaluate(using: ev)), normal: plane.normal, xDir: plane.xDir)
        func dim(_ i: Int) throws -> Double {
            guard i < p.dimensions.count else { throw FeatureError("Missing \(p.kind.dimensionNames[i])") }
            let v = try ev.length(p.dimensions[i])
            guard v >= 0 else { throw FeatureError("\(p.kind.dimensionNames[i].capitalized) must not be negative") }
            return v
        }
        let tool: Shape
        switch p.kind {
        case .box:
            let w = try dim(0), d = try dim(1), h = try dim(2)
            let local = try Shape.box(corner: Vec3(-w / 2, -d / 2, 0), size: Vec3(w, d, h))
            tool = try local.transformed(Self.frame(base))
        case .cylinder:
            tool = try Shape.cylinder(base: base, radius: try dim(0) / 2, height: try dim(1))
        case .sphere:
            tool = try Shape.sphere(center: base.origin, radius: try dim(0) / 2)
        case .cone:
            tool = try Shape.cone(base: base, radius1: try dim(0) / 2, radius2: try dim(1) / 2, height: try dim(2))
        case .torus:
            tool = try Shape.torus(base: base, majorRadius: try dim(0) / 2, minorRadius: try dim(1) / 2)
        }
        try combineTool(tool, operation: p.operation, targets: p.targets, feature, &state)
    }

    private func combine(_ c: Combine, _ feature: Feature, _ state: inout State) throws {
        let (index, target) = try bodyIndex(c.target, state)
        guard !c.tools.isEmpty else { throw FeatureError("Select at least one tool body") }
        var seen: Set<BodyRef> = [c.target]
        let tools = try c.tools.filter { seen.insert($0).inserted }.map { try bodyIndex($0, state).1.shape }
        let op = Self.booleanOp(c.operation)
        var shape = target.shape
        if tools.count > 1 {
            do {
                // One boolean with every tool: OCCT intersects and cleans up once, not per tool.
                shape = try shape.boolean(op, tools)
            } catch {
                // One tool at a time sometimes succeeds where the whole set fails.
                for tool in tools { shape = try shape.boolean(op, tool) }
            }
        } else if let tool = tools.first {
            shape = try shape.boolean(op, tool)
        }
        state.bodies[index].shape = shape
        state.bodies[index].lastFeature = feature.id
        if !c.keepTools {
            state.bodies.removeAll { c.tools.contains($0.ref) && $0.ref != c.target }
        }
    }

    private func move(_ m: Move, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard !m.bodies.isEmpty else { throw FeatureError("Select at least one body") }
        let t = try m.translation.evaluate(using: ev)
        let angle = try ev.angleRadians(m.rotationAngle)
        var transform = Transform.translation(Vec3(t))
        if abs(angle) > 1e-12 {
            var (origin, dir) = try axis(m.rotationAxis, state)
            // A world axis can pass through a chosen centre; an edge axis is where the edge is.
            if let center = m.rotationCenter, m.rotationAxis.referencedBodies.isEmpty {
                origin = Vec3(try center.evaluate(using: ev))
            }
            transform = transform.concatenating(.rotation(axis: dir, angle: angle, origin: origin))
        }
        for ref in m.bodies {
            let (i, body) = try bodyIndex(ref, state)
            state.bodies[i].shape = try body.shape.transformed(transform)
            state.bodies[i].lastFeature = feature.id
        }
    }

    private func scale(_ sc: Scale, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard !sc.bodies.isEmpty else { throw FeatureError("Select at least one body") }
        let f = SIMD3(try ev.scalar(sc.factors.x), try ev.scalar(sc.factors.y), try ev.scalar(sc.factors.z))
        guard f.x > 1e-6, f.y > 1e-6, f.z > 1e-6 else { throw FeatureError("Scale factors must be greater than zero") }
        let c = try sc.center.evaluate(using: ev)
        // M = R·S·Rᵀ: the factors apply along the turned axes (R's columns); the centre stays put.
        var m = simd_double3x3(diagonal: f)
        if let o = sc.orientation {
            let axis = SIMD3(try ev.scalar(o.axis.x), try ev.scalar(o.axis.y), try ev.scalar(o.axis.z))
            guard simd_length(axis) > 1e-9 else { throw FeatureError("The orientation axis must not be zero") }
            let r = simd_double3x3(simd_quatd(angle: try ev.angleRadians(o.angle), axis: simd_normalize(axis)))
            m = r * m * r.transpose
        }
        // Unturned, keep c·(1 − f): the same maths as c − M·c but rounded differently, and
        // every existing design's scaled bodies (and the bench digests) depend on it bit for bit.
        let t = sc.orientation == nil ? c * (SIMD3(1, 1, 1) - f) : c - m * c
        // Transform takes rows; simd matrices index columns first.
        let transform = Transform(matrix: [m[0][0], m[1][0], m[2][0], t.x, m[0][1], m[1][1], m[2][1], t.y,
                                           m[0][2], m[1][2], m[2][2], t.z])
        for ref in sc.bodies {
            let (i, body) = try bodyIndex(ref, state)
            state.bodies[i].shape = try body.shape.transformed(transform)
            state.bodies[i].lastFeature = feature.id
        }
    }

    private func loft(_ l: Loft, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard l.sections.count >= 2 else { throw FeatureError("A loft needs at least two sections") }
        var sections: [LoftSection] = []
        var previousX: Vec3?
        for (n, s) in l.sections.enumerated() {
            let normal = Vec3(try s.normal.evaluate(using: ev))
            guard normal.length > 1e-9 else { throw FeatureError("Section \(n + 1) needs a direction") }
            let z = normal.normalized
            // The width direction follows the previous section's (no twist along a bend); the first
            // uses world X, or Y when the section faces along X.
            func perpendicular(_ v: Vec3) -> Vec3? {
                let p = v - z * v.dot(z)
                return p.length > 1e-6 ? p.normalized : nil
            }
            var x = previousX.flatMap(perpendicular) ?? perpendicular(.unitX) ?? perpendicular(.unitY)!
            if let angle = s.angle {
                let a = try ev.angleRadians(angle)
                x = (x * cos(a) + z.cross(x) * sin(a)).normalized
            }
            previousX = x
            let width = try ev.length(s.width)
            let height = try s.height.map { try ev.length($0) } ?? width
            guard width >= 0, height >= 0 else { throw FeatureError("Section \(n + 1) sizes must not be negative") }
            sections.append(LoftSection(frame: Plane(origin: Vec3(try s.center.evaluate(using: ev)), normal: z, xDir: x),
                                        width: width, height: height))
        }
        let tool = try Shape.loft(sections, ruled: l.ruled)
        try combineTool(tool, operation: l.operation, targets: l.targets, feature, &state)
    }

    private func mirror(_ m: Mirror, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard !m.bodies.isEmpty else { throw FeatureError("Select at least one body") }
        let plane = try resolvePlane(m.plane, state, ev)
        for (n, ref) in m.bodies.enumerated() {
            let (i, body) = try bodyIndex(ref, state)
            let mirrored = try body.shape.mirrored(across: plane)
            if m.merge {
                state.bodies[i].shape = try body.shape.fused(with: mirrored)
                state.bodies[i].lastFeature = feature.id
            } else {
                addBody(mirrored, ref: Self.derivedRef(feature.id, n), feature, &state)
            }
        }
    }

    private func pattern(_ p: Pattern, _ feature: Feature, _ state: inout State, _ ev: Evaluator) throws {
        guard !p.bodies.isEmpty else { throw FeatureError("Select at least one body") }
        var transforms: [Transform] = []
        switch p.layout {
        case .linear(let direction, let countExpr, let spacingExpr):
            let count = try ev.integer(countExpr)
            let spacing = try ev.length(spacingExpr)
            guard count >= 1, count <= 1000 else { throw FeatureError("Count must be between 1 and 1000") }
            let (_, dir) = try axis(direction, state)
            transforms = (1..<max(count, 1)).map { Transform.translation(dir * (spacing * Double($0))) }
        case .circular(let axisRef, let countExpr, let angleExpr):
            let count = try ev.integer(countExpr)
            guard count >= 1, count <= 1000 else { throw FeatureError("Count must be between 1 and 1000") }
            let total = try ev.angleRadians(angleExpr)
            let full = abs(abs(total) - 2 * .pi) < 1e-9
            let step = count > 1 ? total / Double(full ? count : count - 1) : 0
            let (origin, dir) = try axis(axisRef, state)
            transforms = (1..<max(count, 1)).map { Transform.rotation(axis: dir, angle: step * Double($0), origin: origin) }
        }
        for ref in p.bodies {
            let (i, body) = try bodyIndex(ref, state)
            var shape = body.shape
            for t in transforms { shape = try shape.fused(with: try body.shape.transformed(t)) }
            state.bodies[i].shape = shape
            state.bodies[i].lastFeature = feature.id
        }
    }

    private func importedSTEP(_ s: ImportedSTEP, _ feature: Feature, _ state: inout State) throws {
        let shape = try Shape.fromBRep(s.brep)
        addBody(shape, ref: BodyRef(feature.id), feature, &state, name: s.name)
    }

    private func layFlat(_ l: LayFlat, _ feature: Feature, _ state: inout State) throws {
        let (i, body) = try bodyIndex(l.body, state)
        let infos = body.shape.faceInfos
        guard let m = ReferenceResolver.match(l.face.signature, in: infos) else {
            throw FeatureError("The selected face can no longer be found — reselect it")
        }
        let face = m.index
        state.references[feature.id] = [ResolvedReference(m, offset: l.face.signature.centroid.distance(to: infos[face].centroid))]
        guard let plane = body.shape.facePlane(face) else { throw FeatureError("Lay flat needs a flat face") }
        let n = plane.normal, down = -Vec3.unitZ
        var rotation = Transform.identity
        let cosA = max(-1, min(1, n.dot(down)))
        if cosA < 1 - 1e-12 {
            var axis = n.cross(down)
            if axis.length < 1e-9 { axis = .unitX }  // face points straight up: flip over X
            rotation = .rotation(axis: axis, angle: acos(cosA), origin: plane.origin)
        }
        var shape = try body.shape.transformed(rotation)
        if let b = shape.bounds { shape = try shape.translated(by: Vec3(0, 0, -b.min.z)) }
        state.bodies[i].shape = shape
        state.bodies[i].lastFeature = feature.id
    }

    // MARK: - Helpers

    /// Applies a tool solid to the model according to the feature's operation.
    /// Empty `targets` means: every body the tool overlaps (join falls back to a new body).
    private func combineTool(_ tool: Shape, operation: Operation, targets: [BodyRef], _ feature: Feature, _ state: inout State) throws {
        if operation == .newBody {
            addBody(tool, ref: BodyRef(feature.id), feature, &state)
            return
        }
        var refs = targets
        if refs.isEmpty {
            refs = state.bodies.filter { Self.boundsOverlap($0.shape, tool) }.map(\.ref)
        }
        if refs.isEmpty {
            switch operation {
            case .join:
                addBody(tool, ref: BodyRef(feature.id), feature, &state)
                return
            default:
                throw FeatureError("The \(operation == .cut ? "cut" : "intersection") doesn't touch any body")
            }
        }
        if operation == .join {
            // Fuse the tool and all targets into the first target.
            let (first, firstBody) = try bodyIndex(refs[0], state)
            var shape = try firstBody.shape.fused(with: tool)
            for ref in refs.dropFirst() {
                let (_, other) = try bodyIndex(ref, state)
                shape = try shape.fused(with: other.shape)
            }
            state.bodies[first].shape = shape
            state.bodies[first].lastFeature = feature.id
            let merged = Set(refs.dropFirst())
            state.bodies.removeAll { merged.contains($0.ref) }
            return
        }
        var lastError: Error?
        var changed = 0
        for ref in refs {
            let (i, body) = try bodyIndex(ref, state)
            do {
                state.bodies[i].shape = try body.shape.boolean(Self.booleanOp(operation), tool)
                state.bodies[i].lastFeature = feature.id
                changed += 1
            } catch {
                lastError = error
            }
        }
        if changed == 0, let lastError { throw lastError }
    }

    private func addBody(_ shape: Shape, ref: BodyRef, _ feature: Feature, _ state: inout State, name: String? = nil) {
        state.bodyCounter += 1
        state.bodies.removeAll { $0.ref == ref }
        state.bodies.append(EvaluatedBody(ref: ref, name: name ?? "Body \(state.bodyCounter)", shape: shape, lastFeature: feature.id))
    }

    private func bodyIndex(_ ref: BodyRef, _ state: State) throws -> (Int, EvaluatedBody) {
        guard let i = state.bodies.firstIndex(where: { $0.ref == ref }) else {
            throw FeatureError("A body this feature uses no longer exists")
        }
        return (i, state.bodies[i])
    }

    private func resolvePlane(_ ref: SketchPlaneRef, _ state: State, _ ev: Evaluator) throws -> Plane {
        try ref.resolve(using: ev) { face in
            guard let body = state.bodies.first(where: { $0.ref == face.body }),
                let i = ReferenceResolver.resolve(face.signature, in: body.shape.faceInfos)
            else { return nil }
            return body.shape.facePlane(i)
        }
    }

    /// How a sketch's face is found again (nil when it isn't; the sketch then uses its fallback plane).
    private func faceMatch(_ face: FaceRef, _ state: State) -> ResolvedReference? {
        guard let body = state.bodies.first(where: { $0.ref == face.body }) else { return nil }
        let infos = body.shape.faceInfos
        return ReferenceResolver.match(face.signature, in: infos).map {
            ResolvedReference($0, offset: face.signature.centroid.distance(to: infos[$0.index].centroid))
        }
    }

    /// Origin and unit direction of an axis reference.
    private func axis(_ ref: AxisRef, _ state: State) throws -> (Vec3, Vec3) {
        switch ref {
        case .x: return (.zero, .unitX)
        case .y: return (.zero, .unitY)
        case .z: return (.zero, .unitZ)
        case .edge(let e):
            let (_, body) = try bodyIndex(e.body, state)
            guard let i = ReferenceResolver.resolve(e.signature, in: body.shape.edgeInfos) else {
                throw FeatureError("The axis edge can no longer be found — reselect it")
            }
            let info = body.shape.edgeInfo(i)
            switch info.curve {
            case .line:
                return (info.start, info.tangentAtMid.normalized)
            case .circle:
                // Centre from the edge's bounding box (exact for full circles), axis ⟂ to tangent and radius.
                let edge = try body.shape.edge(i)
                guard let b = edge.bounds else { throw FeatureError("Can't use this edge as an axis") }
                let center = info.start.distance(to: info.end) < 1e-6 ? (b.min + b.max) / 2 : Self.circleCenter(info)
                let radial = (info.mid - center).normalized
                return (center, info.tangentAtMid.cross(radial).normalized * -1)
            default:
                throw FeatureError("Use a straight or circular edge as the axis")
            }
        }
    }

    /// Circumcentre of the start, mid and end points of an arc edge.
    static func circleCenter(_ e: EdgeInfo) -> Vec3 {
        let a = e.start, b = e.mid, c = e.end
        let ab = b - a, ac = c - a
        let n = ab.cross(ac)
        let denom = 2 * n.dot(n)
        guard denom > 1e-18 else { return b }
        let term1 = n.cross(ab) * ac.dot(ac)
        let term2 = ac.cross(n) * ab.dot(ab)
        return a + (term1 + term2) / denom
    }

    static func booleanOp(_ op: Operation) -> BooleanOperation {
        switch op {
        case .cut: .cut
        case .intersect: .common
        case .join, .newBody: .fuse
        }
    }

    static func boundsOverlap(_ a: Shape, _ b: Shape) -> Bool {
        guard let x = a.bounds, let y = b.bounds else { return false }
        let eps = 1e-6
        return x.min.x <= y.max.x + eps && y.min.x <= x.max.x + eps
            && x.min.y <= y.max.y + eps && y.min.y <= x.max.y + eps
            && x.min.z <= y.max.z + eps && y.min.z <= x.max.z + eps
    }

    /// Local→world transform placing the XY plane at `plane`.
    static func frame(_ plane: Plane) -> Transform {
        let x = plane.xDir, y = plane.yDir, z = plane.normal, o = plane.origin
        return Transform(matrix: [x.x, y.x, z.x, o.x, x.y, y.y, z.y, o.y, x.z, y.z, z.z, o.z])
    }

    /// Deterministic body id for the n-th extra body a feature creates.
    static func derivedRef(_ feature: UUID, _ n: Int) -> BodyRef {
        guard n > 0 else { return BodyRef(feature) }
        var bytes = feature.uuid
        bytes.15 ^= UInt8(truncatingIfNeeded: n)
        bytes.14 ^= UInt8(truncatingIfNeeded: n >> 8)
        bytes.13 ^= 0xA5
        return BodyRef(UUID(uuid: bytes))
    }
}
