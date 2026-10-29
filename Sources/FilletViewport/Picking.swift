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
    /// The ray met the body's section cap, not one of its faces (`face` is -1): the cap hides what
    /// is behind it and picks the body, but no face.
    public var onSectionCap = false
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
    /// The section cut picks see: what it cuts away can't be picked and hides nothing, and its caps
    /// hide what's behind them. `pick` and `boxSelect` take it from their scene.
    public var section: SectionPlane?

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

    /// Nearest face hit among visible, pickable bodies, on the part of the ray `section` keeps.
    public func raycast(_ ray: Ray, bodies: [SceneBody]) -> FaceHit? {
        guard let (tMin, tMax) = keptSpan(ray) else { return nil }
        let start = ray.point(at: tMin)
        var best: FaceHit?
        for body in bodies where body.visible && body.pickable && !body.mesh.indices.isEmpty {
            let tree = bvh(for: body)
            let limit = min(best?.distance ?? .infinity, tMax) - tMin
            guard let h = tree.intersect(origin: start.simd, direction: ray.direction.simd, maxT: limit) else { continue }
            let m = body.mesh
            let i0 = Int(m.indices[3 * h.triangle]), i1 = Int(m.indices[3 * h.triangle + 1]), i2 = Int(m.indices[3 * h.triangle + 2])
            let a = Vec3(m.positions[i0]), b = Vec3(m.positions[i1]), c = Vec3(m.positions[i2])
            let winding = (b - a).cross(c - a).normalized
            var n = winding
            if n.dot(ray.direction) > 0 { n = -n }
            // Entering the kept side through the plane and then leaving the body: the ray was
            // inside it at the plane, on its cap.
            if tMin > 0, let s = section?.unitNormal {
                let outward = m.normals.count == m.positions.count
                    ? Vec3(m.normals[i0] + m.normals[i1] + m.normals[i2]) : winding
                if outward.dot(ray.direction) > 0 {
                    best = FaceHit(body: body.id, face: -1, triangle: h.triangle, point: start,
                                   normal: s.dot(ray.direction) > 0 ? -s : s, distance: tMin, onSectionCap: true)
                    continue
                }
            }
            let face = h.triangle < m.triangleFaces.count ? Int(m.triangleFaces[h.triangle]) : 0
            best = FaceHit(body: body.id, face: face, triangle: h.triangle, point: ray.point(at: tMin + h.t), normal: n,
                           distance: tMin + h.t)
        }
        return best
    }

    /// The stretch of `ray` (distances from its origin) on the side `section` keeps; nil when none.
    private func keptSpan(_ ray: Ray) -> (Double, Double)? {
        guard let s = section, let n = s.unitNormal else { return (0, .infinity) }
        let d0 = s.distance(ray.origin), rate = ray.direction.dot(n)
        if abs(rate) < 1e-12 { return d0 > 0 ? nil : (0, .infinity) }
        let tPlane = -d0 / rate
        if rate > 0 { return tPlane > 0 ? (0, tPlane) : nil }
        return (max(tPlane, 0), .infinity)
    }

    /// Picks the most relevant target under `location`.
    ///
    /// Priority: handles, sketch points, sketch curves, regions, vertices and then edges (when within
    /// `tolerance` and not occluded), faces/bodies, then reference planes (see below).
    public func pick(scene: ViewportScene, camera: Camera, at location: CGPoint, viewSize: CGSize,
                     filter: PickFilter, tolerance: Double = PointerKind.mouse.tolerance) -> PickHit? {
        section = scene.section
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
            let face = faceHit.flatMap { f in
                filter.contains(.faces) && !f.onSectionCap && scene.canPick(face: f.face, of: f.body) ? f : nil
            }
            if face == nil, p.distance < faceHit?.distance ?? .infinity { return p.hit }
        }
        if let f = faceHit {
            if filter.contains(.faces) {
                // A cap picks the body when bodies can be picked, else it only hides what's behind.
                if f.onSectionCap {
                    return filter.contains(.bodies) ? PickHit(target: .body(f.body), point: f.point, normal: f.normal, screenDistance: 0) : nil
                }
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
                for k in 1..<poly.count {
                    // Only what the section leaves of the edge.
                    guard let (prev, cur) = keptPart(Vec3(poly[k - 1]), Vec3(poly[k])) else { continue }
                    let prevS = camera.project(prev, viewSize: viewSize).map { SIMD2(Double($0.x), Double($0.y)) }
                    let curS = camera.project(cur, viewSize: viewSize).map { SIMD2(Double($0.x), Double($0.y)) }
                    if let p0 = prevS, let p1 = curS {
                        let (d, s) = Self.segmentDistance(location, p0, p1)
                        if d < bestD { bestD = d; bestSeg = Candidate(body: body.id, edge: ei, a: prev, b: cur, s: s, d: d) }
                    }
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

    /// The part of segment `ab` the section keeps, nil when it cuts all of it.
    private func keptPart(_ a: Vec3, _ b: Vec3) -> (Vec3, Vec3)? {
        guard let s = section, s.unitNormal != nil else { return (a, b) }
        let da = s.distance(a), db = s.distance(b)
        if da <= 0 && db <= 0 { return (a, b) }
        if da > 0 && db > 0 { return nil }
        let x = a + (b - a) * (da / (da - db))
        return da > 0 ? (x, b) : (a, x)
    }

    /// Whether a world point is not hidden behind any face (with a depth tolerance of
    /// a couple of screen points), nor cut away by the section.
    func isVisible(_ p: Vec3, bodies: [SceneBody], camera: Camera, viewSize: CGSize) -> Bool {
        if let s = section, s.unitNormal != nil, s.distance(p) > 1e-6 * max(1, p.length) { return false }
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
            var d = Double.infinity
            switch h.kind {
            case .arrow:
                guard let g = Self.handleScreenGeometry(h, camera: camera, viewSize: viewSize) else { continue }
                d = Self.segmentDistance(location, g.start, g.tip).0
            case .rotation:
                // The grip's arc on screen, heads included.
                let points = Self.rotationGrip(h, camera: camera, viewSize: viewSize, reach: HandleMetrics.gripHeadLength)
                    .compactMap { camera.project($0, viewSize: viewSize) }.map { SIMD2(Double($0.x), Double($0.y)) }
                for i in points.indices.dropLast() { d = min(d, Self.segmentDistance(location, points[i], points[i + 1]).0) }
            }
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

    /// What a drag through `ray` reads off a handle: an arrow's axis parameter (see
    /// `handleAxisParameter`), or for a rotation grip the angle in degrees, about its axis, from
    /// `direction` to where the ray crosses the grip's plane (in -180…180). Nil when the ray runs
    /// (nearly) along an arrow, or (nearly) in a grip's plane, where the angle would jump.
    public static func handleParameter(_ h: Handle, ray: Ray) -> Double? {
        guard case .rotation(let axis) = h.kind else { return handleAxisParameter(h, ray: ray) }
        let along = ray.direction.dot(axis)
        guard abs(along) > 0.05 else { return nil }
        let t = (h.origin - ray.origin).dot(axis) / along
        let w = ray.point(at: t) - h.origin
        let side = axis.cross(h.direction)
        guard w.length > 1e-9 else { return nil }
        return atan2(w.dot(side), w.dot(h.direction)) * 180 / .pi
    }

    /// World points along a rotation grip's arc, at its screen-constant radius: from one end to the
    /// other, `reach` points further past each end (its heads).
    static func rotationGrip(_ h: Handle, camera: Camera, viewSize: CGSize, reach: Double = 0) -> [Vec3] {
        guard case .rotation(let axis) = h.kind else { return [] }
        let wpp = camera.worldUnitsPerPoint(at: h.origin, viewSize: viewSize)
        return rotationGripPoints(center: h.origin, axis: axis, direction: h.direction,
                                  radius: HandleMetrics.gripRadius * wpp, reach: reach / HandleMetrics.gripRadius)
    }

    /// `count` + 1 points on the arc of `radius` around `center` in the plane across `axis`,
    /// spanning `HandleMetrics.gripSpan` either side of `direction`, plus `reach` radians past each end.
    static func rotationGripPoints(center: Vec3, axis: Vec3, direction: Vec3, radius: Double, reach: Double = 0,
                                   count: Int = 12) -> [Vec3] {
        let side = axis.cross(direction)
        let half = HandleMetrics.gripSpan + reach
        return (0...count).map { i in
            let a = -half + 2 * half * Double(i) / Double(count)
            return center + (direction * cos(a) + side * sin(a)) * radius
        }
    }
}

/// Screen-space handle dimensions (points; the grip's span in radians).
public enum HandleMetrics {
    static let shaftLength = 34.0
    static let headLength = 14.0
    static let headRadius = 6.0
    /// Arrow length from its tip (the base dot) to the end of its head.
    public static var totalLength: Double { shaftLength + headLength }
    /// How far a rotation grip sits from its centre.
    public static let gripRadius = 64.0
    /// Half the angle a rotation grip's arc covers.
    static let gripSpan = 0.32
    static let gripHeadLength = 10.0
}
