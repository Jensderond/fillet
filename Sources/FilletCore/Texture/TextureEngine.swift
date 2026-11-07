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
///    faces and sharp edges between textured ones (over the `fade` parameter), and never
///    pushes below the lowest point (the bed).
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
        for t in textures {
            guard let pattern = TextureCatalog.make(t.pattern, t.values) else { continue }
            let fade = max(0, t.values.values["fade"] ?? 0)
            for f in faces(of: t, on: shape) {
                specs[Int32(f)] = FaceTexture(surface: FaceSurface(face: f, of: shape), pattern: pattern, fade: fade)
            }
        }
        guard !specs.isEmpty else { return mesh }
        return displace(mesh, faces: specs, quality: quality)
    }

    /// One face's texture: its surface, pattern and edge fade.
    struct FaceTexture: Sendable {
        var surface: FaceSurface
        var pattern: any TexturePattern
        var fade: Double
    }

    /// Dihedral angle above which an edge between two textured faces counts as sharp (the texture
    /// fades out towards it instead of tearing the corner).
    static let creaseAngle = 30.0 * .pi / 180

    /// The textured mesh for `faces` (by B-rep face index in `mesh.triangleFaces`).
    static func displace(_ mesh: Mesh, faces specs: [Int32: FaceTexture], quality: TextureQuality) -> Mesh {
        var m = WorkMesh(welding: mesh)
        guard !m.triangles.isEmpty else { return mesh }
        let textured: (Int32) -> Bool = { specs[$0] != nil }

        // Target edge length: the finest pattern's detail, coarsened to respect the triangle budget.
        var edge = specs.values.map { $0.pattern.detail }.min() ?? 1
        edge = max(edge * quality.edgeScale, 1e-3)
        let area = m.area { textured($0) }
        let budget = Double(max(quality.maxTriangles - m.triangles.count, 1000))
        // A triangle of edge e covers about 0.43 e²; splitting leaves them a little smaller on average.
        edge = max(edge, (1.6 * area / (0.433 * budget)).squareRoot())
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
            for (f, spec) in specs {
                let mapping = bands[f]
                    ?? SurfaceMapping(surface: spec.surface, cell: Self.mappingCell(spec.pattern), points: points[f] ?? [])
                guard !mapping.isTriplanar else { continue }
                coarse[f] = (mapping, spec.pattern.fitted(to: mapping.face(border: borders[f] ?? [])))
            }
        }
        let localScale = quality.edgeScale * quality.edgeScale
        m.subdivide(maxEdge: edge, where: textured, maxTriangles: quality.maxTriangles) { p, f in
            guard let (mapping, pattern) = coarse[f] else { return .infinity }
            return max(pattern.detail(at: mapping.uv(p)) * localScale, 1e-3)
        }
        // Sharp round outlines (a disc's edge) meshed along their own curves (``TextureRim``).
        let rimMappings = m.followRims(specs, borders: borders, scale: quality.edgeScale)

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
        let maxFade = specs.values.map(\.fade).max() ?? 0
        let distance = maxFade > 0 ? m.distances(from: pinned, upTo: maxFade) : nil

        // Surface mapping per face, from its points.
        var facePoints: [Int32: [SIMD3<Double>]] = [:]
        for (t, f) in m.faces.enumerated() where textured(f) {
            let tri = m.triangles[t]
            facePoints[f, default: []].append(m.points[Int(tri.x)])
        }
        var mappings: [Int32: SurfaceMapping] = [:]
        // Each face's pattern laid out for that face (see ``TexturePattern/fitted(to:)``).
        var patterns: [Int32: any TexturePattern] = [:]
        for (f, spec) in specs {
            // A face re-meshed along rims keeps the mapping its rims were laid out in.
            let mapping = rimMappings[f] ?? bands[f]
                ?? SurfaceMapping(surface: spec.surface, cell: Self.mappingCell(spec.pattern), points: facePoints[f] ?? [])
            mappings[f] = mapping
            patterns[f] = spec.pattern.fitted(to: mapping.face(border: borders[f] ?? []))
        }

        var offsets = [SIMD3<Double>](repeating: .zero, count: n)
        for v in 0..<n where !pinned[v] {
            var height = 0.0, direction = SIMD3<Double>.zero, count = 0.0, fade = 0.0
            for f in adjacency.faces(of: v) {
                guard let spec = specs[f], let mapping = mappings[f], let pattern = patterns[f] else { continue }
                // Along the surface's own normal: the triangles' differs by a degree or two from one
                // facet of the tessellation to the next, enough to fold a disc's thin rim strips.
                let own = m.surfaceNormal(Int32(v), face: f)
                let s = mapping.sample(m.points[v], normal: own != .zero ? own : normals[v], pattern)
                height += s.height
                direction += s.normal
                fade = max(fade, spec.fade)
                count += 1
            }
            guard count > 0, simd_length(direction) > 1e-9 else { continue }
            var weight = 1.0
            if fade > 0, let d = distance?[v], d < fade {
                let t = d / fade
                weight = t * t * (3 - 2 * t)
            }
            offsets[v] = simd_normalize(direction) * (height / count * weight)
        }

        // A crevice deeper than the wall is thick must not come out the other side.
        let amplitude = specs.values.map(\.pattern.amplitude).max() ?? 0
        m.limitThroughWalls(&offsets, ramp: max(2 * amplitude, 1), where: textured)
        m.relax(&offsets, floor: lowest)
        let base = m.points
        for v in 0..<n {
            var p = m.points[v] + offsets[v]
            if offsets[v] != .zero { p.z = max(p.z, lowest) }
            m.points[v] = p
        }
        m.alignCreases(base: base, where: textured)
        return m.mesh(keeping: mesh)
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
                            local: ((SIMD3<Double>, Int32) -> Double)? = nil) {
        let limit = maxEdge * maxEdge
        var wanted: [Double] = []
        func wantedLimit(_ v: Int32, _ f: Int32) -> Double {
            guard let local else { return limit }
            let i = Int(v)
            if i >= wanted.count { wanted.append(contentsOf: repeatElement(-1, count: points.count - wanted.count)) }
            if wanted[i] < 0 {
                let e = min(local(points[i], f), maxEdge)
                wanted[i] = e * e
            }
            return wanted[i]
        }
        for _ in 0..<64 {
            var mids: [UInt64: Int32] = [:]
            for t in triangles.indices where include(faces[t]) {
                let tri = triangles[t]
                var best = -1.0, bestK = 0
                for k in 0..<3 {
                    let d = simd_distance_squared(points[Int(tri[k])], points[Int(tri[(k + 1) % 3])])
                    if d > best { best = d; bestK = k }
                }
                let f = faces[t]
                guard best > (local == nil ? limit : min(wantedLimit(tri.x, f), wantedLimit(tri.y, f), wantedLimit(tri.z, f)))
                else { continue }
                let a = tri[bestK], b = tri[(bestK + 1) % 3]
                let k = Self.key(a, b)
                if mids[k] == nil {
                    mids[k] = Int32(points.count)
                    points.append(curvedMidpoint(a, b, face: f))
                    if surfaceNormals.count == points.count - 1 {
                        surfaceNormals.append(Self.unit(surfaceNormal(a, face: f) + surfaceNormal(b, face: f)))
                    }
                }
            }
            if mids.isEmpty { break }
            if triangles.count + 2 * mids.count > maxTriangles {
                if surfaceNormals.count == points.count { surfaceNormals.removeLast(mids.count) }
                points.removeLast(mids.count)
                break
            }
            var newTriangles: [SIMD3<Int32>] = []
            var newFaces: [Int32] = []
            newTriangles.reserveCapacity(triangles.count + 2 * mids.count)
            newFaces.reserveCapacity(triangles.count + 2 * mids.count)
            for t in triangles.indices {
                let v = triangles[t]
                let e0 = mids[Self.key(v[0], v[1])], e1 = mids[Self.key(v[1], v[2])], e2 = mids[Self.key(v[2], v[0])]
                let f = faces[t]
                func add(_ a: Int32, _ b: Int32, _ c: Int32) {
                    newTriangles.append(SIMD3(a, b, c))
                    newFaces.append(f)
                }
                let e = [e0, e1, e2]
                // A point splitting an edge between faces: each face's normal there.
                if !edgeNormals.isEmpty {
                    for r in 0..<3 {
                        guard let m = e[r] else { continue }
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
                    let a = v[r], b = v[(r + 1) % 3], c = v[(r + 2) % 3], m = e[r]!
                    add(a, m, c)
                    add(m, b, c)
                case 2:
                    // Rotate so the unsplit edge is (c, a).
                    let k = e0 == nil ? 0 : (e1 == nil ? 1 : 2)
                    let r = (k + 1) % 3
                    let a = v[r], b = v[(r + 1) % 3], c = v[(r + 2) % 3]
                    let mab = e[r]!, mbc = e[(r + 1) % 3]!
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
            improve(where: include)
        }
        improve(where: include, passes: 4)
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
    mutating func improve(where include: (Int32) -> Bool, passes: Int = 1) {
        let coplanar = cos(25.0 * .pi / 180)
        for _ in 0..<passes {
            var owner: [UInt64: Int32] = [:]
            owner.reserveCapacity(triangles.count * 3 / 2)
            var touched = [Bool](repeating: false, count: triangles.count)
            var flips = 0
            for t in triangles.indices where include(faces[t]) {
                let tri = triangles[t]
                for k in 0..<3 {
                    let a = tri[k], b = tri[(k + 1) % 3]
                    let key = Self.key(a, b)
                    guard let other = owner[key] else { owner[key] = Int32(t); continue }
                    let u = Int(other)
                    guard !touched[t], !touched[u], faces[u] == faces[t] else { continue }
                    let c = tri[(k + 2) % 3]
                    let o = triangles[u]
                    // The other triangle runs b → a; its third corner is d.
                    var d: Int32 = -1
                    for j in 0..<3 where o[j] == b && o[(j + 1) % 3] == a { d = o[(j + 2) % 3] }
                    guard d >= 0, d != c else { continue }
                    let pa = points[Int(a)], pb = points[Int(b)], pc = points[Int(c)], pd = points[Int(d)]
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
                    flips += 1
                    break
                }
            }
            if flips == 0 { return }
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
        var seen: [UInt64: (face: Int32, normal: SIMD3<Double>)] = [:]
        var out = Set<Int>()
        let cosLimit = cos(angle)
        for (t, tri) in triangles.enumerated() where include(faces[t]) {
            let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
            let cross = simd_cross(b - a, c - a)
            let l = simd_length(cross)
            let normal = l > 0 ? cross / l : .zero
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                guard boundary.more[Int(p)] != nil, boundary.more[Int(q)] != nil else { continue }
                let k = Self.key(p, q)
                if let other = seen[k] {
                    if other.face != faces[t], simd_dot(other.normal, normal) < cosLimit {
                        out.insert(Int(p))
                        out.insert(Int(q))
                    }
                } else {
                    seen[k] = (faces[t], normal)
                }
            }
        }
        return out
    }

    /// Endpoints of edges used by only one triangle (a mesh that wasn't closed to begin with).
    func openEdgeVertices() -> Set<Int> {
        var count: [UInt64: Int] = [:]
        count.reserveCapacity(triangles.count * 3 / 2)
        for tri in triangles {
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] { count[Self.key(p, q), default: 0] += 1 }
        }
        var out = Set<Int>()
        for (k, c) in count where c == 1 {
            out.insert(Int(Int32(bitPattern: UInt32(k >> 32))))
            out.insert(Int(Int32(bitPattern: UInt32(k & 0xFFFF_FFFF))))
        }
        return out
    }

    /// Distance along mesh edges from each vertex to the nearest `sources` vertex, up to `limit`
    /// (farther vertices: nil).
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
        var dist = [Double](repeating: .infinity, count: points.count)
        var heap = MinHeap()
        for (v, s) in sources.enumerated() where s {
            dist[v] = 0
            heap.push(0, Int32(v))
        }
        while let (d, v) = heap.pop() {
            let vi = Int(v)
            guard d <= dist[vi], d < limit else { continue }
            for k in start[vi]..<start[vi + 1] {
                let w = Int(neighbours[k])
                let nd = d + simd_distance(points[vi], points[w])
                if nd < dist[w] {
                    dist[w] = nd
                    heap.push(nd, Int32(w))
                }
            }
        }
        return dist.map { $0 < limit ? $0 : nil }
    }

    /// Shrinks displacements that would turn a triangle over (or nearly edge-on to where it was),
    /// halving them where needed, until no triangle folds; what still folds after that is dropped.
    func relax(_ offsets: inout [SIMD3<Double>], floor: Double) {
        let cosLimit = cos(85.0 * .pi / 180)
        func moved(_ v: Int) -> SIMD3<Double> {
            var p = points[v] + offsets[v]
            if offsets[v] != .zero { p.z = max(p.z, floor) }
            return p
        }
        var candidates = triangles.indices.filter { t in
            let tri = triangles[t]
            return offsets[Int(tri.x)] != .zero || offsets[Int(tri.y)] != .zero || offsets[Int(tri.z)] != .zero
        }
        for round in 0..<12 {
            var bad = Set<Int>()
            var still: [Int] = []
            for t in candidates {
                let tri = triangles[t]
                let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
                let n0 = simd_cross(points[b] - points[a], points[c] - points[a])
                let pa = moved(a), pb = moved(b), pc = moved(c)
                let n1 = simd_cross(pb - pa, pc - pa)
                let l0 = simd_length(n0), l1 = simd_length(n1)
                guard l0 > 0 else { continue }
                if l1 < 1e-3 * l0 || simd_dot(n0, n1) < cosLimit * l0 * l1 {
                    bad.insert(a); bad.insert(b); bad.insert(c)
                    still.append(t)
                }
            }
            if bad.isEmpty { return }
            for v in bad { offsets[v] = round == 11 ? .zero : offsets[v] * 0.5 }
            candidates = still + candidates.filter { t in
                let tri = triangles[t]
                return bad.contains(Int(tri.x)) || bad.contains(Int(tri.y)) || bad.contains(Int(tri.z))
            }
            candidates = Array(Set(candidates))
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
