import Foundation
import simd
import FilletKernel

/// Procedurally built meshes shaped like kernel tessellations (per-face triangles,
/// per-edge polylines). Used by tests, snapshots and SwiftUI previews.
public enum DemoMeshes {
    /// Axis-aligned box. Faces: 0 bottom (-Z), 1 top (+Z), 2 front (-Y), 3 back (+Y),
    /// 4 left (-X), 5 right (+X). Edges: 0–3 bottom loop, 4–7 top loop, 8–11 verticals.
    public static func box(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Mesh {
        var b = MeshBuilder()
        let c = corners(lo, hi)
        // Corner index: bit0 = x, bit1 = y, bit2 = z.
        let faces: [([Int], SIMD3<Float>)] = [
            ([0, 2, 3, 1], [0, 0, -1]), ([4, 5, 7, 6], [0, 0, 1]),
            ([0, 1, 5, 4], [0, -1, 0]), ([2, 6, 7, 3], [0, 1, 0]),
            ([0, 4, 6, 2], [-1, 0, 0]), ([1, 3, 7, 5], [1, 0, 0]),
        ]
        for (q, n) in faces {
            let f = b.beginFace()
            b.addQuad(c[q[0]], c[q[1]], c[q[2]], c[q[3]], normal: n, face: f)
        }
        let loops = [[0, 1, 3, 2], [4, 5, 7, 6]]
        for l in loops { for i in 0..<4 { b.addEdge([c[l[i]], c[l[(i + 1) % 4]]]) } }
        for i in [0, 1, 3, 2] { b.addEdge([c[i], c[i + 4]]) }
        return b.mesh
    }

    /// Cube of edge length `size` centred at `center`.
    public static func cube(size: Float = 20, center: SIMD3<Float> = .zero) -> Mesh {
        box(min: center - size / 2, max: center + size / 2)
    }

    /// Z-aligned cylinder standing on `base`. Faces: 0 side, 1 bottom, 2 top.
    /// Edges: 0 bottom circle, 1 top circle.
    public static func cylinder(base: SIMD3<Float> = .zero, radius: Float = 10, height: Float = 20, segments: Int = 72) -> Mesh {
        var b = MeshBuilder()
        let ring = (0...segments).map { i -> SIMD2<Float> in
            let a = Float(i) / Float(segments) * 2 * .pi
            return SIMD2(cos(a), sin(a))
        }
        let side = b.beginFace()
        for i in 0..<segments {
            let d0 = ring[i], d1 = ring[i + 1]
            let n0 = SIMD3(d0.x, d0.y, 0), n1 = SIMD3(d1.x, d1.y, 0)
            let p00 = base + n0 * radius, p10 = base + n1 * radius
            let p01 = p00 + SIMD3(0, 0, height), p11 = p10 + SIMD3(0, 0, height)
            let v = [b.vertex(p00, n0), b.vertex(p10, n1), b.vertex(p11, n1), b.vertex(p01, n0)]
            b.triangle(v[0], v[1], v[2], face: side)
            b.triangle(v[0], v[2], v[3], face: side)
        }
        for (z, n) in [(Float(0), SIMD3<Float>(0, 0, -1)), (height, SIMD3<Float>(0, 0, 1))] {
            let f = b.beginFace()
            let c = b.vertex(base + SIMD3(0, 0, z), n)
            let rim = ring.map { b.vertex(base + SIMD3($0.x * radius, $0.y * radius, z), n) }
            for i in 0..<segments { b.triangle(c, rim[i], rim[i + 1], face: f) }
        }
        for z in [Float(0), height] {
            b.addEdge(ring.map { base + SIMD3($0.x * radius, $0.y * radius, z) })
        }
        return b.mesh
    }

    /// UV sphere: one face, no edges.
    public static func sphere(center: SIMD3<Float> = .zero, radius: Float = 10, segments: Int = 48) -> Mesh {
        var b = MeshBuilder()
        let f = b.beginFace()
        let rings = segments / 2
        var grid: [[UInt32]] = []
        for j in 0...rings {
            let phi = Float(j) / Float(rings) * .pi
            var row: [UInt32] = []
            for i in 0...segments {
                let th = Float(i) / Float(segments) * 2 * .pi
                let n = SIMD3(sin(phi) * cos(th), sin(phi) * sin(th), cos(phi))
                row.append(b.vertex(center + n * radius, n))
            }
            grid.append(row)
        }
        for j in 0..<rings {
            for i in 0..<segments {
                let a = grid[j][i], c = grid[j][i + 1], d = grid[j + 1][i + 1], e = grid[j + 1][i]
                if j > 0 { b.triangle(a, c, d, face: f) }
                if j < rings - 1 { b.triangle(a, d, e, face: f) }
            }
        }
        return b.mesh
    }

    /// Box with all edges rounded by `radius` (6 flat faces, 12 fillet faces,
    /// 8 corner patches; tangent edges between them).
    public static func roundedBox(min lo: SIMD3<Float>, max hi: SIMD3<Float>, radius r0: Float, segments n: Int = 8) -> Mesh {
        let r = Swift.min(r0, Swift.min(hi.x - lo.x, Swift.min(hi.y - lo.y, hi.z - lo.z)) * 0.49)
        let ilo = lo + r, ihi = hi - r
        var b = MeshBuilder()
        func e(_ axis: Int) -> SIMD3<Float> { var v = SIMD3<Float>(0, 0, 0); v[axis] = 1; return v }
        func pick(_ s: Float, _ axis: Int) -> Float { s > 0 ? ihi[axis] : ilo[axis] }

        // Flat faces.
        for axis in 0..<3 {
            for s: Float in [-1, 1] {
                let u = (axis + 1) % 3, v = (axis + 2) % 3
                let nrm = e(axis) * s
                var p = SIMD3<Float>(0, 0, 0)
                p[axis] = s > 0 ? hi[axis] : lo[axis]
                func at(_ a: Float, _ c: Float) -> SIMD3<Float> { var q = p; q[u] = a; q[v] = c; return q }
                let f = b.beginFace()
                b.addQuad(at(ilo[u], ilo[v]), at(ihi[u], ilo[v]), at(ihi[u], ihi[v]), at(ilo[u], ihi[v]), normal: nrm, face: f)
            }
        }
        // Fillets along each axis; arcs use the normalized-linear parametrisation shared with corners.
        func arcDir(_ k: Int, _ eb: SIMD3<Float>, _ ec: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize(eb * Float(n - k) + ec * Float(k))
        }
        for axis in 0..<3 {
            let bAx = (axis + 1) % 3, cAx = (axis + 2) % 3
            for s1: Float in [-1, 1] {
                for s2: Float in [-1, 1] {
                    let eb = e(bAx) * s1, ec = e(cAx) * s2
                    var line = SIMD3<Float>(0, 0, 0)
                    line[bAx] = pick(s1, bAx); line[cAx] = pick(s2, cAx)
                    let f = b.beginFace()
                    var rows: [[UInt32]] = []
                    for end in [ilo[axis], ihi[axis]] {
                        var base = line; base[axis] = end
                        rows.append((0...n).map { k in let d = arcDir(k, eb, ec); return b.vertex(base + d * r, d) })
                    }
                    for k in 0..<n {
                        b.triangle(rows[0][k], rows[1][k], rows[1][k + 1], face: f)
                        b.triangle(rows[0][k], rows[1][k + 1], rows[0][k + 1], face: f)
                    }
                    for k in [0, n] {
                        let d = arcDir(k, eb, ec)
                        var a = line, c = line; a[axis] = ilo[axis]; c[axis] = ihi[axis]
                        b.addEdge([a + d * r, c + d * r])
                    }
                    for end in [ilo[axis], ihi[axis]] {
                        var base = line; base[axis] = end
                        b.addEdge((0...n).map { base + arcDir($0, eb, ec) * r })
                    }
                }
            }
        }
        // Corner patches.
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    let c = SIMD3(pick(sx, 0), pick(sy, 1), pick(sz, 2))
                    let f = b.beginFace()
                    var idx = [[UInt32]]()
                    for i in 0...n {
                        idx.append((0...(n - i)).map { j in
                            let l = n - i - j
                            let d = simd_normalize(SIMD3(Float(i) * sx, Float(j) * sy, Float(l) * sz))
                            return b.vertex(c + d * r, d)
                        })
                    }
                    for i in 0..<n {
                        for j in 0..<(n - i) {
                            b.triangle(idx[i][j], idx[i + 1][j], idx[i][j + 1], face: f)
                            if j + 1 < n - i { b.triangle(idx[i + 1][j], idx[i + 1][j + 1], idx[i][j + 1], face: f) }
                        }
                    }
                }
            }
        }
        return b.mesh
    }

    /// Rectangular plate `[lo, hi]` with a vertical through-hole. Faces: 0 bottom, 1 top,
    /// 2 front (-Y), 3 right (+X), 4 back (+Y), 5 left (-X), 6 hole wall. Edges: 0–3 bottom
    /// loop, 4–7 top loop, 8–11 verticals, 12 hole bottom, 13 hole top.
    public static func plateWithHole(min lo: SIMD3<Float>, max hi: SIMD3<Float>, holeCenter: SIMD2<Float>,
                                     holeRadius: Float, segments: Int = 64) -> Mesh {
        var b = MeshBuilder()
        let c = holeCenter
        let rect = [SIMD2(lo.x, lo.y), SIMD2(hi.x, lo.y), SIMD2(hi.x, hi.y), SIMD2(lo.x, hi.y)]
        var angles = (0..<segments).map { Float($0) / Float(segments) * 2 * .pi }
        for p in rect {
            var a = atan2(p.y - c.y, p.x - c.x)
            if a < 0 { a += 2 * .pi }
            angles.append(a)
        }
        angles.sort()
        func rectPoint(_ a: Float) -> SIMD2<Float> {
            let d = SIMD2(cos(a), sin(a))
            var t = Float.greatestFiniteMagnitude
            if d.x > 1e-6 { t = Swift.min(t, (hi.x - c.x) / d.x) }
            if d.x < -1e-6 { t = Swift.min(t, (lo.x - c.x) / d.x) }
            if d.y > 1e-6 { t = Swift.min(t, (hi.y - c.y) / d.y) }
            if d.y < -1e-6 { t = Swift.min(t, (lo.y - c.y) / d.y) }
            return c + d * t
        }
        for (z, nz) in [(lo.z, Float(-1)), (hi.z, Float(1))] {
            let f = b.beginFace()
            let n = SIMD3<Float>(0, 0, nz)
            for i in 0..<angles.count {
                let a0 = angles[i], a1 = angles[(i + 1) % angles.count]
                let h0 = c + SIMD2(cos(a0), sin(a0)) * holeRadius, h1 = c + SIMD2(cos(a1), sin(a1)) * holeRadius
                let r0 = rectPoint(a0), r1 = rectPoint(a1)
                let v = [b.vertex(SIMD3(h0, z), n), b.vertex(SIMD3(r0, z), n), b.vertex(SIMD3(r1, z), n), b.vertex(SIMD3(h1, z), n)]
                b.triangle(v[0], v[1], v[2], face: f)
                b.triangle(v[0], v[2], v[3], face: f)
            }
        }
        let sideNormals: [SIMD3<Float>] = [[0, -1, 0], [1, 0, 0], [0, 1, 0], [-1, 0, 0]]
        for i in 0..<4 {
            let p0 = rect[i], p1 = rect[(i + 1) % 4]
            let f = b.beginFace()
            b.addQuad(SIMD3(p0, lo.z), SIMD3(p1, lo.z), SIMD3(p1, hi.z), SIMD3(p0, hi.z), normal: sideNormals[i], face: f)
        }
        let hole = b.beginFace()
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi, a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let d0 = SIMD2(cos(a0), sin(a0)), d1 = SIMD2(cos(a1), sin(a1))
            let n0 = SIMD3(-d0, 0), n1 = SIMD3(-d1, 0)
            let v = [b.vertex(SIMD3(c + d0 * holeRadius, lo.z), n0), b.vertex(SIMD3(c + d1 * holeRadius, lo.z), n1),
                     b.vertex(SIMD3(c + d1 * holeRadius, hi.z), n1), b.vertex(SIMD3(c + d0 * holeRadius, hi.z), n0)]
            b.triangle(v[0], v[1], v[2], face: hole)
            b.triangle(v[0], v[2], v[3], face: hole)
        }
        for z in [lo.z, hi.z] { for i in 0..<4 { b.addEdge([SIMD3(rect[i], z), SIMD3(rect[(i + 1) % 4], z)]) } }
        for p in rect { b.addEdge([SIMD3(p, lo.z), SIMD3(p, hi.z)]) }
        for z in [lo.z, hi.z] {
            b.addEdge((0...segments).map { i in
                let a = Float(i) / Float(segments) * 2 * .pi
                return SIMD3(c + SIMD2(cos(a), sin(a)) * holeRadius, z)
            })
        }
        return b.mesh
    }

    /// Prism: a simple polygon in XY extruded from `z0` by `height`. Faces: 0 bottom,
    /// 1 top, then one side face per profile segment. Edges: bottom loop, top loop, verticals.
    public static func extrudedProfile(_ profile: [SIMD2<Float>], z0: Float = 0, height: Float) -> Mesh {
        var poly = profile
        if signedArea(poly) < 0 { poly.reverse() }
        let tris = earClip(poly)
        var b = MeshBuilder()
        for (z, nz) in [(z0, Float(-1)), (z0 + height, Float(1))] {
            let f = b.beginFace()
            let n = SIMD3<Float>(0, 0, nz)
            let v = poly.map { b.vertex(SIMD3($0, z), n) }
            for t in stride(from: 0, to: tris.count, by: 3) { b.triangle(v[tris[t]], v[tris[t + 1]], v[tris[t + 2]], face: f) }
        }
        let m = poly.count
        for i in 0..<m {
            let p0 = poly[i], p1 = poly[(i + 1) % m]
            let d = simd_normalize(p1 - p0)
            let f = b.beginFace()
            b.addQuad(SIMD3(p0, z0), SIMD3(p1, z0), SIMD3(p1, z0 + height), SIMD3(p0, z0 + height),
                      normal: SIMD3(d.y, -d.x, 0), face: f)
        }
        for z in [z0, z0 + height] { for i in 0..<m { b.addEdge([SIMD3(poly[i], z), SIMD3(poly[(i + 1) % m], z)]) } }
        for p in poly { b.addEdge([SIMD3(p, z0), SIMD3(p, z0 + height)]) }
        return b.mesh
    }

    /// Arrow-head cone along +Z: base `radius` at z = 0, apex at z = 1. One face.
    static func cone(radius r: Float = 1, segments: Int = 32) -> Mesh {
        var b = MeshBuilder()
        let f = b.beginFace()
        let len = (1 + r * r).squareRoot()
        let (nr, nz) = (1 / len, r / len)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi, a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let am = (a0 + a1) / 2
            let n0 = SIMD3(cos(a0) * nr, sin(a0) * nr, nz)
            let n1 = SIMD3(cos(a1) * nr, sin(a1) * nr, nz)
            let nm = SIMD3(cos(am) * nr, sin(am) * nr, nz)
            b.triangle(b.vertex(SIMD3(cos(a0) * r, sin(a0) * r, 0), n0), b.vertex(SIMD3(cos(a1) * r, sin(a1) * r, 0), n1),
                       b.vertex(SIMD3(0, 0, 1), nm), face: f)
            let dn = SIMD3<Float>(0, 0, -1)
            b.triangle(b.vertex(.zero, dn), b.vertex(SIMD3(cos(a1) * r, sin(a1) * r, 0), dn),
                       b.vertex(SIMD3(cos(a0) * r, sin(a0) * r, 0), dn), face: f)
        }
        return b.mesh
    }

    /// Applies a rigid transform to positions, normals and edges.
    public static func transformed(_ mesh: Mesh, by t: Transform) -> Mesh {
        var m = mesh
        m.positions = mesh.positions.map { t.apply(Vec3($0)).float }
        m.normals = mesh.normals.map { t.applyDirection(Vec3($0)).normalized.float }
        m.edges = mesh.edges.map { $0.map { t.apply(Vec3($0)).float } }
        return m
    }

    /// Concatenates meshes into one (face and edge indices are offset in order).
    public static func merged(_ meshes: [Mesh]) -> Mesh {
        var out = Mesh.empty
        var faceOffset: Int32 = 0
        for m in meshes {
            let base = UInt32(out.positions.count)
            out.positions += m.positions
            out.normals += m.normals
            out.indices += m.indices.map { $0 + base }
            out.triangleFaces += m.triangleFaces.map { $0 + faceOffset }
            out.edges += m.edges
            faceOffset += (m.triangleFaces.max() ?? -1) + 1
        }
        return out
    }

    // MARK: Showcase

    /// An L-shaped bracket profile (mm), useful as a typical printable part.
    public static func lBracket(origin: SIMD2<Float> = .zero, width: Float = 40, height: Float = 30,
                                thickness: Float = 6, depth: Float = 24) -> Mesh {
        let o = origin
        let profile: [SIMD2<Float>] = [o, o + [width, 0], o + [width, thickness], o + [thickness, thickness],
                                       o + [thickness, height], o + [0, height]]
        // Profile lies in XZ; extrude along +Y.
        let m = extrudedProfile(profile, z0: 0, height: depth)
        let toXZ = Transform(matrix: [1, 0, 0, 0, 0, 0, -1, Double(depth), 0, 1, 0, 0])
        return transformed(m, by: toXZ)
    }

    /// A small multi-body scene: rounded block, plate with a hole, cylinder and an
    /// overhanging T-shape, arranged on a 180 mm bed.
    public static func showcaseScene() -> ViewportScene {
        let ids = (0..<4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
        let rounded = roundedBox(min: [-55, -20, 0], max: [-15, 20, 24], radius: 5)
        let plate = plateWithHole(min: [-5, -25, 0], max: [45, 15, 6], holeCenter: [20, -5], holeRadius: 8)
        let cyl = cylinder(base: [25, 40, 0], radius: 10, height: 32)
        let t = tShape(center: [-35, 45], width: 36, stem: 10, barThickness: 6, height: 26, depth: 14)
        return ViewportScene(
            bodies: [
                SceneBody(id: ids[0], mesh: rounded),
                SceneBody(id: ids[1], mesh: plate),
                SceneBody(id: ids[2], mesh: cyl, color: ViewportColor(hex: 0x6FA8DC)),
                SceneBody(id: ids[3], mesh: t, color: ViewportColor(hex: 0xE8B04A)),
            ],
            plate: BuildPlate(name: "Bambu Lab A1 mini", size: [180, 180, 180]))
    }

    /// Upright "T" (overhanging bar on a stem), profile in XZ extruded along Y.
    public static func tShape(center: SIMD2<Float>, width: Float, stem: Float, barThickness: Float, height: Float, depth: Float) -> Mesh {
        let hw = width / 2, hs = stem / 2
        let profile: [SIMD2<Float>] = [[-hs, 0], [hs, 0], [hs, height - barThickness], [hw, height - barThickness],
                                       [hw, height], [-hw, height], [-hw, height - barThickness], [-hs, height - barThickness]]
        let m = extrudedProfile(profile, z0: 0, height: depth)
        // XY profile → XZ, extrusion → +Y, centred on `center`.
        let t = Transform(matrix: [1, 0, 0, Double(center.x), 0, 0, -1, Double(center.y + depth / 2), 0, 1, 0, 0])
        return transformed(m, by: t)
    }

    // MARK: Helpers

    static func corners(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<8).map { i in SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
    }

    static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        var a: Float = 0
        for i in 0..<p.count { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return a / 2
    }

    /// Ear-clipping triangulation of a counter-clockwise simple polygon.
    static func earClip(_ p: [SIMD2<Float>]) -> [Int] {
        var idx = Array(p.indices)
        var out: [Int] = []
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for i in 0..<idx.count {
                let ia = idx[(i + idx.count - 1) % idx.count], ib = idx[i], ic = idx[(i + 1) % idx.count]
                let a = p[ia], b = p[ib], c = p[ic]
                guard cross(a, b, c) > 1e-9 else { continue }
                let inside = idx.contains { j in
                    guard j != ia && j != ib && j != ic else { return false }
                    let q = p[j]
                    return cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0
                }
                if inside { continue }
                out += [ia, ib, ic]
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx }
        return out
    }
}

/// Incremental mesh construction with automatic outward winding.
struct MeshBuilder {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var triangleFaces: [Int32] = []
    var edges: [[SIMD3<Float>]] = []
    var faceCount: Int32 = 0

    mutating func beginFace() -> Int32 { defer { faceCount += 1 }; return faceCount }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> UInt32 {
        positions.append(p)
        normals.append(n)
        return UInt32(positions.count - 1)
    }

    /// Adds a triangle, flipping it if its winding disagrees with the vertex normals.
    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, face: Int32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let g = simd_cross(pb - pa, pc - pa)
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        if simd_dot(g, n) < 0 { indices += [a, c, b] } else { indices += [a, b, c] }
        triangleFaces.append(face)
    }

    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>, face: Int32) {
        let v = [vertex(a, normal), vertex(b, normal), vertex(c, normal), vertex(d, normal)]
        triangle(v[0], v[1], v[2], face: face)
        triangle(v[0], v[2], v[3], face: face)
    }

    mutating func addEdge(_ polyline: [SIMD3<Float>]) { edges.append(polyline) }

    var mesh: Mesh {
        Mesh(positions: positions, normals: normals, indices: indices, triangleFaces: triangleFaces, edges: edges)
    }
}
