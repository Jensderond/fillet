import CoreGraphics
import Foundation
import simd
import FilletKernel

/// Cache key for per-body derived data (GPU buffers, BVH): explicit version plus a
/// cheap O(1) fingerprint of the mesh so forgotten version bumps are still caught
/// in the common cases (different counts or moved samples).
struct MeshKey: Hashable {
    var version: Int
    var vertexCount: Int
    var indexCount: Int
    var edgeCount: Int
    var sample: Int

    init(_ body: SceneBody) {
        let m = body.mesh
        version = body.version
        vertexCount = m.positions.count
        indexCount = m.indices.count
        edgeCount = m.edges.count
        var h = Hasher()
        if !m.positions.isEmpty {
            let step = max(1, m.positions.count / 16)
            var i = 0
            while i < m.positions.count {
                let p = m.positions[i]
                h.combine(p.x.bitPattern); h.combine(p.y.bitPattern); h.combine(p.z.bitPattern)
                i += step
            }
            let last = m.positions[m.positions.count - 1]
            h.combine(last.x.bitPattern); h.combine(last.y.bitPattern); h.combine(last.z.bitPattern)
        }
        sample = h.finalize()
    }
}

/// A face hit from a ray cast.
public struct FaceHit: Hashable, Sendable {
    public var body: UUID
    public var face: Int
    public var triangle: Int
    public var point: Vec3
    /// Geometric (triangle) normal facing the ray origin.
    public var normal: Vec3
    /// Distance along the ray.
    public var distance: Double
}

/// The result of picking at a screen location.
public struct PickHit: Hashable, Sendable {
    public var target: PickTarget
    /// World position of the hit (for sketch picks: on the sketch plane).
    public var point: Vec3
    /// Surface normal for face/body hits.
    public var normal: Vec3?
    /// Sketch-plane coordinates for sketch and region hits.
    public var sketchPoint: SIMD2<Double>?
    /// Screen distance in points from the pointer to the picked element (0 for surface hits).
    public var screenDistance: Double
}

/// Pointer precision; sets the pick tolerance in points.
public enum PointerKind: Sendable {
    case touch, pencil, mouse

    /// Tolerance for edges, curves and points (points).
    public var tolerance: Double {
        switch self {
        case .touch: 10
        case .pencil: 6
        case .mouse: 5
        }
    }
}

/// CPU picking against a `ViewportScene`. Holds a per-body BVH cache keyed by mesh
/// version, built lazily on first use.
public final class ViewportPicker {
    private var bvhs: [UUID: (key: MeshKey, bvh: TriangleBVH)] = [:]

    public init() {}

    /// BVH for a body (cached).
    public func bvh(for body: SceneBody) -> TriangleBVH {
        let key = MeshKey(body)
        if let c = bvhs[body.id], c.key == key { return c.bvh }
        let b = TriangleBVH(mesh: body.mesh)
        bvhs[body.id] = (key, b)
        return b
    }

    /// Drops cache entries for bodies that are no longer in the scene.
    public func prune(keeping ids: Set<UUID>) {
        bvhs = bvhs.filter { ids.contains($0.key) }
    }

    /// Nearest face hit among visible, pickable bodies.
    public func raycast(_ ray: Ray, bodies: [SceneBody]) -> FaceHit? {
        var best: FaceHit?
        for body in bodies where body.visible && body.pickable && !body.mesh.indices.isEmpty {
            let tree = bvh(for: body)
            guard let h = tree.intersect(origin: ray.origin.simd, direction: ray.direction.simd,
                                         maxT: best?.distance ?? .infinity) else { continue }
            let m = body.mesh
            let i0 = Int(m.indices[3 * h.triangle]), i1 = Int(m.indices[3 * h.triangle + 1]), i2 = Int(m.indices[3 * h.triangle + 2])
            let a = Vec3(m.positions[i0]), b = Vec3(m.positions[i1]), c = Vec3(m.positions[i2])
            var n = (b - a).cross(c - a).normalized
            if n.dot(ray.direction) > 0 { n = -n }
            let face = h.triangle < m.triangleFaces.count ? Int(m.triangleFaces[h.triangle]) : 0
            best = FaceHit(body: body.id, face: face, triangle: h.triangle, point: ray.point(at: h.t), normal: n, distance: h.t)
        }
        return best
    }

    /// Picks the most relevant target under `location`.
    ///
    /// Priority: handles, sketch points, sketch curves, regions, vertices and then edges (when within
    /// `tolerance` and not occluded), faces/bodies, then reference planes (see below).
    public func pick(scene: ViewportScene, camera: Camera, at location: CGPoint, viewSize: CGSize,
                     filter: PickFilter, tolerance: Double = PointerKind.mouse.tolerance) -> PickHit? {
        let ray = camera.ray(at: location, viewSize: viewSize)
        let loc = SIMD2(Double(location.x), Double(location.y))

        if filter.contains(.handles), let h = pickHandle(scene.handles, camera: camera, location: loc, viewSize: viewSize,
                                                          tolerance: max(tolerance, 12)) {
            return h
        }
        if let sketch = scene.sketch, !filter.intersection([.sketchPoints, .sketchCurves, .regions]).isEmpty,
           let hit = pickSketch(sketch, ray: ray, camera: camera, viewSize: viewSize, filter: filter, tolerance: tolerance) {
            return hit
        }
        let planeHit = filter.contains(.referencePlanes) ? pickReferencePlane(scene.referencePlanes, ray: ray) : nil
        guard !filter.intersection([.faces, .edges, .bodies]).isEmpty else { return planeHit?.hit }
        let faceHit = raycast(ray, bodies: scene.bodies)
        if filter.contains(.vertices),
           let v = pickVertex(scene.bodies, camera: camera, location: loc, viewSize: viewSize, tolerance: tolerance * 1.4) {
            return v
        }
        if filter.contains(.edges),
           let e = pickEdge(scene.bodies, camera: camera, location: loc, viewSize: viewSize, tolerance: tolerance) {
            return e
        }
        // Reference planes are see-through: a pickable face seen through one is what's under the
        // pointer, so the plane only takes the pick where there is no such face, or in front of
        // a face that can't be picked. A face that can't be picked still hides what's behind it.
        if let p = planeHit {
            let face = faceHit.flatMap { f in filter.contains(.faces) && scene.canPick(face: f.face, of: f.body) ? f : nil }
            if face == nil, p.distance < faceHit?.distance ?? .infinity { return p.hit }
        }
        if let f = faceHit {
            if filter.contains(.faces) {
                guard scene.canPick(face: f.face, of: f.body) else { return nil }
                return PickHit(target: .face(body: f.body, index: f.face), point: f.point, normal: f.normal, screenDistance: 0)
            }
            if filter.contains(.bodies) {
                return PickHit(target: .body(f.body), point: f.point, normal: f.normal, screenDistance: 0)
            }
        }
        return nil
    }

    // MARK: Vertices

    /// Nearest visible B-rep vertex within `tolerance` points of `location`. A corner is where
    /// edges end, so it gets a slightly larger target than the edges (the caller scales it).
    func pickVertex(_ bodies: [SceneBody], camera: Camera, location: SIMD2<Double>, viewSize: CGSize, tolerance: Double) -> PickHit? {
        var candidates: [(body: UUID, index: Int, point: Vec3, d: Double)] = []
        for body in bodies where body.visible && body.pickable {
            for (i, v) in body.mesh.brepVertices.enumerated() {
                let p = Vec3(v)
                guard let s = camera.project(p, viewSize: viewSize) else { continue }
                let d = simd_distance(SIMD2(Double(s.x), Double(s.y)), location)
                if d <= tolerance { candidates.append((body.id, i, p, d)) }
            }
        }
        candidates.sort { $0.d < $1.d }
        for c in candidates.prefix(8) where isVisible(c.point, bodies: bodies, camera: camera, viewSize: viewSize) {
            return PickHit(target: .vertex(body: c.body, index: c.index), point: c.point, normal: nil, screenDistance: c.d)
        }
        return nil
    }

    // MARK: Edges

    /// Nearest visible edge within `tolerance` points of `location`.
    func pickEdge(_ bodies: [SceneBody], camera: Camera, location: SIMD2<Double>, viewSize: CGSize, tolerance: Double) -> PickHit? {
        struct Candidate { var body: UUID; var edge: Int; var a: Vec3; var b: Vec3; var s: Double; var d: Double }
        var candidates: [Candidate] = []
        for body in bodies where body.visible && body.pickable && body.showsEdges {
            for (ei, poly) in body.mesh.edges.enumerated() where poly.count >= 2 {
                var bestD = Double.infinity
                var bestSeg: Candidate?
                var prev = Vec3(poly[0])
                var prevS = camera.project(prev, viewSize: viewSize).map { SIMD2(Double($0.x), Double($0.y)) }
                for k in 1..<poly.count {
                    let cur = Vec3(poly[k])
                    let curS = camera.project(cur, viewSize: viewSize).map { SIMD2(Double($0.x), Double($0.y)) }
                    if let p0 = prevS, let p1 = curS {
                        let (d, s) = Self.segmentDistance(location, p0, p1)
                        if d < bestD { bestD = d; bestSeg = Candidate(body: body.id, edge: ei, a: prev, b: cur, s: s, d: d) }
                    }
                    prev = cur; prevS = curS
                }
                if let c = bestSeg, c.d <= tolerance { candidates.append(c) }
            }
        }
        candidates.sort { $0.d < $1.d }
        for c in candidates.prefix(8) {
            // 3D point on the segment (screen parameter is close enough for perspective at pick scale).
            var p = c.a + (c.b - c.a) * c.s
            let pickRay = camera.ray(at: CGPoint(x: location.x, y: location.y), viewSize: viewSize)
            if let (_, s) = pickRay.closestParameters(toLine: c.a, direction: c.b - c.a) {
                let len = (c.b - c.a).length
                if len > 0 { p = c.a + (c.b - c.a).normalized * min(max(s, 0), len) }
            }
            if isVisible(p, bodies: bodies, camera: camera, viewSize: viewSize) {
                return PickHit(target: .edge(body: c.body, index: c.edge), point: p, normal: nil, screenDistance: c.d)
            }
        }
        return nil
    }

    /// Whether a world point is not hidden behind any face (with a depth tolerance of
    /// a couple of screen points).
    func isVisible(_ p: Vec3, bodies: [SceneBody], camera: Camera, viewSize: CGSize) -> Bool {
        guard let sp = camera.project(p, viewSize: viewSize) else { return false }
        let r = camera.ray(at: sp, viewSize: viewSize)
        let tPoint = (p - r.origin).dot(r.direction)
        let eps = camera.worldUnitsPerPoint(at: p, viewSize: viewSize) * 2 + 1e-4
        guard let hit = raycast(r, bodies: bodies) else { return true }
        return hit.distance >= tPoint - eps
    }

    /// Distance from `p` to segment `ab` and the segment parameter of the closest point.
    static func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (Double, Double) {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        let s = l2 > 0 ? min(max(simd_dot(p - a, ab) / l2, 0), 1) : 0
        return (simd_distance(p, a + ab * s), s)
    }

    // MARK: Sketch

    func pickSketch(_ sketch: SketchOverlay, ray: Ray, camera: Camera, viewSize: CGSize, filter: PickFilter,
                    tolerance: Double) -> PickHit? {
        guard let world = ray.intersect(sketch.plane) else { return nil }
        let uv = sketch.plane.project(world)
        let tol = tolerance * camera.worldUnitsPerPoint(at: world, viewSize: viewSize)

        if filter.contains(.sketchPoints) {
            var best: (SketchPoint, Double)?
            for p in sketch.points {
                let d = simd_distance(p.position, uv)
                if d <= tol * 1.2, d < (best?.1 ?? .infinity) { best = (p, d) }
            }
            if let (p, d) = best {
                return PickHit(target: .sketchPoint(shape: p.shapeID, index: p.index), point: sketch.plane.point(p.position),
                               normal: sketch.plane.normal, sketchPoint: p.position, screenDistance: d / max(tol / tolerance, 1e-12))
            }
        }
        if filter.contains(.sketchCurves) {
            var best: (SketchCurve, Double)?
            for c in sketch.curves where c.points.count >= 2 {
                let n = c.closed ? c.points.count : c.points.count - 1
                for i in 0..<n {
                    let (d, _) = Self.segmentDistance(uv, c.points[i], c.points[(i + 1) % c.points.count])
                    if d <= tol, d < (best?.1 ?? .infinity) { best = (c, d) }
                }
            }
            if let (c, d) = best {
                return PickHit(target: .sketchShape(c.shapeID), point: world, normal: sketch.plane.normal, sketchPoint: uv,
                               screenDistance: d / max(tol / tolerance, 1e-12))
            }
        }
        if filter.contains(.regions) {
            for r in sketch.regions {
                var i = 0
                while i + 2 < r.triangles.count {
                    if Self.pointInTriangle(uv, r.triangles[i], r.triangles[i + 1], r.triangles[i + 2]) {
                        return PickHit(target: .region(r.index), point: world, normal: sketch.plane.normal, sketchPoint: uv, screenDistance: 0)
                    }
                    i += 3
                }
            }
        }
        return nil
    }

    static func pointInTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        func cross(_ o: SIMD2<Double>, _ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        let d1 = cross(p, a, b), d2 = cross(p, b, c), d3 = cross(p, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0
        let pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }

    // MARK: Reference planes

    /// The nearest reference plane patch the ray passes through, with the distance along the ray.
    func pickReferencePlane(_ planes: [ReferencePlane], ray: Ray) -> (hit: PickHit, distance: Double)? {
        var best: (hit: PickHit, distance: Double)?
        for r in planes {
            guard let p = ray.intersect(r.plane) else { continue }
            let uv = r.plane.project(p)
            guard r.u.contains(uv.x), r.v.contains(uv.y) else { continue }
            let t = (p - ray.origin).dot(ray.direction)
            guard t < (best?.distance ?? .infinity) else { continue }
            var n = r.plane.normal
            if n.dot(ray.direction) > 0 { n = -n }
            best = (PickHit(target: .referencePlane(r.id), point: p, normal: n, sketchPoint: uv, screenDistance: 0), t)
        }
        return best
    }

    // MARK: Handles

    /// On-screen arrow geometry of a handle: shaft start, shaft end/head base, head tip (points).
    static func handleScreenGeometry(_ h: Handle, camera: Camera, viewSize: CGSize) -> (start: SIMD2<Double>, tip: SIMD2<Double>)? {
        let wpp = camera.worldUnitsPerPoint(at: h.tip, viewSize: viewSize)
        let end = h.tip + h.direction * (HandleMetrics.totalLength * wpp)
        guard let a = camera.project(h.tip, viewSize: viewSize), let b = camera.project(end, viewSize: viewSize) else { return nil }
        return (SIMD2(Double(a.x), Double(a.y)), SIMD2(Double(b.x), Double(b.y)))
    }

    func pickHandle(_ handles: [Handle], camera: Camera, location: SIMD2<Double>, viewSize: CGSize, tolerance: Double) -> PickHit? {
        var best: (Handle, Double)?
        for h in handles {
            guard let g = Self.handleScreenGeometry(h, camera: camera, viewSize: viewSize) else { continue }
            let (d, _) = Self.segmentDistance(location, g.start, g.tip)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        guard let (h, d) = best else { return nil }
        return PickHit(target: .handle(h.id), point: h.tip, normal: nil, screenDistance: d)
    }

    /// Handle value for a ray: the axis parameter of the point on the handle axis
    /// closest to the ray. Nil when the axis is (nearly) parallel to the ray.
    public static func handleAxisParameter(_ h: Handle, ray: Ray) -> Double? {
        guard abs(ray.direction.dot(h.direction)) < 0.995 else { return nil }
        return ray.closestParameters(toLine: h.origin, direction: h.direction)?.s
    }
}

/// Screen-space arrow dimensions (points).
enum HandleMetrics {
    static let shaftLength = 34.0
    static let headLength = 14.0
    static let headRadius = 6.0
    static var totalLength: Double { shaftLength + headLength }
}
