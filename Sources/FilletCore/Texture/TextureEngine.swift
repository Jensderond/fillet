import FilletKernel
import Foundation
import simd

/// A texture step's result on one body: which faces, which pattern, which values.
public struct BodyTexture: Hashable, Sendable {
    /// The texture step.
    public var feature: UUID
    public var pattern: TexturePatternID
    public var values: TextureValues
    /// Signatures of the textured faces, found again on the body's final shape (later steps may
    /// have changed it). nil: every face except the ones the body rests on.
    public var faces: [FaceSignature]?

    public init(feature: UUID, pattern: TexturePatternID, values: TextureValues, faces: [FaceSignature]?) {
        self.feature = feature; self.pattern = pattern; self.values = values; self.faces = faces
    }
}

/// How finely a texture is meshed.
public struct TextureQuality: Hashable, Sendable {
    /// Multiplies each pattern's ``TexturePattern/detail`` to get the subdivision edge length.
    public var edgeScale: Double
    /// Upper bound on the result's triangles; the edge length grows to stay under it.
    public var maxTriangles: Int

    public init(edgeScale: Double, maxTriangles: Int) {
        self.edgeScale = edgeScale; self.maxTriangles = maxTriangles
    }

    /// For 3MF/STL export: the pattern's own detail.
    public static let export = TextureQuality(edgeScale: 1, maxTriangles: 2_500_000)
    /// For the viewport: coarser, so editing stays responsive (also on iPad), but fine enough
    /// that a knit's narrow stitches under a vase's rim don't alias into a crumpled band. At 2.5
    /// they did: triangles wider than a stitch leg, and the finer flanks never refined.
    public static let display = TextureQuality(edgeScale: 1.4, maxTriangles: 400_000)
}

/// Turns a body's tessellation into a textured, still watertight mesh.
///
/// 1. Welds the per-face tessellation into one indexed surface.
/// 2. Splits every edge of a textured face longer than the target length (and the same edge of
///    the untextured neighbour, so no T-junctions appear) until the textured faces are fine enough.
/// 3. Gives each point surface coordinates following its face (``SurfaceMapping``) and moves it
///    along the normal by the pattern's height. A point shared by several textured faces gets the
///    average, so shared points move once. The displacement fades to zero towards untextured
///    faces and sharp edges between textured ones (over the `fade` parameter), a cut never goes
///    deeper than ``cutSlope`` times its distance from them, and nothing pushes below the lowest
///    point (the bed).
/// 4. Shortens any displacement that would reach through a thin wall or across a narrow gap
///    (``WorkMesh/limitThroughWalls(_:ramp:where:)``), and walks back any that would fold a triangle over.
/// 5. Splits the result back into per-face vertices (for flat shading at face edges) with
///    bit-identical positions, so exporters weld it closed again.
public enum TextureEngine {
    /// Tessellation used for printing, as the exporters use it.
    public static let exportDeflection = (linear: 0.01, angular: 0.1)

    /// Faces a body rests on: flat faces facing straight down at its lowest point.
    public static func bedFaces(of shape: Shape) -> Set<Int> {
        guard let b = shape.bounds else { return [] }
        let span = max((b.max - b.min).length, 1)
        var faces = Set<Int>()
        for (i, info) in shape.faceInfos.enumerated()
        where info.surface == .plane && info.normal.normalized.z < -0.999 && info.boundsMax.z - b.min.z < 1e-4 * span {
            faces.insert(i)
        }
        return faces
    }

    /// The faces of `shape` a texture covers.
    public static func faces(of texture: BodyTexture, on shape: Shape) -> [Int] {
        let infos = shape.faceInfos
        guard let signatures = texture.faces else {
            let bed = bedFaces(of: shape)
            return infos.indices.filter { !bed.contains($0) }
        }
        var out: [Int] = []
        for s in signatures {
            if let i = ReferenceResolver.resolve(s, in: infos), !out.contains(i) { out.append(i) }
        }
        return out
    }

    /// `mesh` (a tessellation of `shape`) with `textures` applied; `mesh` itself when none applies.
    public static func apply(_ textures: [BodyTexture], to mesh: Mesh, of shape: Shape, quality: TextureQuality) -> Mesh {
        var specs: [Int32: FaceTexture] = [:]
        for (i, t) in textures.enumerated() {
            guard let pattern = TextureCatalog.make(t.pattern, t.values) else { continue }
            let fade = max(0, t.values.values["fade"] ?? 0)
            for f in faces(of: t, on: shape) {
                specs[Int32(f)] = FaceTexture(surface: FaceSurface(face: f, of: shape), pattern: pattern, fade: fade, group: i)
            }
        }
        TextureStageTimes.current?.mark("face surfaces")
        guard !specs.isEmpty else { return mesh }
        return displace(mesh, faces: specs, quality: quality)
    }

    /// One face's texture: its surface, pattern and edge fade.
    struct FaceTexture: Sendable {
        var surface: FaceSurface
        var pattern: any TexturePattern
        var fade: Double
        /// Faces with the same group come from the same texture step: a pattern laid out in space
        /// (``TexturePattern/solid(over:)``) is laid out once over all of them.
        var group = 0
    }

    /// Dihedral angle above which an edge between two textured faces counts as sharp (the texture
    /// fades out towards it instead of tearing the corner).
    static let creaseAngle = 30.0 * .pi / 180
    /// Deepest a cut may go per mm of distance from a sharp edge or an untextured face. Deeper,
    /// and a cut next to a convex corner reaches past the corner's bisector into the cut of the
    /// face on the other side (self-intersecting triangles), whatever the fade.
    static let cutSlope = 0.75
    /// How much coarser than asked for the trial subdivision is that sizes a layout in space to
    /// the triangle budget (see ``displace(_:faces:quality:)``). Its count times this squared
    /// came within 4% of the real one on the review designs (a little over: the coarser mesh has
    /// relatively more triangles in its transitions).
    static let trialScale = 1.6
    /// The share of the triangle budget the trial subdivision aims the mesh at (see
    /// ``displace(_:faces:quality:)``), leaving room for its error.
    static let budgetAim = 0.92
    /// Radius in mm over which the curvature of the surface under a layout in space is evened out
    /// (``WorkMesh/fairing(along:where:radius:)``).
    static let fairingRadius = 2.5

    /// The textured mesh for `faces` (by B-rep face index in `mesh.triangleFaces`).
    static func displace(_ mesh: Mesh, faces specs: [Int32: FaceTexture], quality: TextureQuality) -> Mesh {
        let stages = TextureStageTimes.current
        var m = WorkMesh(welding: mesh)
        guard !m.triangles.isEmpty else { return mesh }
        // Whether each face is textured, by face index: asked for every triangle in most passes
        // (dozens of them while subdividing), where hashing into `specs` cost more than the work.
        var texturedFaces = [Bool](repeating: false, count: Int(max(specs.keys.max() ?? -1, -1)) + 1)
        for f in specs.keys where f >= 0 { texturedFaces[Int(f)] = true }
        let textured: (Int32) -> Bool = { [texturedFaces] f in f >= 0 && Int(f) < texturedFaces.count && texturedFaces[Int(f)] }
        stages?.mark("weld")
        // Patterns laid out over their whole surface in space, by face.
        let solids = m.solidTextures(specs, detailScale: quality.edgeScale * quality.edgeScale)
        stages?.mark("solid layout")

        // Target edge length: the finest pattern's detail, coarsened to respect the triangle budget.
        var edge = specs.values.map { $0.pattern.detail }.min() ?? 1
        edge = max(edge * quality.edgeScale, 1e-3)
        let area = m.area { textured($0) }
        let budget = Double(max(quality.maxTriangles - m.triangles.count, 1000))
        let localScale = quality.edgeScale * quality.edgeScale
        if solids.isEmpty {
            // A triangle of edge e covers about 0.43 e²; splitting leaves them a little smaller on average.
            edge = max(edge, (1.6 * area / (0.433 * budget)).squareRoot())
        }
        // Finer triangles where a pattern asks for them (``TexturePattern/detail(at:)``), laid out
        // as on the final mesh. The display coarsens these more than the rest.
        var coarse: [Int32: (SurfaceMapping, any TexturePattern)] = [:]
        // Rings of straight walls share one mapping, so the pattern runs on across their seams.
        let bands = m.wallBands(specs)
        // Each face's edges, for patterns that keep their features inside the face.
        let borders = m.faceBorders(where: textured)
        do {
            var points: [Int32: [SIMD3<Double>]] = [:]
            // Every corner: the tessellation is still coarse (a cylinder is long strips).
            for (t, f) in m.faces.enumerated() where textured(f) {
                let tri = m.triangles[t]
                points[f, default: []] += [m.points[Int(tri.x)], m.points[Int(tri.y)], m.points[Int(tri.z)]]
            }
            for (f, spec) in specs where solids[f] == nil {
                let mapping = bands[f]
                    ?? SurfaceMapping(surface: spec.surface, cell: Self.mappingCell(spec.pattern), points: points[f] ?? [])
                guard !mapping.isTriplanar else { continue }
                coarse[f] = (mapping, spec.pattern.fitted(to: mapping.face(border: borders[f] ?? [])))
            }
        }
        stages?.mark("bands, borders, coarse mappings")
        // How much longer than asked for every triangle comes out, to stay within the budget.
        var budgetScale = 1.0
        // The layouts and coarse mappings by face index, for `wanted`, which runs for every point
        // on every core: read from arrays it shares them, where copying them out of dictionaries
        // had every core count references on the same objects.
        let solidByFace = texturedFaces.indices.map { solids[Int32($0)] }
        let coarseByFace = texturedFaces.indices.map { coarse[Int32($0)] }
        func wanted(_ p: SIMD3<Double>, _ normal: SIMD3<Double>, _ f: Int32) -> Double {
            guard f >= 0, Int(f) < solidByFace.count else { return .infinity }
            if let solid = solidByFace[Int(f)] { return max(solid.detail(at: p, normal: normal) * localScale * budgetScale, 1e-3) }
            guard let (mapping, pattern) = coarseByFace[Int(f)] else { return .infinity }
            return max(pattern.detail(at: mapping.uv(p)) * localScale * budgetScale, 1e-3)
        }
        if !solids.isEmpty {
            // A layout in space asks for fine triangles only along its features (a stone's
            // rounded edge) and coarse ones elsewhere. Capping every triangle at the length a
            // uniform mesh would need (as for the other patterns) spent the viewport's budget on
            // the stone tops: the edges came out no finer than the tops, and frayed. Instead
            // every wanted length grows by the same factor, just enough for the mesh to fit,
            // measured on a trial subdivision a little coarser (the count goes with 1 / length²).
            // The trial is skipped when a quick estimate from samples is well under the budget:
            // it leaves out the triangles between fine and coarse, so it counts up to about half.
            let estimate = m.estimatedTriangles(maxEdge: edge, where: textured) { p, normal, f in
                solids[f].map { $0.detail(at: p, normal: normal) * localScale }
            }
            if 2.5 * estimate > budget {
                let trial = Self.trialScale
                budgetScale = trial
                var probe = m
                probe.subdivide(maxEdge: edge * trial, where: textured, maxTriangles: .max, local: wanted)
                let needed = Double(probe.triangles.count - m.triangles.count) * trial * trial
                // Aimed a little under: the estimate comes within a few percent either way, and a
                // mesh that runs into the cap ends on a partial pass, uneven along the stone edges.
                let aim = Self.budgetAim * budget
                budgetScale = needed > aim ? (needed / aim).squareRoot() : 1
                edge *= budgetScale
            }
            stages?.mark("budget trial")
        }
        m.subdivide(maxEdge: edge, where: textured, maxTriangles: quality.maxTriangles, local: wanted)
        stages?.mark("subdivide")
        // Sharp round outlines (a disc's edge) meshed along their own curves (``TextureRim``).
        let rimMappings = m.followRims(specs, borders: borders, scale: quality.edgeScale)
        stages?.mark("rims")
        // Points in rows along the level lines of a pattern laid out in space (a stone's round).
        do {
            let open = m.openEdgeVertices()
            m.snapToContours(solids) { !open.contains($0) }
        }
        stages?.mark("contour snap")
        m.dissolveSlivers(where: textured)
        stages?.mark("slivers")

        let n = m.points.count
        let adjacency = m.vertexFaces()
        let normals = m.vertexNormals { textured($0) }
        let lowest = m.points.reduce(Double.infinity) { min($0, $1.z) }

        // Points that must stay put: on an untextured face or a sharp edge between textured ones.
        var pinned = [Bool](repeating: false, count: n)
        for v in 0..<n {
            for f in adjacency.faces(of: v) where !textured(f) { pinned[v] = true; break }
        }
        let creases = m.creaseVertices(angle: creaseAngle, where: textured)
        for v in m.sharpCreaseVertices(creases, angle: creaseAngle, where: textured) { pinned[v] = true }
        for v in m.openEdgeVertices() { pinned[v] = true }

        // Faded weight from the distance (along the surface) to the nearest pinned point.
        // Also far enough out to keep the deepest cut off the edges (see ``cutSlope``).
        let maxFade = specs.values.map(\.fade).max() ?? 0
        let reach = max(maxFade, Self.cutLimitRange(amplitude: specs.values.map(\.pattern.amplitude).max() ?? 0))
        stages?.mark("normals, pins")
        let distance = reach > 0 ? m.distances(from: pinned, upTo: reach) : nil
        stages?.mark("edge distances")
        // Surface mapping per face, from its points.
        var facePoints: [Int32: [SIMD3<Double>]] = [:]
        for (t, f) in m.faces.enumerated() where textured(f) {
            let tri = m.triangles[t]
            facePoints[f, default: []].append(m.points[Int(tri.x)])
        }
        var mappings: [Int32: SurfaceMapping] = [:]
        // Each face's pattern laid out for that face (see ``TexturePattern/fitted(to:)``).
        var patterns: [Int32: any TexturePattern] = [:]
        for (f, spec) in specs where solids[f] == nil {
            // A face re-meshed along rims keeps the mapping its rims were laid out in.
            let mapping = rimMappings[f] ?? bands[f]
                ?? SurfaceMapping(surface: spec.surface, cell: Self.mappingCell(spec.pattern), points: facePoints[f] ?? [])
            mappings[f] = mapping
            patterns[f] = spec.pattern.fitted(to: mapping.face(border: borders[f] ?? []))
        }
        stages?.mark("face mappings")

        let amplitudeLimit = max(specs.values.map(\.pattern.amplitude).max() ?? 0, 1e-3)
        var offsets = [SIMD3<Double>](repeating: .zero, count: n)
        // Displacement along each point's direction, and whether the point is under a layout in
        // space (its normal smoothed and the surface faired there).
        var directions = [SIMD3<Double>](repeating: .zero, count: n)
        var amounts = [Double](repeating: 0, count: n)
        var smoothed = [Bool](repeating: false, count: n)
        // A layout in space runs across every face, including the kernel's corner blends, whose
        // normals can swing by several degrees within a tenth of a millimetre: a joint cut 1 mm
        // deep along them spreads its points sideways enough to fold the fine triangles over, and
        // the layout itself (measured in the tangent plane) jumps with them. So the normals there
        // are smoothed over about a joint's depth in space first (see
        // ``WorkMesh/smoothDirections(_:where:radius:)``), and the layout sampled and cut along them.
        var solidNormals = [SIMD3<Double>](repeating: .zero, count: n)
        if !solids.isEmpty {
            for v in 0..<n where !pinned[v] {
                var sum = SIMD3<Double>.zero
                for f in adjacency.faces(of: v) where solids[f] != nil {
                    let own = m.surfaceNormal(Int32(v), face: f)
                    sum += own != .zero ? own : normals[v]
                }
                guard simd_length(sum) > 1e-9 else { continue }
                solidNormals[v] = simd_normalize(sum)
                smoothed[v] = true
            }
            let solidAmplitude = specs.filter { solids[$0.key] != nil }.map(\.value.pattern.amplitude).max() ?? 0
            m.smoothDirections(&solidNormals, where: smoothed, radius: max(solidAmplitude, 0.1))
            stages?.mark("smooth normals")
        }
        do {
            // Each point on its own, across the cores; the layouts, mappings and patterns by face
            // in arrays (see `solidByFace`).
            let fadeByFace = texturedFaces.indices.map { specs[Int32($0)]?.fade }
            let mappingByFace = texturedFaces.indices.map { mappings[Int32($0)] }
            let patternByFace = texturedFaces.indices.map { patterns[Int32($0)] }
            let mesh = m, pinned = pinned, solidNormals = solidNormals
            let sampled = concurrentMap(n) { v -> (direction: SIMD3<Double>, amount: Double)? in
                guard !pinned[v] else { return nil }
                var height = 0.0, direction = SIMD3<Double>.zero, count = 0.0, fade = 0.0
                for f in adjacency.faces(of: v) {
                    guard f >= 0, Int(f) < fadeByFace.count, let faceFade = fadeByFace[Int(f)] else { continue }
                    // Along the surface's own normal: the triangles' differs by a degree or two from one
                    // facet of the tessellation to the next, enough to fold a disc's thin rim strips.
                    let own = mesh.surfaceNormal(Int32(v), face: f)
                    let s: (height: Double, normal: SIMD3<Double>)
                    if let solid = solidByFace[Int(f)] {
                        s = (solid.height(at: mesh.points[v], normal: solidNormals[v]), solidNormals[v])
                    } else if let mapping = mappingByFace[Int(f)], let pattern = patternByFace[Int(f)] {
                        s = mapping.sample(mesh.points[v], normal: own != .zero ? own : normals[v], pattern)
                    } else {
                        continue
                    }
                    height += s.height
                    direction += s.normal
                    fade = max(fade, faceFade)
                    count += 1
                }
                guard count > 0, simd_length(direction) > 1e-9 else { return nil }
                var weight = 1.0
                if fade > 0, let d = distance?[v], d < fade {
                    let t = d / fade
                    weight = t * t * (3 - 2 * t)
                }
                var offset = height / count * weight
                if offset < 0, let d = distance?[v] {
                    // Rounded into the limit rather than clipped by it, so where the limit takes
                    // over the cut doesn't break into a crease.
                    let limit = Self.cutLimit(at: d, amplitude: amplitudeLimit)
                    if limit.isFinite {
                        let width = min(0.3 * amplitudeLimit, limit)
                        offset = width > 0 ? min(Self.smoothMax(offset, -limit, width: width), 0) : 0
                    }
                }
                return (simd_normalize(direction), offset)
            }
            for v in 0..<n {
                guard let s = sampled[v] else { continue }
                directions[v] = s.direction
                amounts[v] = s.amount
            }
        }
        stages?.mark("height sampling")
        // Where a flat face meets a fillet the curvature jumps, which shades as a crisp line at any
        // fine tessellation; across a stone it read as a seam slicing it. Faired out under a
        // layout in space (see ``WorkMesh/fairing(along:where:radius:)``), faded in from the
        // pinned edges.
        if smoothed.contains(true) {
            let fair = m.fairing(along: directions, where: smoothed, radius: Self.fairingRadius)
            for v in 0..<n where smoothed[v] && !pinned[v] {
                var weight = 1.0
                if reach > 0, let d = distance?[v], d < reach {
                    let t = d / reach
                    weight = t * t * (3 - 2 * t)
                }
                amounts[v] += fair[v] * weight
            }
            stages?.mark("fairing")
        }
        for v in 0..<n where amounts[v] != 0 { offsets[v] = directions[v] * amounts[v] }

        // A crevice deeper than the wall is thick must not come out the other side.
        let amplitude = specs.values.map(\.pattern.amplitude).max() ?? 0
        m.limitThroughWalls(&offsets, ramp: max(2 * amplitude, 1), where: textured)
        stages?.mark("wall limit")
        m.relax(&offsets, floor: lowest)
        let base = m.points
        for v in 0..<n {
            var p = m.points[v] + offsets[v]
            if offsets[v] != .zero { p.z = max(p.z, lowest) }
            m.points[v] = p
        }
        // Not on a layout in space: its relief has no creases (a stone's edge is a smooth round),
        // and flipping towards the least bend there chained into fans of needle triangles that
        // shaded as spikes along the stone edges.
        stages?.mark("relax folds")
        m.alignCreases(base: base) { textured($0) && solids[$0] == nil }
        stages?.mark("crease flips")
        let result = m.mesh(keeping: mesh)
        stages?.mark("mesh assembly")
        return result
    }

    /// Deepest a cut may go `d` mm (straight) from a sharp or untextured edge, for patterns at
    /// most `amplitude` deep; infinite (no limit) from ``cutLimitRange(amplitude:)`` on.
    ///
    /// Never deeper than ``cutSlope`` · `d`, but rising from the edge along a smootherstep rather
    /// than that straight line: it leaves the edge level and runs into the full depth level, with
    /// no bend for the triangles to cut across. A straight ramp met the joint floor in a bend
    /// a few tenths of a millimetre wide, finer than the joint floor's triangles, and the joints
    /// ran into a rim or the bed in a saw-toothed line. It tops out a little over `amplitude`, so
    /// the full depth meets it (and the rounding into it) before it ends.
    static func cutLimit(at d: Double, amplitude: Double) -> Double {
        let range = cutLimitRange(amplitude: amplitude)
        guard d < range else { return .infinity }
        let t = max(d, 0) / range
        return cutLimitTop * amplitude * t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// How far from an edge ``cutLimit(at:amplitude:)`` holds: where its smootherstep, whose
    /// steepest secant from the edge is 1.2 (just over, to be safe) times its average slope, stays
    /// within ``cutSlope``.
    static func cutLimitRange(amplitude: Double) -> Double {
        1.21 * cutLimitTop * amplitude / cutSlope
    }

    /// ``cutLimit(at:amplitude:)`` tops out this many times the amplitude: room for the rounding
    /// into it (0.3 of the amplitude) before it ends.
    static let cutLimitTop = 1.3

    /// The larger of `a` and `b`, rounded over `width` where they are close (never smaller than
    /// either).
    static func smoothMax(_ a: Double, _ b: Double, width: Double) -> Double {
        let h = max(width - abs(a - b), 0) / width
        return max(a, b) + h * h * width / 4
    }

    /// The repeat a face's u is fitted to: the pattern's cell, or (for a pattern that spaces
    /// itself around closed faces) a tiny one, which leaves u as plain arc length.
    static func mappingCell(_ pattern: any TexturePattern) -> SIMD2<Double> {
        pattern.fitsAround ? SIMD2(1e-6, pattern.cell.y) : pattern.cell
    }
}

// MARK: - Working mesh

/// An indexed triangle mesh in double precision, with the B-rep face of each triangle.
struct WorkMesh {
    var points: [SIMD3<Double>]
    var triangles: [SIMD3<Int32>]
    var faces: [Int32]
    /// The surface's own unit normal at each point (outward), carried from the kernel's
    /// tessellation and interpolated for the points added since. Unlike normals from the
    /// triangles these don't jump at the tessellation's facets, so neighbouring points a few
    /// microns apart (a disc's rim strips) move in the same direction. A point on an edge between
    /// faces has each face's own in ``edgeNormals``. Empty when the mesh came without normals.
    var surfaceNormals: [SIMD3<Double>] = []
    /// Each face's own normal at the points on edges between faces, by ``pointFace(_:_:)``.
    var edgeNormals: [UInt64: SIMD3<Double>] = [:]

    init(points: [SIMD3<Double>], triangles: [SIMD3<Int32>], faces: [Int32]) {
        self.points = points; self.triangles = triangles; self.faces = faces
    }

    /// Welds the per-face vertices of a kernel tessellation (shared edges have identical points).
    init(welding mesh: Mesh) {
        var index: [SIMD3<Float>: Int32] = [:]
        index.reserveCapacity(mesh.positions.count)
        var remap: [Int32] = []
        remap.reserveCapacity(mesh.positions.count)
        var points: [SIMD3<Double>] = []
        for p in mesh.positions {
            if let i = index[p] {
                remap.append(i)
            } else {
                let i = Int32(points.count)
                index[p] = i
                remap.append(i)
                points.append(SIMD3<Double>(p))
            }
        }
        var triangles: [SIMD3<Int32>] = []
        var faces: [Int32] = []
        triangles.reserveCapacity(mesh.indices.count / 3)
        for t in 0..<(mesh.indices.count / 3) {
            let raw = (Int(mesh.indices[3 * t]), Int(mesh.indices[3 * t + 1]), Int(mesh.indices[3 * t + 2]))
            guard raw.0 < remap.count, raw.1 < remap.count, raw.2 < remap.count else { continue }
            let tri = SIMD3(remap[raw.0], remap[raw.1], remap[raw.2])
            guard tri.x != tri.y, tri.y != tri.z, tri.x != tri.z else { continue }
            triangles.append(tri)
            faces.append(t < mesh.triangleFaces.count ? mesh.triangleFaces[t] : -1)
        }
        self.init(points: points, triangles: triangles, faces: faces)
        guard mesh.normals.count == mesh.positions.count else { return }
        // Each face's own normal at its points; a point several faces share keeps all of them.
        var normals = [SIMD3<Double>](repeating: .zero, count: points.count)
        var owner = [Int32](repeating: Int32.min, count: points.count)
        for t in 0..<(mesh.indices.count / 3) {
            let f = t < mesh.triangleFaces.count ? mesh.triangleFaces[t] : -1
            for k in 0..<3 {
                let raw = Int(mesh.indices[3 * t + k])
                guard raw < remap.count else { continue }
                let v = Int(remap[raw])
                let n = Self.unit(SIMD3<Double>(mesh.normals[raw]))
                if owner[v] == Int32.min {
                    owner[v] = f
                    normals[v] = n
                } else if owner[v] != f {
                    edgeNormals[Self.pointFace(Int32(v), owner[v])] = normals[v]
                    edgeNormals[Self.pointFace(Int32(v), f)] = n
                }
            }
        }
        surfaceNormals = normals
    }

    /// Key of point `v` on face `f` in ``edgeNormals``.
    static func pointFace(_ v: Int32, _ f: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: v)) << 32 | UInt64(UInt32(bitPattern: f))
    }

    /// The surface normal at point `v` of face `f` (zero when unknown).
    func surfaceNormal(_ v: Int32, face f: Int32) -> SIMD3<Double> {
        guard Int(v) < surfaceNormals.count else { return .zero }
        if !edgeNormals.isEmpty, let n = edgeNormals[Self.pointFace(v, f)] { return n }
        return surfaceNormals[Int(v)]
    }

    /// `v` scaled to length 1, or zero when it has none.
    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : .zero
    }

    /// One edge of a face's outline (see ``faceBorders(where:)``).
    struct FaceEdge {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        /// The face on the other side is accepted too and meets this one smoothly (at less than
        /// ``TextureEngine/creaseAngle``): a seam inside the textured area, not its outer edge.
        var seam: Bool
    }

    /// The edges of each face `include` accepts: triangle edges whose other side is another face
    /// or nothing, as segments in space.
    func faceBorders(where include: (Int32) -> Bool) -> [Int32: [FaceEdge]] {
        var owners: [UInt64: (Int, Int)] = [:]
        owners.reserveCapacity(triangles.count * 3 / 2)
        for (t, tri) in triangles.enumerated() {
            for k in 0..<3 {
                let key = Self.key(tri[k], tri[(k + 1) % 3])
                if let o = owners[key] {
                    owners[key] = (o.0, t)
                } else {
                    owners[key] = (t, -1)
                }
            }
        }
        func normal(_ t: Int) -> SIMD3<Double> {
            let tri = triangles[t]
            let a = points[Int(tri.x)]
            return Self.unit(simd_cross(points[Int(tri.y)] - a, points[Int(tri.z)] - a))
        }
        let cosCrease = cos(TextureEngine.creaseAngle)
        var out: [Int32: [FaceEdge]] = [:]
        for (key, o) in owners {
            let f0 = faces[o.0], f1 = o.1 >= 0 ? faces[o.1] : -2
            guard f0 != f1 else { continue }
            let a = Int(Int32(bitPattern: UInt32(key >> 32))), b = Int(Int32(bitPattern: UInt32(key & 0xFFFF_FFFF)))
            let inside = f0 >= 0 && f1 >= 0 && include(f0) && include(f1)
            let seam = inside && simd_dot(normal(o.0), normal(o.1)) > cosCrease
            for f in [f0, f1] where f >= 0 && include(f) { out[f, default: []].append(FaceEdge(a: points[a], b: points[b], seam: seam)) }
        }
        return out
    }

    /// About how many triangles ``subdivide(maxEdge:where:maxTriangles:local:)`` makes of the faces
    /// `include` accepts with these lengths: `local` (nil: none asked for) is sampled at points
    /// spread evenly over them, each standing for its share of the area, capped at `maxEdge`.
    func estimatedTriangles(maxEdge: Double, where include: (Int32) -> Bool,
                            local: (SIMD3<Double>, SIMD3<Double>, Int32) -> Double?) -> Double {
        let total = area(where: include)
        guard total > 0, maxEdge > 0 else { return 0 }
        // About 40 000 samples in all, at least one per triangle.
        let share = total / 40_000
        // The lengths wanted at each triangle's samples, across the cores (each is a pattern
        // sample), then added up one by one in the same order as ever.
        var sampled: [(t: Int, size: Double, samples: Int)] = []
        for (t, tri) in triangles.enumerated() where include(faces[t]) {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let size = simd_length(simd_cross(b - a, c - a)) / 2
            guard size > 0 else { continue }
            sampled.append((t, size, max(1, Int((size / share).rounded(.up)))))
        }
        let lengths = concurrentMap(sampled.count, chunk: 64) { i -> [Double] in
            let (t, size, samples) = sampled[i]
            let tri = triangles[t]
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let cross = simd_cross(b - a, c - a)
            let normal = cross / (2 * size)
            return (0..<samples).map { k in
                // A low-discrepancy (R2) sequence folded into the triangle.
                var u = (0.5 + 0.754_877_666 * Double(k + 1)).truncatingRemainder(dividingBy: 1)
                var v = (0.5 + 0.569_840_291 * Double(k + 1)).truncatingRemainder(dividingBy: 1)
                if u + v > 1 { u = 1 - u; v = 1 - v }
                let p = a + u * (b - a) + v * (c - a)
                return min(local(p, normal, faces[t]) ?? maxEdge, maxEdge)
            }
        }
        var count = 0.0
        for (i, (_, size, samples)) in sampled.enumerated() {
            for e in lengths[i] {
                // A triangle of edge e covers about 0.43 e²; splitting leaves them a little smaller on average.
                count += 1.6 * (size / Double(samples)) / (0.433 * max(e * e, 1e-6))
            }
        }
        return count
    }

    func area(where include: (Int32) -> Bool) -> Double {
        var total = 0.0
        for (t, tri) in triangles.enumerated() where include(faces[t]) {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            total += simd_length(simd_cross(b - a, c - a)) / 2
        }
        return total
    }

    static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        let lo = UInt64(UInt32(bitPattern: min(a, b))), hi = UInt64(UInt32(bitPattern: max(a, b)))
        return lo << 32 | hi
    }

    /// Longest-edge bisection: each pass splits the longest edge of every triangle of a face
    /// `include` accepts while it is longer than `maxEdge`, and the neighbouring triangle on the
    /// same edge too (whatever its face), so the mesh stays conforming. Bisecting the longest
    /// edge keeps triangles well shaped, even from the long thin strips a cylinder tessellates into.
    /// `local`, when given, is the edge length wanted at a point of a face (squared and capped at
    /// `maxEdge`); a triangle is split while its longest edge is longer than the smallest
    /// length wanted at its corners.
    mutating func subdivide(maxEdge: Double, where include: (Int32) -> Bool, maxTriangles: Int,
                            local: ((SIMD3<Double>, SIMD3<Double>, Int32) -> Double)? = nil) {
        let limit = maxEdge * maxEdge
        // The squared length wanted at each point (-1: not yet known), on the face of the first
        // triangle (in order) that needed it.
        var wanted: [Double] = []
        // The points whose edges ``improve(where:passes:dirty:)`` must look at again (nil: all).
        var dirty: [Bool]? = nil
        for _ in 0..<64 {
            if let local {
                // The points this pass looks at for the first time, on that face, looked up
                // across the cores first (each is a pattern sample, often the most of a pass).
                if wanted.count < points.count { wanted.append(contentsOf: repeatElement(-1, count: points.count - wanted.count)) }
                var todo: [Int32] = [], todoFaces: [Int32] = []
                for t in triangles.indices where include(faces[t]) {
                    let tri = triangles[t]
                    for k in 0..<3 where wanted[Int(tri[k])] < 0 && wanted[Int(tri[k])] != -2 {
                        wanted[Int(tri[k])] = -2
                        todo.append(tri[k])
                        todoFaces.append(faces[t])
                    }
                }
                let mesh = self
                let found = concurrentMap(todo.count) { i in
                    let v = todo[i], f = todoFaces[i]
                    let e = min(local(mesh.points[Int(v)], mesh.surfaceNormal(v, face: f), f), maxEdge)
                    return e * e
                }
                for (i, v) in todo.enumerated() { wanted[Int(v)] = found[i] }
            }
            // Edges to split this pass, in triangle order, with how far each is over its length.
            var wantedSplits: [(key: UInt64, a: Int32, b: Int32, face: Int32, excess: Double)] = []
            var seen = EdgeMap<Bool>(capacity: 1024, filler: true)
            for t in triangles.indices where include(faces[t]) {
                let tri = triangles[t]
                var best = -1.0, bestK = 0
                for k in 0..<3 {
                    let d = simd_distance_squared(points[Int(tri[k])], points[Int(tri[(k + 1) % 3])])
                    if d > best { best = d; bestK = k }
                }
                let f = faces[t]
                let wantedHere = local == nil ? limit : min(wanted[Int(tri.x)], wanted[Int(tri.y)], wanted[Int(tri.z)])
                guard best > wantedHere else { continue }
                let a = tri[bestK], b = tri[(bestK + 1) % 3]
                let k = Self.key(a, b)
                if !seen.findOrInsert(k).found { wantedSplits.append((k, a, b, f, best / max(wantedHere, 1e-12))) }
            }
            if wantedSplits.isEmpty { break }
            // Over the budget: only the edges furthest over their length, as many as fit (each
            // split adds about two triangles), and this is the last pass.
            let room = (maxTriangles - triangles.count) / 2
            var last = false
            if wantedSplits.count > room {
                guard room > 0 else { break }
                let cut = wantedSplits.map(\.excess).sorted(by: >)[room - 1]
                var kept = 0
                wantedSplits = wantedSplits.filter { split in
                    guard split.excess >= cut, kept < room else { return false }
                    kept += 1
                    return true
                }
                last = true
            }
            var mids = EdgeMap<Int32>(capacity: wantedSplits.count, filler: -1)
            // The ends of the edges split: only an edge with both ends among them can be one.
            var splitEnd = [Bool](repeating: false, count: points.count)
            for split in wantedSplits {
                mids.set(split.key, Int32(points.count))
                points.append(curvedMidpoint(split.a, split.b, face: split.face))
                if surfaceNormals.count == points.count - 1 {
                    surfaceNormals.append(Self.unit(surfaceNormal(split.a, face: split.face) + surfaceNormal(split.b, face: split.face)))
                }
            }
            for s in wantedSplits { splitEnd[Int(s.a)] = true; splitEnd[Int(s.b)] = true }
            func mid(_ a: Int32, _ b: Int32) -> Int32? {
                splitEnd[Int(a)] && splitEnd[Int(b)] ? mids[Self.key(a, b)] : nil
            }
            if dirty != nil { dirty!.append(contentsOf: repeatElement(false, count: points.count - dirty!.count)) }
            var newTriangles: [SIMD3<Int32>] = []
            var newFaces: [Int32] = []
            newTriangles.reserveCapacity(triangles.count + 2 * mids.count)
            newFaces.reserveCapacity(triangles.count + 2 * mids.count)
            for t in triangles.indices {
                let v = triangles[t]
                let e0 = mid(v[0], v[1]), e1 = mid(v[1], v[2]), e2 = mid(v[2], v[0])
                let f = faces[t]
                func add(_ a: Int32, _ b: Int32, _ c: Int32) {
                    newTriangles.append(SIMD3(a, b, c))
                    newFaces.append(f)
                    dirty?[Int(a)] = true; dirty?[Int(b)] = true; dirty?[Int(c)] = true
                }
                func e(_ r: Int) -> Int32? { r == 0 ? e0 : (r == 1 ? e1 : e2) }
                // A point splitting an edge between faces: each face's normal there.
                if !edgeNormals.isEmpty {
                    for r in 0..<3 {
                        guard let m = e(r) else { continue }
                        let a = v[r], b = v[(r + 1) % 3]
                        guard edgeNormals[Self.pointFace(a, f)] != nil, edgeNormals[Self.pointFace(b, f)] != nil else { continue }
                        edgeNormals[Self.pointFace(m, f)] = Self.unit(surfaceNormal(a, face: f) + surfaceNormal(b, face: f))
                    }
                }
                switch (e0 != nil ? 1 : 0) + (e1 != nil ? 1 : 0) + (e2 != nil ? 1 : 0) {
                case 0:
                    newTriangles.append(v)
                    newFaces.append(f)
                case 1:
                    let r = e0 != nil ? 0 : (e1 != nil ? 1 : 2)
                    let a = v[r], b = v[(r + 1) % 3], c = v[(r + 2) % 3], m = e(r)!
                    add(a, m, c)
                    add(m, b, c)
                case 2:
                    // Rotate so the unsplit edge is (c, a).
                    let k = e0 == nil ? 0 : (e1 == nil ? 1 : 2)
                    let r = (k + 1) % 3
                    let a = v[r], b = v[(r + 1) % 3], c = v[(r + 2) % 3]
                    let mab = e(r)!, mbc = e((r + 1) % 3)!
                    add(mab, b, mbc)
                    if simd_distance_squared(points[Int(a)], points[Int(mbc)]) < simd_distance_squared(points[Int(mab)], points[Int(c)]) {
                        add(a, mab, mbc)
                        add(a, mbc, c)
                    } else {
                        add(a, mab, c)
                        add(mab, mbc, c)
                    }
                default:
                    let m0 = e0!, m1 = e1!, m2 = e2!
                    add(v[0], m0, m2)
                    add(m0, v[1], m1)
                    add(m2, m1, v[2])
                    add(m0, m1, m2)
                }
            }
            triangles = newTriangles
            faces = newFaces
            improve(where: include, dirty: &dirty)
            if last { break }
        }
        improve(where: include, passes: 4, dirty: &dirty)
    }

    /// The point halfway along edge (`a`, `b`) on the face's curved surface rather than on the
    /// straight edge: the midpoint of the cubic through both ends that leaves each across its
    /// surface normal there (as in PN triangles). The kernel's tessellation of a cylinder is flat
    /// strips a few degrees apart, and splitting them on the chord kept those facets: on a
    /// textured wall they showed as straight streaks along the strips' edges. Points split along
    /// the curve land within a hair of the true surface, so the facets smooth out as the mesh
    /// gets finer. The straight midpoint when the normals are unknown or too far apart to be one
    /// smooth surface.
    func curvedMidpoint(_ a: Int32, _ b: Int32, face f: Int32) -> SIMD3<Double> {
        let pa = points[Int(a)], pb = points[Int(b)]
        let mid = (pa + pb) / 2
        let na = surfaceNormal(a, face: f), nb = surfaceNormal(b, face: f)
        guard na != .zero, nb != .zero, simd_dot(na, nb) > 0.5 else { return mid }
        let d = pb - pa
        var bow = (simd_dot(d, nb) * nb - simd_dot(d, na) * na) / 8
        // Never more than a cylinder's quarter turn would bulge.
        let most = 0.15 * simd_length(d), length = simd_length(bow)
        if length > most { bow *= most / length }
        return mid + bow
    }

    /// Delaunay edge flips inside each face `include` accepts: an edge whose opposite angles add
    /// up to more than 180° is swapped for the other diagonal (when the two triangles are nearly
    /// coplanar and the quad is convex), so splitting leaves round triangles, not needles.
    ///
    /// `dirty`, when given, marks the points whose edges can have changed since the last pass
    /// looked at them: every corner of a triangle made or changed since (by splitting or a flip).
    /// Only edges with both ends dirty are looked at, and on return it marks the corners of the
    /// triangles this call flipped (none dirty when it ended on a pass without flips). Subdividing
    /// runs a pass after every split, and in the later ones only the stone edges or other fine
    /// bands still split: looking up every edge of the mesh each time was most of subdividing.
    /// The flips come out the same as looking at every edge: an edge with an end that isn't dirty
    /// lies only between triangles unchanged since a pass that looked at it (any triangle made or
    /// changed on it would have dirtied both its ends), in the same order (splitting and flips
    /// keep it), with the points fixed. That pass found nothing to flip there, which depends on
    /// nothing else, and no triangle on it can flip in this pass either (it would have changed),
    /// so skipping it changes neither the flips nor which triangle owns each other edge. Nil
    /// looks at every edge (the first pass after a split of a mesh never improved).
    mutating func improve(where include: (Int32) -> Bool, passes: Int = 1, dirty: inout [Bool]?) {
        let coplanar = cos(25.0 * .pi / 180)
        for _ in 0..<passes {
            // The triangles with an edge to look at, in order.
            var visit: [Int] = []
            if let dirty {
                for t in triangles.indices where include(faces[t]) {
                    let tri = triangles[t]
                    if (dirty[Int(tri.x)] ? 1 : 0) + (dirty[Int(tri.y)] ? 1 : 0) + (dirty[Int(tri.z)] ? 1 : 0) >= 2 { visit.append(t) }
                }
            } else {
                visit = triangles.indices.filter { include(faces[$0]) }
            }
            var owner = EdgeMap<Int32>(capacity: visit.count * 3 / 2, filler: -1)
            var touched = [Bool](repeating: false, count: triangles.count)
            var flipped: [Int] = []
            for t in visit {
                let tri = triangles[t]
                for k in 0..<3 {
                    let a = tri[k], b = tri[(k + 1) % 3]
                    if let dirty, !dirty[Int(a)] || !dirty[Int(b)] { continue }
                    let (slot, found) = owner.findOrInsert(Self.key(a, b))
                    guard found else { owner.set(slot: slot, Int32(t)); continue }
                    let u = Int(owner.values[slot])
                    guard !touched[t], !touched[u], faces[u] == faces[t] else { continue }
                    let c = tri[(k + 2) % 3]
                    let o = triangles[u]
                    // The other triangle runs b → a; its third corner is d.
                    var d: Int32 = -1
                    for j in 0..<3 where o[j] == b && o[(j + 1) % 3] == a { d = o[(j + 2) % 3] }
                    guard d >= 0, d != c else { continue }
                    let pa = points[Int(a)], pb = points[Int(b)], pc = points[Int(c)], pd = points[Int(d)]
                    // Both opposite angles acute: each atan2 below comes out at most π/2 (to an
                    // ulp), their sum nowhere near the 1e-9 over π the flip needs. Most edges
                    // are, and this spares them the two atan2.
                    if simd_dot(pa - pc, pb - pc) > 0, simd_dot(pb - pd, pa - pd) > 0 { continue }
                    func angle(_ at: SIMD3<Double>, _ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double {
                        let x = p - at, y = q - at
                        return atan2(simd_length(simd_cross(x, y)), simd_dot(x, y))
                    }
                    guard angle(pc, pa, pb) + angle(pd, pb, pa) > .pi + 1e-9 else { continue }
                    let n1 = simd_cross(pb - pa, pc - pa), n2 = simd_cross(pa - pb, pd - pb)
                    let l1 = simd_length(n1), l2 = simd_length(n2)
                    guard l1 > 0, l2 > 0, simd_dot(n1, n2) > coplanar * l1 * l2 else { continue }
                    // New triangles (c, a, d) and (c, d, b) must face the same way as before.
                    let m1 = simd_cross(pa - pc, pd - pc), m2 = simd_cross(pd - pc, pb - pc)
                    guard simd_dot(m1, n1) > 0, simd_dot(m2, n1) > 0, simd_dot(m1, n2) > 0, simd_dot(m2, n2) > 0 else { continue }
                    triangles[t] = SIMD3(c, a, d)
                    triangles[u] = SIMD3(c, d, b)
                    touched[t] = true
                    touched[u] = true
                    flipped.append(t)
                    flipped.append(u)
                    break
                }
            }
            var next = [Bool](repeating: false, count: points.count)
            for t in flipped {
                let tri = triangles[t]
                next[Int(tri.x)] = true; next[Int(tri.y)] = true; next[Int(tri.z)] = true
            }
            dirty = next
            if flipped.isEmpty { return }
        }
    }

    /// Faces around each vertex: most vertices have one, those on face boundaries several.
    struct VertexFaces {
        var first: [Int32]
        var more: [Int: [Int32]]

        func faces(of v: Int) -> [Int32] {
            if let extra = more[v] { return extra }
            return first[v] == Int32.min ? [] : [first[v]]
        }

        /// Whether vertex `v` is on face `f`.
        func contains(_ v: Int, _ f: Int32) -> Bool {
            if first[v] == f { return true }
            return more.isEmpty ? false : more[v]?.contains(f) ?? false
        }
    }

    func vertexFaces() -> VertexFaces {
        var first = [Int32](repeating: Int32.min, count: points.count)
        var more: [Int: [Int32]] = [:]
        for (t, tri) in triangles.enumerated() {
            let f = faces[t]
            for v in [Int(tri.x), Int(tri.y), Int(tri.z)] {
                if first[v] == Int32.min {
                    first[v] = f
                } else if first[v] != f || more[v] != nil {
                    var list = more[v] ?? [first[v]]
                    if !list.contains(f) { list.append(f) }
                    more[v] = list
                }
            }
        }
        return VertexFaces(first: first, more: more)
    }

    /// Area-weighted vertex normals from the triangles of faces `include` accepts (others: all).
    func vertexNormals(where include: (Int32) -> Bool) -> [SIMD3<Double>] {
        var sums = [SIMD3<Double>](repeating: .zero, count: points.count)
        var fallback = [SIMD3<Double>](repeating: .zero, count: points.count)
        for (t, tri) in triangles.enumerated() {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let n = simd_cross(b - a, c - a)
            let use = include(faces[t])
            for v in [Int(tri.x), Int(tri.y), Int(tri.z)] {
                if use { sums[v] += n } else { fallback[v] += n }
            }
        }
        return sums.indices.map { i in
            let s = simd_length(sums[i]) > 0 ? sums[i] : fallback[i]
            let l = simd_length(s)
            return l > 0 ? s / l : .zero
        }
    }

    /// Endpoints of edges between two faces both accepted by `include` whose triangles meet at
    /// more than `angle`.
    func creaseVertices(angle: Double, where include: (Int32) -> Bool) -> Set<Int> {
        let boundary = vertexFaces()
        // Points on more than one face (only their edges can be between faces).
        var shared = [Bool](repeating: false, count: points.count)
        for v in boundary.more.keys { shared[v] = true }
        var seen = EdgeMap<(face: Int32, normal: SIMD3<Double>)>(capacity: 1024, filler: (-1, .zero))
        var out = Set<Int>()
        let cosLimit = cos(angle)
        for (t, tri) in triangles.enumerated() where include(faces[t]) {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let cross = simd_cross(b - a, c - a)
            let l = simd_length(cross)
            let normal = l > 0 ? cross / l : .zero
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                guard shared[Int(p)], shared[Int(q)] else { continue }
                let (slot, found) = seen.findOrInsert(Self.key(p, q))
                if found {
                    let other = seen.values[slot]
                    if other.face != faces[t], simd_dot(other.normal, normal) < cosLimit {
                        out.insert(Int(p))
                        out.insert(Int(q))
                    }
                } else {
                    seen.set(slot: slot, (faces[t], normal))
                }
            }
        }
        return out
    }

    /// Each face whose pattern lays itself out in space (``TexturePattern/solid(over:)``): the
    /// layout over all faces of its texture step, made from their triangles as they are now.
    /// `detailScale` is how much coarser than the patterns' own detail the mesh is made.
    func solidTextures(_ specs: [Int32: TextureEngine.FaceTexture], detailScale: Double) -> [Int32: any SolidTexture] {
        var groups: [Int: [Int32]] = [:]
        for (f, spec) in specs { groups[spec.group, default: []].append(f) }
        var out: [Int32: any SolidTexture] = [:]
        for (_, faces) in groups {
            let members = Set(faces)
            var remap: [Int32: Int32] = [:]
            var surfacePoints: [SIMD3<Double>] = [], surfaceTriangles: [SIMD3<Int32>] = []
            func index(_ v: Int32) -> Int32 {
                if let i = remap[v] { return i }
                let i = Int32(surfacePoints.count)
                remap[v] = i
                surfacePoints.append(points[Int(v)])
                return i
            }
            for (t, tri) in triangles.enumerated() where members.contains(self.faces[t]) {
                surfaceTriangles.append(SIMD3(index(tri.x), index(tri.y), index(tri.z)))
            }
            let first = faces.min()!
            guard let solid = specs[first]!.pattern.solid(over: TextureSurface(points: surfacePoints, triangles: surfaceTriangles,
                                                                                 detailScale: detailScale))
            else { continue }
            for f in faces { out[f] = solid }
        }
        return out
    }

    /// Smooths the unit vectors `directions` of the points `include` marks over the marked points
    /// within `radius` mm in space (weighted by distance, and only those facing the same way),
    /// keeping them unit length.
    ///
    /// In space rather than along the mesh's edges: a kernel blend's tessellation has vertices a
    /// few microns apart whose normals differ by a degree, on either side of a sliver triangle,
    /// and averaging along edges leaves them that far apart (each side averages its own fan).
    ///
    /// Each is the value at the point of a plane fitted through the directions over the tangent
    /// plane (a local linear fit), face by face: on each face the point is on, through the points
    /// on that face, the fits averaged. Not one plain average of every point near: where a flat
    /// face meets a fillet the surface starts to curve, and an average over both leans towards
    /// the fillet (up to 0.8° on a box's 8 mm corners, and towards wherever the mesh has more
    /// points). Cut 1 mm deep along those leaning directions, a stone's edge came out with a
    /// straight crease along every such line, a ghost outline of the fillets across the stones.
    /// On one face the surface is smooth, and a fitted plane follows its turn exactly, however
    /// unevenly the points are spaced, while it still evens out a blend's jitter.
    ///
    /// Where two faces' fits disagree along their shared edge (a kernel blend whose normals are a
    /// degree off its neighbour's), the difference is spread out over `radius` either side of the
    /// edge (see ``edgeSteps``), rather than left as a step that folds the fine triangles there.
    func smoothDirections(_ directions: inout [SIMD3<Double>], where include: [Bool], radius: Double) {
        let r = max(radius, 1e-6)
        let targets = points.indices.filter { include[$0] }
        guard !targets.isEmpty else { return }
        let source = directions, points = self.points
        let grid = PointGrid(radius: r, items: targets.map { Int32($0) }) { points[Int($0)] }
        // The grid's points and directions in its order, read one after another.
        let near = grid.members.map { points[Int($0)] }, nearDirections = grid.members.map { source[Int($0)] }
        let vertexFaces = self.vertexFaces()
        // The grid's points' first face and whether they are on others too, in its order: the
        // test whether a point is on a face (``VertexFaces/contains(_:_:)``) without hashing.
        let nearFace = grid.members.map { vertexFaces.first[Int($0)] }
        let nearSeveral = grid.members.map { vertexFaces.more[Int($0)] != nil }
        // Each target's fit per face (up to `slots` faces), face index in `fitFaces`.
        let slots = 4
        let fits = UnsafeMutableBufferPointer<SIMD3<Double>>.allocate(capacity: targets.count * slots)
        let fitFaces = UnsafeMutableBufferPointer<Int32>.allocate(capacity: targets.count * slots)
        defer { fits.deallocate(); fitFaces.deallocate() }
        fitFaces.initialize(repeating: Int32.min)
        let fitOut = SendableDirections(buffer: fits), faceOut = SendableFaces(buffer: fitFaces)
        let chunk = 1024
        let blocks = (targets.count + chunk - 1) / chunk
        DispatchQueue.concurrentPerform(iterations: blocks) { block in
            for i in (block * chunk)..<min(targets.count, (block + 1) * chunk) {
                let v = targets[i]
                let p = points[v], own = source[v]
                let around = Int(grid.cellOfItem[i]) * 27
                // Its faces (as ``VertexFaces/faces(of:)``, at most `slots`) and per face the sums
                // below, kept on the stack: this runs for every point.
                var faces = SIMD4<Int32>(repeating: Int32.min), faceCount = 0
                if let more = vertexFaces.more[v] {
                    for f in more.prefix(slots) { faces[faceCount] = f; faceCount += 1 }
                } else if vertexFaces.first[v] != Int32.min {
                    faces[0] = vertexFaces.first[v]; faceCount = 1
                }
                // Per face: weighted least squares of n ≈ a + b·x + c·y over the tangent plane (x, y
                // in units of `r`), as the normal equations' sums.
                let helper: SIMD3<Double> = abs(own.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                let e1 = simd_normalize(helper - simd_dot(helper, own) * own), e2 = simd_cross(own, e1)
                withUnsafeTemporaryAllocation(of: simd_double3x3.self, capacity: 2 * slots) { sums in
                    let m = UnsafeMutableBufferPointer(rebasing: sums[0..<slots])
                    let rhs = UnsafeMutableBufferPointer(rebasing: sums[slots..<(2 * slots)])
                    sums.initialize(repeating: simd_double3x3(0))
                    for c in grid.around[around..<(around + 27)] where c >= 0 {
                        for slot in grid.start[Int(c)]..<grid.start[Int(c) + 1] {
                            let w = grid.members[slot]
                            let d = (near[slot] - p) / r
                            let d2 = simd_length_squared(d)
                            guard d2 < 1 else { continue }
                            let n = nearDirections[slot]
                            guard simd_dot(n, own) > 0.5 else { continue }
                            let k = (1 - d2) * (1 - d2)
                            let x = SIMD3(1, simd_dot(d, e1), simd_dot(d, e2))
                            for j in 0..<faceCount {
                                let f = faces[j]
                                guard nearFace[slot] == f || (nearSeveral[slot] && vertexFaces.contains(Int(w), f)) else { continue }
                                m[j] += simd_double3x3(columns: (k * x[0] * x, k * x[1] * x, k * x[2] * x))
                                // Row q of the right-hand side, Σ k x_q n, as column q here.
                                rhs[j] += simd_double3x3(columns: (k * x[0] * n, k * x[1] * n, k * x[2] * n))
                            }
                        }
                    }
                    for j in 0..<faceCount {
                        var mj = m[j]
                        let total = mj[0][0]
                        var fitted = own
                        if total > 0 {
                            // A trace of ridge on the slopes, so points all along one line (or too few)
                            // fall back towards the plain average rather than a wild slope. Not more:
                            // on one side of a face's edge the points all lie to one side, and a
                            // shrunken slope moves the value at the point towards their average.
                            mj[1][1] += 1e-4 * total
                            mj[2][2] += 1e-4 * total
                            fitted = Self.unit(rhs[j].columns.0)
                            if abs(mj.determinant) > 1e-12 * total * total * total {
                                // The value at the point: a = Σ_q (M⁻¹)₀q · rhs_q.
                                let inverse = mj.inverse
                                let plane = Self.unit(rhs[j] * SIMD3(inverse[0][0], inverse[1][0], inverse[2][0]))
                                if simd_dot(plane, own) > 0.5 { fitted = plane }
                            }
                        }
                        fitOut.buffer[i * slots + j] = fitted == .zero ? own : fitted
                        faceOut.buffer[i * slots + j] = faces[j]
                    }
                    if faceCount == 0 {
                        fitOut.buffer[i * slots] = own
                    }
                }
            }
        }
        // Points on more than one face (by their place in `targets`), by cell, for spreading out
        // the steps between faces; and the cells of them round each cell of `grid`.
        let edges = PointGrid(radius: r, items: targets.indices.filter { fitFaces[$0 * slots + 1] != Int32.min }.map { Int32($0) }) {
            points[targets[Int($0)]]
        }
        let edgesAround = concurrentMap(grid.cellCount, chunk: 256) { edges.neighbours(of: grid.key(of: $0)) }
        func mean(_ i: Int) -> SIMD3<Double> {
            var sum = SIMD3<Double>.zero
            for j in 0..<slots where j == 0 || fitFaces[i * slots + j] != Int32.min { sum += fits[i * slots + j] }
            return Self.unit(sum)
        }
        let found = UnsafeMutableBufferPointer<SIMD3<Double>>.allocate(capacity: targets.count)
        defer { found.deallocate() }
        let out = SendableDirections(buffer: found)
        DispatchQueue.concurrentPerform(iterations: blocks) { block in
            for i in (block * chunk)..<min(targets.count, (block + 1) * chunk) {
                let v = targets[i]
                let own = fits[i * slots]
                let face = fitFaces[i * slots]
                // On an edge between faces: the faces' fits averaged.
                guard fitFaces[i * slots + 1] == Int32.min, face != Int32.min else {
                    out.buffer[i] = mean(i)
                    continue
                }
                // Inside one face: shifted by the step to the edge's average at the nearby points of
                // the face's edges, fully at the edge and fading out over `r`.
                let p = points[v]
                var step = SIMD3<Double>.zero, weight = 0.0, nearest = 1.0
                for c in edgesAround[Int(grid.cellOfItem[i])] where c >= 0 {
                    for e in edges.members[edges.start[Int(c)]..<edges.start[Int(c) + 1]] {
                        let b = Int(e)
                        let d2 = simd_distance_squared(points[targets[b]], p) / (r * r)
                        guard d2 < 1 else { continue }
                        guard let j = (0..<slots).first(where: { fitFaces[b * slots + $0] == face }) else { continue }
                        let k = (1 - d2) * (1 - d2)
                        step += k * (mean(b) - fits[b * slots + j])
                        weight += k
                        nearest = min(nearest, d2.squareRoot())
                    }
                }
                guard weight > 0 else { out.buffer[i] = own; continue }
                let fade = 1 - nearest * nearest * (3 - 2 * nearest)
                out.buffer[i] = Self.unit(own + fade * step / weight)
            }
        }
        for (i, v) in targets.enumerated() { directions[v] = found[i] == .zero ? source[v] : found[i] }
    }

    /// How far to move each point the `include` marks along its unit `direction` (the surface's
    /// normal) to even out a jump in the surface's curvature, such as where a flat face meets a
    /// fillet (tangent, but suddenly curved): the distance along it to the area-weighted average
    /// of the surface within `radius` in space (points facing within about 45° of the same way).
    ///
    /// The surface averaged so is smooth through such a jump, its curvature running from one
    /// side's to the other's over about `radius`, rather than as a step that shades as a crisp line
    /// where the fillet starts. On a flat face nothing moves (every point is in its plane); round
    /// a curve of radius r the surface sinks evenly by about radius² / (20 r) (0.04 mm on an 8 mm
    /// fillet), its shape kept.
    func fairing(along directions: [SIMD3<Double>], where include: [Bool], radius: Double) -> [Double] {
        var out = [Double](repeating: 0, count: points.count)
        let r = max(radius, 1e-6)
        // Each point's share of the surface: a third of its triangles' area.
        var area = [Double](repeating: 0, count: points.count)
        for tri in triangles {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let third = simd_length(simd_cross(b - a, c - a)) / 6
            area[Int(tri.x)] += third; area[Int(tri.y)] += third; area[Int(tri.z)] += third
        }
        let targets = points.indices.filter { include[$0] && directions[$0] != .zero }
        guard !targets.isEmpty else { return out }
        let points = self.points
        let grid = PointGrid(radius: r, items: targets.map { Int32($0) }) { points[Int($0)] }
        // The grid's points, directions and areas in its order, read one after another.
        let near = grid.members.map { points[Int($0)] }, nearDirections = grid.members.map { directions[Int($0)] }
        let nearArea = grid.members.map { area[Int($0)] }
        let found = UnsafeMutableBufferPointer<Double>.allocate(capacity: targets.count)
        defer { found.deallocate() }
        let sink = SendableHeights(buffer: found)
        let chunk = 1024
        DispatchQueue.concurrentPerform(iterations: (targets.count + chunk - 1) / chunk) { block in
            for i in (block * chunk)..<min(targets.count, (block + 1) * chunk) {
                let v = targets[i]
                let p = points[v], n = directions[v]
                let around = Int(grid.cellOfItem[i]) * 27
                var sum = 0.0, weight = 0.0
                for c in grid.around[around..<(around + 27)] where c >= 0 {
                    for slot in grid.start[Int(c)]..<grid.start[Int(c) + 1] {
                        let d = near[slot] - p
                        let d2 = simd_length_squared(d) / (r * r)
                        guard d2 < 1 else { continue }
                        // Faded out from 45° to 78° apart rather than cut off: round a tight
                        // blend a cut-off took points in or out a micron apart, and the
                        // average jumped there.
                        let t = (simd_dot(nearDirections[slot], n) - 0.2) / 0.5
                        guard t > 0 else { continue }
                        let facing = t >= 1 ? 1 : t * t * (3 - 2 * t)
                        let k = (1 - d2) * (1 - d2) * (1 - d2) * nearArea[slot] * facing
                        sum += k * simd_dot(d, n)
                        weight += k
                    }
                }
                sink.buffer[i] = weight > 0 ? sum / weight : 0
            }
        }
        for (i, v) in targets.enumerated() { out[v] = found[i] }
        return out
    }

    /// Endpoints of edges used by only one triangle (a mesh that wasn't closed to begin with).
    func openEdgeVertices() -> Set<Int> {
        var count = EdgeMap<Int32>(capacity: triangles.count * 3 / 2, filler: 0)
        for tri in triangles {
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                let slot = count.findOrInsert(Self.key(p, q)).slot
                count.set(slot: slot, count.values[slot] + 1)
            }
        }
        var out = Set<Int>()
        count.forEach { k, c in
            guard c == 1 else { return }
            out.insert(Int(Int32(bitPattern: UInt32(k >> 32))))
            out.insert(Int(Int32(bitPattern: UInt32(k & 0xFFFF_FFFF))))
        }
        return out
    }

    /// Distance from each vertex to the nearest `sources` vertex reached along mesh edges, up to
    /// `limit` (farther vertices: nil): measured in a straight line to that source's edges with
    /// other sources (the outline the sources make), not summed along the zigzag of mesh edges,
    /// which wanders by a good part of an edge from one point to the next and left anything
    /// shaped by the distance (a cut kept shallow near an edge) frayed along it.
    func distances(from sources: [Bool], upTo limit: Double) -> [Double?] {
        // Compressed adjacency.
        var degree = [Int32](repeating: 0, count: points.count + 1)
        for tri in triangles {
            degree[Int(tri.x)] += 2; degree[Int(tri.y)] += 2; degree[Int(tri.z)] += 2
        }
        var start = [Int](repeating: 0, count: points.count + 1)
        for i in 0..<points.count { start[i + 1] = start[i] + Int(degree[i]) }
        var fill = start
        var neighbours = [Int32](repeating: 0, count: start[points.count])
        for tri in triangles {
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                neighbours[fill[Int(p)]] = q; fill[Int(p)] += 1
                neighbours[fill[Int(q)]] = p; fill[Int(q)] += 1
            }
        }
        // Distance from `p` to the outline at source `s`: its edges to neighbouring sources.
        func outline(_ p: SIMD3<Double>, _ s: Int) -> Double {
            let a = points[s]
            var best = simd_distance(p, a)
            for k in start[s]..<start[s + 1] {
                let b = points[Int(neighbours[k])]
                guard sources[Int(neighbours[k])] else { continue }
                let ab = b - a
                let l2 = simd_length_squared(ab)
                guard l2 > 0 else { continue }
                let t = max(0, min(1, simd_dot(p - a, ab) / l2))
                best = min(best, simd_distance(p, a + t * ab))
            }
            return best
        }
        var dist = [Double](repeating: .infinity, count: points.count)
        var nearest = [Int32](repeating: -1, count: points.count)
        var heap = MinHeap()
        for (v, s) in sources.enumerated() where s {
            dist[v] = 0
            nearest[v] = Int32(v)
            heap.push(0, Int32(v))
        }
        while let (d, v) = heap.pop() {
            let vi = Int(v)
            guard d <= dist[vi], d < limit else { continue }
            let source = Int(nearest[vi])
            for k in start[vi]..<start[vi + 1] {
                let w = Int(neighbours[k])
                guard !sources[w] else { continue }
                // Never nearer than one edge beyond this point along the surface allows: the
                // straight line may not cut through the body to the far side of a thin wall.
                let nd = max(outline(points[w], source), d)
                if nd < dist[w] {
                    dist[w] = nd
                    nearest[w] = Int32(source)
                    heap.push(nd, Int32(w))
                }
            }
        }
        return dist.map { $0 < limit ? $0 : nil }
    }

    /// Undoes displacements that would turn a triangle over (or nearly edge-on to where it was).
    /// First the corners of such a triangle are given one shared direction, keeping how far each
    /// moves: a needle-thin triangle whose corners move along directions a few degrees apart
    /// (a kernel blend's normals can be that uneven) folds over, though it only needs to move as
    /// one. Then the points of what still folds take their neighbours' average displacement, a
    /// few times over: a patch moved all one way can't fold, and where a joint crossed a spot the
    /// surface turns too tightly to cut that deep along its normals (the tip of a kernel's corner
    /// blend), halving cut the joint off there in a torn notch. What still folds after that is
    /// halved, round after round, until no triangle folds; what still folds after that is dropped.
    /// Removes slivers lying along an edge between faces: a triangle whose third corner is all but
    /// on its longest edge (three points in a row along a curved face edge, as the kernel and the
    /// splitting leave them), where that edge is shared with another face's triangle. The other
    /// triangle is split at the third corner instead, and the sliver goes.
    ///
    /// A sliver faces no particular way: cut along a joint, the least difference in depth between
    /// its corners stood it on edge or turned it over, and undoing that (``relax(_:floor:)``)
    /// spread into torn flaps round the tip of a box's corner blend. Inside one face the
    /// splitting's flips already keep them out.
    mutating func dissolveSlivers(where include: (Int32) -> Bool) {
        var owner = EdgeMap<Int>(capacity: triangles.count * 3, filler: -1)
        for (t, tri) in triangles.enumerated() {
            for k in 0..<3 { owner.set(Self.directedKey(tri[k], tri[(k + 1) % 3]), t) }
        }
        var removed = [Bool](repeating: false, count: triangles.count)
        var added: [(SIMD3<Int32>, Int32)] = []
        for t in triangles.indices where !removed[t] && include(faces[t]) {
            let tri = triangles[t]
            var longest = 0, length2 = -1.0
            for k in 0..<3 {
                let d = simd_distance_squared(points[Int(tri[k])], points[Int(tri[(k + 1) % 3])])
                if d > length2 { length2 = d; longest = k }
            }
            let a = tri[longest], b = tri[(longest + 1) % 3], c = tri[(longest + 2) % 3]
            let pa = points[Int(a)], pb = points[Int(b)], pc = points[Int(c)]
            guard length2 > 0, simd_length(simd_cross(pb - pa, pc - pa)) < WorkMesh.sliver * length2 else { continue }
            let f = simd_dot(pc - pa, pb - pa) / length2
            guard f > 0.02, f < 0.98 else { continue }
            // The triangle across (a, b), running b → a.
            guard let u = owner[Self.directedKey(b, a)], u >= 0, u != t, !removed[u], faces[u] != faces[t] else { continue }
            let other = triangles[u]
            guard let k = (0..<3).first(where: { other[$0] == b && other[($0 + 1) % 3] == a }) else { continue }
            let d = other[(k + 2) % 3]
            // Its two halves must face as it did and not be slivers themselves.
            let pd = points[Int(d)]
            let n = simd_cross(pa - pb, pd - pb)
            let first = simd_cross(pc - pb, pd - pb), second = simd_cross(pa - pc, pd - pc)
            guard simd_dot(first, n) > 0, simd_dot(second, n) > 0,
                  simd_length(first) > WorkMesh.sliver * max(simd_distance_squared(pb, pd), simd_distance_squared(pb, pc)),
                  simd_length(second) > WorkMesh.sliver * max(simd_distance_squared(pa, pd), simd_distance_squared(pa, pc))
            else { continue }
            removed[t] = true
            removed[u] = true
            added.append((SIMD3(b, c, d), faces[u]))
            added.append((SIMD3(c, a, d), faces[u]))
            // The new triangles' edges aren't split again in this pass.
            for (new, _) in added.suffix(2) {
                for j in 0..<3 { owner.set(Self.directedKey(new[j], new[(j + 1) % 3]), -1) }
            }
        }
        guard !added.isEmpty else { return }
        var kept: [SIMD3<Int32>] = [], keptFaces: [Int32] = []
        kept.reserveCapacity(triangles.count)
        keptFaces.reserveCapacity(triangles.count)
        for t in triangles.indices where !removed[t] { kept.append(triangles[t]); keptFaces.append(faces[t]) }
        for (tri, f) in added { kept.append(tri); keptFaces.append(f) }
        triangles = kept
        faces = keptFaces
    }

    /// Key of the edge running from `a` to `b` (``key(_:_:)`` ignores the direction).
    static func directedKey(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
    }

    /// Twice a triangle's area over its longest edge squared (its height over that edge, as a
    /// share of the edge) below which ``relax(_:floor:)`` counts it a sliver.
    static let sliver = 0.01

    func relax(_ offsets: inout [SIMD3<Double>], floor: Double) {
        let cosLimit = cos(85.0 * .pi / 180)
        let rounds = 20, aligning = 4, evening = 4
        func moved(_ v: Int) -> SIMD3<Double> {
            var p = points[v] + offsets[v]
            if offsets[v] != .zero { p.z = max(p.z, floor) }
            return p
        }
        var candidates = triangles.indices.filter { t in
            let tri = triangles[t]
            return offsets[Int(tri.x)] != .zero || offsets[Int(tri.y)] != .zero || offsets[Int(tri.z)] != .zero
        }
        // Slivers (corners all but in a line, as the kernel lays them along a curved edge between
        // faces) face no particular way: the least difference in depth stands one on edge or
        // turns it over. So the middle corner of each moves with its long edge from the start
        // (where that moves it less than a tenth of the edge), all of them a few times over (they come in chains along an edge, each one's middle
        // corner the end of the next): fixed only once they folded, one at a time, they kept
        // undoing each other, and the cuts round them were halved away into a notch in the joint.
        var slivers: [(apex: Int, a: Int, b: Int, f: Double)] = []
        for t in candidates {
            let tri = triangles[t]
            let corners = [Int(tri.x), Int(tri.y), Int(tri.z)]
            var longest = 0
            for k in 1..<3 where simd_distance_squared(points[corners[(k + 1) % 3]], points[corners[(k + 2) % 3]])
                > simd_distance_squared(points[corners[(longest + 1) % 3]], points[corners[(longest + 2) % 3]]) { longest = k }
            let apex = corners[longest], ea = corners[(longest + 1) % 3], eb = corners[(longest + 2) % 3]
            let edge = points[eb] - points[ea]
            let length2 = simd_length_squared(edge)
            let area2 = simd_length(simd_cross(points[corners[1]] - points[corners[0]], points[corners[2]] - points[corners[0]]))
            guard length2 > 0, area2 < Self.sliver * length2 else { continue }
            slivers.append((apex, ea, eb, max(0, min(1, simd_dot(points[apex] - points[ea], edge) / length2))))
        }
        for _ in 0..<(slivers.isEmpty ? 0 : 8) {
            for s in slivers {
                let along = offsets[s.a] + s.f * (offsets[s.b] - offsets[s.a])
                // Only a small correction (the cut barely changing along the edge): moved further,
                // the middle corner folded the ordinary triangles round it instead.
                guard simd_distance_squared(offsets[s.apex], along) < 0.01 * simd_distance_squared(points[s.a], points[s.b]) else { continue }
                offsets[s.apex] = along
            }
        }
        // The corners of folded triangles this round: flags by point, and the points flagged.
        var isBad = [Bool](repeating: false, count: points.count)
        var bad: [Int] = []
        for round in 0..<rounds {
            for v in bad { isBad[v] = false }
            bad.removeAll(keepingCapacity: true)
            func markBad(_ v: Int) {
                if !isBad[v] { isBad[v] = true; bad.append(v) }
            }
            var folded: [Int] = []
            for t in candidates {
                let tri = triangles[t]
                let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
                let n0 = simd_cross(points[b] - points[a], points[c] - points[a])
                let pa = moved(a), pb = moved(b), pc = moved(c)
                let n1 = simd_cross(pb - pa, pc - pa)
                let l0 = simd_length(n0), l1 = simd_length(n1)
                guard l0 > 0 else { continue }
                // A sliver whose middle corner moves with its long edge (above) stays one.
                let ab2 = simd_distance_squared(points[a], points[b]), bc2 = simd_distance_squared(points[b], points[c])
                let ca2 = simd_distance_squared(points[c], points[a])
                let longest = max(ab2, bc2, ca2)
                if l0 < Self.sliver * longest {
                    let (apex, ea, eb) = ab2 == longest ? (c, a, b) : (bc2 == longest ? (a, b, c) : (b, c, a))
                    let edge = points[eb] - points[ea]
                    let f = max(0, min(1, simd_dot(points[apex] - points[ea], edge) / longest))
                    let drift = simd_length(offsets[apex] - (offsets[ea] + f * (offsets[eb] - offsets[ea])))
                    if drift < 1e-3 * longest.squareRoot() { continue }
                }
                if l1 < 1e-3 * l0 || simd_dot(n0, n1) < cosLimit * l0 * l1 {
                    markBad(a); markBad(b); markBad(c)
                    folded.append(t)
                }
            }
            if bad.isEmpty { return }
            if round < aligning + evening {
                var stubborn = Set<Int>()
                for t in folded {
                    let tri = triangles[t]
                    let corners = [Int(tri.x), Int(tri.y), Int(tri.z)]
                    let n0 = simd_cross(points[corners[1]] - points[corners[0]], points[corners[2]] - points[corners[0]])
                    // A sliver (one corner almost on the opposite edge) flips over from the
                    // smallest difference in height: that corner moves with the edge instead.
                    var longest = 0
                    for k in 1..<3 where simd_distance_squared(points[corners[(k + 1) % 3]], points[corners[(k + 2) % 3]])
                        > simd_distance_squared(points[corners[(longest + 1) % 3]], points[corners[(longest + 2) % 3]]) { longest = k }
                    let apex = corners[longest], ea = corners[(longest + 1) % 3], eb = corners[(longest + 2) % 3]
                    let edge = points[eb] - points[ea]
                    let length2 = simd_length_squared(edge)
                    if length2 > 0, simd_length(n0) / length2 < 0.1 {
                        let f = max(0, min(1, simd_dot(points[apex] - points[ea], edge) / length2))
                        offsets[apex] = offsets[ea] + f * (offsets[eb] - offsets[ea])
                        continue
                    }
                    guard round < aligning else {
                        stubborn.formUnion(corners)
                        continue
                    }
                    // Each corner's direction, signed so that all point out of the triangle.
                    var sum = SIMD3<Double>.zero
                    for v in corners {
                        let l = simd_length(offsets[v])
                        guard l > 0 else { continue }
                        sum += offsets[v] / l * (simd_dot(offsets[v], n0) >= 0 ? 1 : -1)
                    }
                    let direction = Self.unit(sum)
                    guard direction != .zero else { continue }
                    for v in corners {
                        let l = simd_length(offsets[v])
                        guard l > 0 else { continue }
                        offsets[v] = direction * (l * (simd_dot(offsets[v], n0) >= 0 ? 1 : -1))
                    }
                }
                if !stubborn.isEmpty {
                    // The folded points and a few rings round them (more each round), so the
                    // change fades out rather than folding the next ring.
                    var region = stubborn
                    var around: [Int: Set<Int>] = [:]
                    for _ in 0...(round - aligning + 1) {
                        var grown = region
                        for tri in triangles {
                            let corners = [Int(tri.x), Int(tri.y), Int(tri.z)]
                            guard corners.contains(where: { region.contains($0) }) else { continue }
                            for v in corners {
                                grown.insert(v)
                                if region.contains(v) { for w in corners where w != v { around[v, default: []].insert(w) } }
                            }
                        }
                        region = grown
                    }
                    for _ in 0..<8 {
                        let before = offsets
                        for (v, near) in around where before[v] != .zero {
                            var sum = before[v]
                            for w in near { sum += before[w] }
                            offsets[v] = sum / Double(near.count + 1)
                        }
                    }
                }
            } else {
                for v in bad { offsets[v] = round == rounds - 1 ? .zero : offsets[v] * 0.5 }
            }
            // Every triangle touching a point that moved (not only the ones checked this round:
            // moving a point can fold a neighbour that was fine before).
            candidates = triangles.indices.filter { t in
                let tri = triangles[t]
                return isBad[Int(tri.x)] || isBad[Int(tri.y)] || isBad[Int(tri.z)]
            }
        }
    }

    /// A kernel mesh with one vertex per (point, face) pair, so normals stay sharp at face edges;
    /// `edges` and `brepVertices` come from `original`.
    func mesh(keeping original: Mesh) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(points.count + points.count / 8)
        indices.reserveCapacity(triangles.count * 3)
        var first = [Int32](repeating: -1, count: points.count)
        var firstFace = [Int32](repeating: Int32.min, count: points.count)
        var extra: [UInt64: Int32] = [:]
        let floats = points.map { SIMD3<Float>($0) }
        func vertex(_ v: Int32, _ f: Int32) -> UInt32 {
            let i = Int(v)
            if first[i] < 0 {
                first[i] = Int32(positions.count)
                firstFace[i] = f
                positions.append(floats[i])
                normals.append(.zero)
                return UInt32(first[i])
            }
            if firstFace[i] == f { return UInt32(first[i]) }
            let k = UInt64(UInt32(bitPattern: v)) << 32 | UInt64(UInt32(bitPattern: f))
            if let e = extra[k] { return UInt32(e) }
            let e = Int32(positions.count)
            extra[k] = e
            positions.append(floats[i])
            normals.append(.zero)
            return UInt32(e)
        }
        for (t, tri) in triangles.enumerated() {
            let f = faces[t]
            let a = vertex(tri.x, f), b = vertex(tri.y, f), c = vertex(tri.z, f)
            indices += [a, b, c]
            let n = simd_cross(positions[Int(b)] - positions[Int(a)], positions[Int(c)] - positions[Int(a)])
            normals[Int(a)] += n; normals[Int(b)] += n; normals[Int(c)] += n
        }
        normals = normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1) }
        return Mesh(positions: positions, normals: normals, indices: indices, triangleFaces: faces,
                    edges: original.edges, brepVertices: original.brepVertices)
    }
}

/// `transform` of each index in `0..<count`, worked out across the cores in fixed blocks of
/// `chunk` (fewer for transforms that are each a lot of work); each value is the same as worked
/// out one by one (no sums run across the blocks).
func concurrentMap<T>(_ count: Int, chunk: Int = 1024, _ transform: (Int) -> T) -> [T] {
    guard count > 0 else { return [] }
    return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
        let out = SendableSlots(buffer: buffer)
        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { block in
            for i in (block * chunk)..<min(count, (block + 1) * chunk) {
                (out.buffer.baseAddress! + i).initialize(to: transform(i))
            }
        }
        initialized = count
    }
}

/// Lets `concurrentPerform` write distinct slots of one buffer.
private struct SendableSlots<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
}

/// Lets `concurrentPerform` write distinct slots of one buffer.
private struct SendableDirections: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<SIMD3<Double>>
}

private struct SendableHeights: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Double>
}

private struct SendableFaces: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Int32>
}

/// Binary min-heap of (distance, vertex).
struct MinHeap {
    private var items: [(Double, Int32)] = []

    mutating func push(_ d: Double, _ v: Int32) {
        items.append((d, v))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].0 < items[parent].0 else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int32)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
