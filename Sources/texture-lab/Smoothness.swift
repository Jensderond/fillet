import FilletCore
import FilletKernel
import Foundation
import simd

/// `texture-lab smoothness`: how rough a textured mesh looks, in numbers.
///
/// Measured on the meshes the app makes (display: `TextureEngine.apply` at `.display`, then
/// `creaseShaded()`; export: `printMesh`), against a fine tessellation of the untextured shape:
/// each point's height `h` over that base surface tells joint floor, stone top and the rounded
/// shoulder between them apart, and gives guard numbers (relief depth, joint width, edge slope,
/// grain) that drop when a "smoother" result is only a flatter one. Everything is deterministic:
/// no sums run in dictionary order or across threads.
enum Smoothness {
    enum Mode: String, CaseIterable { case display, export }

    struct Options {
        var modes: [Mode] = Mode.allCases
        /// Self-test: moves every point along the base normal by a pseudo-random ±`jitter` mm.
        var jitter = 0.0
        /// Self-test: scales every point's height over the base surface.
        var flatten = 1.0
    }

    // MARK: Entry

    static func main(files: [URL], options: Options) async throws {
        var out: [[String: Any]] = []
        for file in files {
            let doc = try Document(data: Data(contentsOf: file))
            let model = await ModelEvaluator(displayMeshes: false).evaluate(doc)
            for f in doc.activeFeatures {
                if case .failed(let m) = model.status[f.id] { fail("\(file.lastPathComponent): step “\(f.name)” failed: \(m)") }
            }
            let name = file.deletingPathExtension().lastPathComponent
            for (i, body) in model.bodies.enumerated() where !body.textures.isEmpty {
                var faces = Set<Int32>()
                var amplitude = 0.0
                for t in body.textures {
                    for f in TextureEngine.faces(of: t, on: body.shape) { faces.insert(Int32(f)) }
                    amplitude = max(amplitude, TextureCatalog.make(t.pattern, t.values)?.amplitude ?? 0)
                }
                // The untextured surface, far finer than either textured mesh (1 µm chords).
                let fine = try body.shape.tessellate(linearDeflection: 0.001, angularDeflection: 0.05)
                let base = BaseSurface(fine, faces: faces, reach: max(1.0, 1.3 * amplitude + 0.3))
                for mode in options.modes {
                    log("smoothness: \(name) body \(i) \(mode.rawValue)…")
                    var mesh: Mesh
                    switch mode {
                    case .display:
                        let d = ModelEvaluator.texturedBaseDeflection(for: body.shape)
                        let coarse = try body.shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)
                        mesh = TextureEngine.apply(body.textures, to: coarse, of: body.shape, quality: .display)
                    case .export:
                        mesh = try body.printMesh(quality: .export)
                    }
                    if options.jitter != 0 || options.flatten != 1 {
                        mesh = perturbed(mesh, base: base, faces: faces, jitter: options.jitter, flatten: options.flatten)
                    }
                    // What is shaded: the viewport's own normals for display; for an export (which
                    // has none: a slicer or viewer makes its own) the same crease-aware normals
                    // on the welded mesh, as `texture-lab render` draws it.
                    let shaded = (mode == .display ? mesh : welded(mesh)).creaseShaded()
                    var result = analyse(shaded, faces: faces, base: base, mode: mode)
                    result["fixture"] = name
                    result["body"] = i
                    result["mode"] = mode.rawValue
                    result["amplitudeMm"] = round(amplitude, 4)
                    if options.jitter != 0 { result["selfTestJitterMm"] = options.jitter }
                    if options.flatten != 1 { result["selfTestFlatten"] = options.flatten }
                    out.append(result)
                }
            }
        }
        FileHandle.standardOutput.write(Data((json(["results": out]) + "\n").utf8))
    }

    /// `value` (dictionaries, arrays, strings and numbers) as indented JSON with sorted keys and
    /// short numbers (JSONSerialization writes 0.2264 as 0.22639999999999999).
    static func json(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let d as [String: Any]:
            if d.isEmpty { return "{}" }
            return "{\n" + d.keys.sorted().map { "\(inner)\"\($0)\": \(json(d[$0]!, indent: inner))" }.joined(separator: ",\n") + "\n\(indent)}"
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + json($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let s as String: return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case let i as Int: return String(i)
        case let v as Double: return v.isFinite ? String(format: "%.10g", v) : "null"
        default: return "null"
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func round(_ v: Double, _ digits: Int = 4) -> Double {
        guard v.isFinite else { return -1 }
        let s = pow(10.0, Double(digits))
        return (v * s).rounded() / s
    }

    // MARK: Base surface

    /// The untextured faces' fine triangles in a grid, for the nearest point on them.
    struct BaseSurface: @unchecked Sendable {
        var a: [SIMD3<Double>] = [], b: [SIMD3<Double>] = [], c: [SIMD3<Double>] = []
        var normal: [SIMD3<Double>] = []
        var center: [SIMD3<Double>] = []
        var radius: [Double] = []
        var origin = SIMD3<Double>.zero
        var cell = 1.0
        var dims = SIMD3<Int>(1, 1, 1)
        var start: [Int32] = [0, 0]
        var items: [Int32] = []

        init(_ mesh: Mesh, faces: Set<Int32>, reach: Double) {
            cell = reach
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for t in 0..<mesh.triangleCount where faces.contains(mesh.triangleFaces[t]) {
                let p = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t])])
                let q = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 1])])
                let r = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 2])])
                let n = simd_cross(q - p, r - p)
                let l = simd_length(n)
                guard l > 0 else { continue }
                a.append(p); b.append(q); c.append(r)
                normal.append(n / l)
                let m = (p + q + r) / 3
                center.append(m)
                radius.append(max(simd_length(p - m), simd_length(q - m), simd_length(r - m)))
                lo = simd_min(lo, simd_min(p, simd_min(q, r))); hi = simd_max(hi, simd_max(p, simd_max(q, r)))
            }
            guard !a.isEmpty else { return }
            origin = lo
            let span = hi - lo
            dims = SIMD3(Int(span.x / cell) + 1, Int(span.y / cell) + 1, Int(span.z / cell) + 1)
            let cells = dims.x * dims.y * dims.z
            func range(_ t: Int) -> (SIMD3<Int>, SIMD3<Int>) {
                let l = simd_min(a[t], simd_min(b[t], c[t])), h = simd_max(a[t], simd_max(b[t], c[t]))
                return (index(l), index(h))
            }
            var count = [Int32](repeating: 0, count: cells + 1)
            for t in a.indices {
                let (l, h) = range(t)
                for z in l.z...h.z { for y in l.y...h.y { for x in l.x...h.x { count[flat(x, y, z) + 1] += 1 } } }
            }
            for i in 0..<cells { count[i + 1] += count[i] }
            start = count
            var fill = count
            items = [Int32](repeating: 0, count: Int(count[cells]))
            for t in a.indices {
                let (l, h) = range(t)
                for z in l.z...h.z { for y in l.y...h.y { for x in l.x...h.x {
                    let k = flat(x, y, z)
                    items[Int(fill[k])] = Int32(t)
                    fill[k] += 1
                } } }
            }
        }

        func index(_ p: SIMD3<Double>) -> SIMD3<Int> {
            let q = (p - origin) / cell
            return SIMD3(min(max(Int(q.x.rounded(.down)), 0), dims.x - 1), min(max(Int(q.y.rounded(.down)), 0), dims.y - 1),
                         min(max(Int(q.z.rounded(.down)), 0), dims.z - 1))
        }

        func flat(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * dims.y + y) * dims.x + x }

        /// The nearest point of the base to `p` within one cell: its signed height over it (along
        /// the base's normal there), the point and that normal. nil when nothing is that near.
        func nearest(_ p: SIMD3<Double>) -> (height: Double, point: SIMD3<Double>, normal: SIMD3<Double>)? {
            guard !a.isEmpty else { return nil }
            let i = index(p)
            var best = cell * cell, bestPoint = SIMD3<Double>.zero, bestTriangle = -1
            for z in max(i.z - 1, 0)...min(i.z + 1, dims.z - 1) {
                for y in max(i.y - 1, 0)...min(i.y + 1, dims.y - 1) {
                    for x in max(i.x - 1, 0)...min(i.x + 1, dims.x - 1) {
                        let k = flat(x, y, z)
                        for s in Int(start[k])..<Int(start[k + 1]) {
                            let t = Int(items[s])
                            let reach = simd_length(p - center[t]) - radius[t]
                            if reach > 0, reach * reach >= best { continue }
                            let q = Smoothness.closest(p, a[t], b[t], c[t])
                            let d = simd_length_squared(p - q)
                            // Ties to the lower triangle, so the answer doesn't depend on the order.
                            if d < best || (d == best && t < bestTriangle) { best = d; bestPoint = q; bestTriangle = t }
                        }
                    }
                }
            }
            guard bestTriangle >= 0 else { return nil }
            let n = normal[bestTriangle]
            let side = simd_dot(p - bestPoint, n)
            return (side < 0 ? -best.squareRoot() : best.squareRoot(), bestPoint, n)
        }
    }

    /// The point of triangle abc nearest to p (Ericson, Real-Time Collision Detection 5.1.5).
    static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    // MARK: Mesh helpers

    /// `count` values worked out across the cores, each on its own (the same as one by one).
    static func parallelMap<T>(_ count: Int, chunk: Int = 2048, _ transform: @escaping (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let slots = Slots(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { block in
                for i in (block * chunk)..<min(count, (block + 1) * chunk) { (slots.base + i).initialize(to: transform(i)) }
            }
            initialized = count
        }
    }

    private struct Slots<T>: @unchecked Sendable { let base: UnsafeMutablePointer<T> }

    /// The mesh with one vertex per distinct position (degenerate triangles dropped).
    static func welded(_ mesh: Mesh) -> Mesh {
        var index: [SIMD3<Float>: UInt32] = [:]
        index.reserveCapacity(mesh.positions.count)
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = [], faces: [Int32] = []
        indices.reserveCapacity(mesh.indices.count)
        for t in 0..<mesh.triangleCount {
            var v = SIMD3<UInt32>()
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[3 * t + k])]
                if let i = index[p] { v[k] = i } else {
                    v[k] = UInt32(positions.count)
                    index[p] = v[k]
                    positions.append(p)
                }
            }
            guard v.x != v.y, v.y != v.z, v.x != v.z else { continue }
            indices += [v.x, v.y, v.z]
            faces.append(mesh.triangleFaces[t])
        }
        return Mesh(positions: positions, normals: [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: positions.count), indices: indices,
                    triangleFaces: faces, edges: [])
    }

    /// A number in -1…1 from a position's bits (the same for every copy of a point).
    static func noise(_ p: SIMD3<Float>) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in [p.x.bitPattern, p.y.bitPattern, p.z.bitPattern] {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
            h ^= h >> 29
            h = h &* 0xbf58_476d_1ce4_e5b9
            h ^= h >> 32
        }
        return Double(h >> 11) / Double(1 << 52) - 1
    }

    /// Self-test: the textured faces' points moved along the base normal (see ``Options``).
    static func perturbed(_ mesh: Mesh, base: BaseSurface, faces: Set<Int32>, jitter: Double, flatten: Double) -> Mesh {
        var move = [Bool](repeating: false, count: mesh.positions.count)
        var fixed: Set<SIMD3<Float>> = []
        for t in 0..<mesh.triangleCount {
            let textured = faces.contains(mesh.triangleFaces[t])
            for k in 0..<3 {
                let v = Int(mesh.indices[3 * t + k])
                if textured { move[v] = true } else { fixed.insert(mesh.positions[v]) }
            }
        }
        var out = mesh
        let positions = mesh.positions
        let moved = parallelMap(positions.count) { v -> SIMD3<Float> in
            let p = positions[v]
            guard move[v], !fixed.contains(p), let near = base.nearest(SIMD3<Double>(p)) else { return p }
            let h = near.height * flatten + jitter * noise(p)
            // Along the line the point was displaced along, not the facet's normal.
            let along = abs(near.height) > 1e-6 ? (SIMD3<Double>(p) - near.point) / near.height : near.normal
            return SIMD3<Float>(near.point + along * h)
        }
        out.positions = moved
        return out
    }

    /// Weighted mean and percentiles of `values`.
    struct Distribution {
        var pairs: [(value: Double, weight: Double)] = []
        mutating func add(_ v: Double, _ w: Double = 1) { if v.isFinite, w > 0 { pairs.append((v, w)) } }

        func summary(_ percentiles: [Int] = [50, 95, 99], digits: Int = 4, max: Bool = true, rms: Bool = false) -> [String: Any] {
            guard !pairs.isEmpty else { return ["n": 0] }
            let sorted = pairs.sorted { $0.value < $1.value }
            var total = 0.0, sum = 0.0, squares = 0.0
            for p in sorted { total += p.weight; sum += p.value * p.weight; squares += p.value * p.value * p.weight }
            var out: [String: Any] = ["n": sorted.count, "mean": Smoothness.round(sum / total, digits)]
            if rms { out["rms"] = Smoothness.round((squares / total).squareRoot(), digits) }
            var running = 0.0, next = 0
            let wanted = percentiles.sorted()
            for p in sorted {
                running += p.weight
                while next < wanted.count, running >= total * Double(wanted[next]) / 100 {
                    out["p\(wanted[next])"] = Smoothness.round(p.value, digits)
                    next += 1
                }
            }
            while next < wanted.count { out["p\(wanted[next])"] = Smoothness.round(sorted.last!.value, digits); next += 1 }
            if max { out["max"] = Smoothness.round(sorted.last!.value, digits) }
            return out
        }

        func percentile(_ q: Double) -> Double {
            guard !pairs.isEmpty else { return .nan }
            let sorted = pairs.sorted { $0.value < $1.value }
            let total = sorted.reduce(0) { $0 + $1.weight }
            var running = 0.0
            for p in sorted {
                running += p.weight
                if running >= total * q { return p.value }
            }
            return sorted.last!.value
        }
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        // atan2 rather than acos: exact for the small angles this is all about.
        atan2(simd_length(simd_cross(a, b)), simd_dot(a, b)) * 180 / .pi
    }

    /// Solves the symmetric system `m x = r` (n ≤ 6) by elimination with pivoting; nil if singular.
    static func solve(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        let n = r.count
        var a = m, b = r
        for i in 0..<n {
            var pivot = i
            for j in (i + 1)..<n where abs(a[j][i]) > abs(a[pivot][i]) { pivot = j }
            guard abs(a[pivot][i]) > 1e-12 else { return nil }
            if pivot != i { a.swapAt(i, pivot); b.swapAt(i, pivot) }
            for j in (i + 1)..<n {
                let f = a[j][i] / a[i][i]
                if f == 0 { continue }
                for k in i..<n { a[j][k] -= f * a[i][k] }
                b[j] -= f * b[i]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = b[i]
            for k in (i + 1)..<n { s -= a[i][k] * x[k] }
            x[i] = s / a[i][i]
        }
        return x
    }

    // MARK: Analysis

    static let classNames = ["floor", "top", "shoulder"]
    /// Radius of the neighbourhood a smooth quadric is fitted to, mm (see `roughness`): about
    /// three triangles of that mode's stone-edge mesh.
    static func fitRadius(_ mode: Mode) -> Double { mode == .display ? 0.9 : 0.45 }
    static let grainRadius = 2.0
    static let rimWidth = 3.0
    static let outlineWindow = 1.5

    static func analyse(_ mesh: Mesh, faces: Set<Int32>, base: BaseSurface, mode: Mode) -> [String: Any] {
        // The textured triangles, welded by position; each corner keeps its shaded normal.
        var index: [SIMD3<Float>: Int32] = [:]
        var points: [SIMD3<Double>] = []
        var tris: [SIMD3<Int32>] = []
        var cornerNormals: [SIMD3<Double>] = []
        var degenerate = 0
        for t in 0..<mesh.triangleCount where faces.contains(mesh.triangleFaces[t]) {
            var v = SIMD3<Int32>()
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[3 * t + k])]
                if let i = index[p] { v[k] = i } else {
                    v[k] = Int32(points.count)
                    index[p] = v[k]
                    points.append(SIMD3<Double>(p))
                }
            }
            guard v.x != v.y, v.y != v.z, v.x != v.z else { degenerate += 1; continue }
            let n = simd_cross(points[Int(v.y)] - points[Int(v.x)], points[Int(v.z)] - points[Int(v.x)])
            guard simd_length(n) > 0 else { degenerate += 1; continue }
            tris.append(v)
            for k in 0..<3 { cornerNormals.append(SIMD3<Double>(mesh.normals[Int(mesh.indices[3 * t + k])])) }
        }
        index = [:]
        let n = points.count, tn = tris.count
        guard tn > 0 else { return ["error": "no textured triangles"] }

        // Per triangle: unit normal, area.
        var normals = [SIMD3<Double>](repeating: .zero, count: tn), areas = [Double](repeating: 0, count: tn)
        for t in 0..<tn {
            let c = simd_cross(points[Int(tris[t].y)] - points[Int(tris[t].x)], points[Int(tris[t].z)] - points[Int(tris[t].x)])
            let l = simd_length(c)
            normals[t] = c / l
            areas[t] = l / 2
        }
        let totalArea = areas.reduce(0, +)

        // Height over the base surface.
        let near = parallelMap(n) { v in base.nearest(points[v]) }
        let h = near.map { $0?.height ?? .nan }
        let unmatched = h.reduce(0) { $0 + ($1.isNaN ? 1 : 0) }
        var vertexArea = [Double](repeating: 0, count: n)
        for t in 0..<tn { for k in 0..<3 { vertexArea[Int(tris[t][k])] += areas[t] / 3 } }
        var heights = Distribution()
        for v in 0..<n { heights.add(h[v], vertexArea[v]) }
        let hLo = heights.percentile(0.005), hHi = heights.percentile(0.995)
        let range = max(hHi - hLo, 1e-9)

        // Slope of the relief on each triangle (the gradient of h along it) and its class:
        // 0 joint floor, 1 stone top, 2 the round between them.
        var slope = [Double](repeating: .nan, count: tn), meanH = [Double](repeating: .nan, count: tn)
        var kind = [UInt8](repeating: 2, count: tn)
        for t in 0..<tn {
            let a = Int(tris[t].x), b = Int(tris[t].y), c = Int(tris[t].z)
            guard !h[a].isNaN, !h[b].isNaN, !h[c].isNaN else { continue }
            let g = (simd_cross(normals[t], points[c] - points[b]) * h[a] + simd_cross(normals[t], points[a] - points[c]) * h[b]
                + simd_cross(normals[t], points[b] - points[a]) * h[c]) / (2 * areas[t])
            slope[t] = atan(simd_length(g)) * 180 / .pi
            meanH[t] = (h[a] + h[b] + h[c]) / 3
            let level = (meanH[t] - hLo) / range
            if slope[t] < 10 { kind[t] = level < 0.08 ? 0 : (level > 0.6 ? 1 : 2) }
        }
        var classArea = [Double](repeating: 0, count: 3)
        for t in 0..<tn { classArea[Int(kind[t])] += areas[t] }

        // Edges: (key, triangle) sorted, so the two triangles of an edge sit next to each other.
        var halves: [(key: UInt64, tri: Int32)] = []
        halves.reserveCapacity(3 * tn)
        for t in 0..<tn {
            for k in 0..<3 {
                let a = tris[t][k], b = tris[t][(k + 1) % 3]
                halves.append((UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b))), Int32(t)))
            }
        }
        halves.sort { $0.key != $1.key ? $0.key < $1.key : $0.tri < $1.tri }
        var boundary = [Bool](repeating: false, count: n)
        var nonManifold = 0
        var ringStart = [Int32](repeating: 0, count: n + 1)
        var edgeList: [(a: Int32, b: Int32, t0: Int32, t1: Int32)] = []
        var i = 0
        while i < halves.count {
            var j = i + 1
            while j < halves.count, halves[j].key == halves[i].key { j += 1 }
            let a = Int32(halves[i].key >> 32), b = Int32(halves[i].key & 0xffff_ffff)
            ringStart[Int(a) + 1] += 1; ringStart[Int(b) + 1] += 1
            if j - i == 2 {
                edgeList.append((a, b, halves[i].tri, halves[i + 1].tri))
            } else {
                if j - i > 2 { nonManifold += 1 }
                edgeList.append((a, b, halves[i].tri, -1))
                boundary[Int(a)] = true; boundary[Int(b)] = true
            }
            i = j
        }
        for v in 0..<n { ringStart[v + 1] += ringStart[v] }
        var ringFill = ringStart
        var ring = [Int32](repeating: 0, count: Int(ringStart[n]))
        for e in edgeList {
            ring[Int(ringFill[Int(e.a)])] = e.b; ringFill[Int(e.a)] += 1
            ring[Int(ringFill[Int(e.b)])] = e.a; ringFill[Int(e.b)] += 1
        }

        // Points within `rimWidth` of the textured faces' border (a rim, the bed, an untextured
        // face): where the relief runs out, which has its own ways of going wrong.
        var borderCells: [SIMD3<Int32>: [Int32]] = [:]
        func borderCell(_ p: SIMD3<Double>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / rimWidth).rounded(.down)), Int32((p.y / rimWidth).rounded(.down)), Int32((p.z / rimWidth).rounded(.down)))
        }
        for v in 0..<n where boundary[v] { borderCells[borderCell(points[v]), default: []].append(Int32(v)) }
        let borders = borderCells
        let rim = parallelMap(n) { v -> Bool in
            let c = borderCell(points[v])
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                guard let list = borders[c &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                for b in list where simd_length_squared(points[Int(b)] - points[v]) <= rimWidth * rimWidth { return true }
            } } }
            return false
        }
        var rimArea = 0.0
        for v in 0..<n where rim[v] { rimArea += vertexArea[v] }

        // Dihedral angles, weighted by edge length. Slot 3 is everything, 4 the rim zone.
        var dihedral = [Distribution](repeating: Distribution(), count: 5)
        for e in edgeList where e.t1 >= 0 {
            let d = angle(normals[Int(e.t0)], normals[Int(e.t1)])
            let w = simd_length(points[Int(e.a)] - points[Int(e.b)])
            let k = Int(max(kind[Int(e.t0)], kind[Int(e.t1)]))
            dihedral[k].add(d, w)
            dihedral[3].add(d, w)
            if rim[Int(e.a)] || rim[Int(e.b)] { dihedral[4].add(d, w) }
        }

        // Shaded normal per point (the area-weighted mean of its corners') and how far its
        // corners' normals are apart (a split smooth group shades as a seam).
        var shaded = [SIMD3<Double>](repeating: .zero, count: n)
        var vertexKind = [UInt8](repeating: 0, count: n)
        for t in 0..<tn {
            for k in 0..<3 {
                let v = Int(tris[t][k])
                shaded[v] += cornerNormals[3 * t + k] * areas[t]
                vertexKind[v] = max(vertexKind[v], kind[t])
            }
        }
        for v in 0..<n { shaded[v] = simd_length(shaded[v]) > 0 ? simd_normalize(shaded[v]) : SIMD3(0, 0, 1) }
        var split = [Double](repeating: 0, count: n)
        for t in 0..<tn {
            for k in 0..<3 {
                let v = Int(tris[t][k])
                split[v] = max(split[v], angle(cornerNormals[3 * t + k], shaded[v]))
            }
        }
        var splitArea = 0.0, splitCount = 0, interiorArea = 0.0
        var splits = Distribution()
        for v in 0..<n where !boundary[v] {
            interiorArea += vertexArea[v]
            splits.add(split[v], vertexArea[v])
            if split[v] > 2 { splitArea += vertexArea[v]; splitCount += 1 }
        }

        // Shading noise: each point's shaded normal against the mean of its neighbours'.
        var ringNoise = [Distribution](repeating: Distribution(), count: 5)
        for v in 0..<n where !boundary[v] {
            var sum = SIMD3<Double>.zero
            for s in Int(ringStart[v])..<Int(ringStart[v + 1]) { sum += shaded[Int(ring[s])] }
            guard simd_length(sum) > 0 else { continue }
            let d = angle(shaded[v], sum)
            ringNoise[Int(vertexKind[v])].add(d, vertexArea[v])
            ringNoise[3].add(d, vertexArea[v])
            if rim[v] { ringNoise[4].add(d, vertexArea[v]) }
        }

        // Triangle centroids in a grid, for the fits at a fixed size in mm.
        let radius = fitRadius(mode)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let cell = radius
        let dims = SIMD3<Int>(Int((hi.x - lo.x) / cell) + 1, Int((hi.y - lo.y) / cell) + 1, Int((hi.z - lo.z) / cell) + 1)
        func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int> {
            let q = (p - lo) / cell
            return SIMD3(min(max(Int(q.x), 0), dims.x - 1), min(max(Int(q.y), 0), dims.y - 1), min(max(Int(q.z), 0), dims.z - 1))
        }
        let centroids = (0..<tn).map { (points[Int(tris[$0].x)] + points[Int(tris[$0].y)] + points[Int(tris[$0].z)]) / 3 }
        var gridStart = [Int32](repeating: 0, count: dims.x * dims.y * dims.z + 1)
        let triCell = centroids.map { c -> Int in let k = cellOf(c); return (k.z * dims.y + k.y) * dims.x + k.x }
        for k in triCell { gridStart[k + 1] += 1 }
        for k in 0..<(gridStart.count - 1) { gridStart[k + 1] += gridStart[k] }
        var gridFill = gridStart
        var gridItems = [Int32](repeating: 0, count: tn)
        for t in 0..<tn { gridItems[Int(gridFill[triCell[t]])] = Int32(t); gridFill[triCell[t]] += 1 }
        /// Triangles whose centroid is within `r` of `p`, in a fixed order.
        func trianglesNear(_ p: SIMD3<Double>, _ r: Double) -> [Int32] {
            let reach = Int((r / cell).rounded(.up))
            let k = cellOf(p)
            var out: [Int32] = []
            for z in max(k.z - reach, 0)...min(k.z + reach, dims.z - 1) {
                for y in max(k.y - reach, 0)...min(k.y + reach, dims.y - 1) {
                    for x in max(k.x - reach, 0)...min(k.x + reach, dims.x - 1) {
                        let c = (z * dims.y + y) * dims.x + x
                        for s in Int(gridStart[c])..<Int(gridStart[c + 1]) where simd_length_squared(centroids[Int(gridItems[s])] - p) <= r * r {
                            out.append(gridItems[s])
                        }
                    }
                }
            }
            return out
        }

        // Sample points for the fits: every k-th interior point of each class, at most 6000.
        var samples: [[Int]] = [[], [], []]
        for k in 0..<3 {
            let members = (0..<n).filter { !boundary[$0] && Int(vertexKind[$0]) == k && !h[$0].isNaN }
            let step = max(1, members.count / 6000)
            samples[k] = stride(from: 0, to: members.count, by: step).map { members[$0] }
        }
        let flat = samples[0] + samples[1] + samples[2]
        // Roughness at a fixed size: the surface within `radius` (triangle corners and centroids,
        // by area) against the best smooth quadric through it. The residual is what the mesh adds
        // on top of a smooth surface (facets and noise), the fitted normal's angle to the shaded
        // one is what that does to the shading.
        let fits = parallelMap(flat.count, chunk: 64) { s -> (residual: Double, normalError: Double)? in
            let v = flat[s]
            let o = points[v], z = shaded[v]
            let x = simd_normalize(simd_cross(abs(z.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0), z))
            let y = simd_cross(z, x)
            let near = trianglesNear(o, radius)
            guard near.count >= 10 else { return nil }
            var m = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6), r = [Double](repeating: 0, count: 6)
            var samples: [(SIMD3<Double>, Double)] = []
            samples.reserveCapacity(near.count * 4)
            for t in near {
                let tri = tris[Int(t)], w = areas[Int(t)]
                for k in 0..<3 { samples.append(((points[Int(tri[k])] - o) / radius, w / 6)) }
                samples.append(((centroids[Int(t)] - o) / radius, w / 2))
            }
            for (d, w) in samples {
                let px = simd_dot(d, x), py = simd_dot(d, y), pz = simd_dot(d, z)
                let f = [1, px, py, px * px, px * py, py * py]
                for a in 0..<6 {
                    r[a] += w * f[a] * pz
                    for b in 0..<6 { m[a][b] += w * f[a] * f[b] }
                }
            }
            guard let c = solve(m, r) else { return nil }
            var sum = 0.0, weight = 0.0
            for (d, w) in samples {
                let px = simd_dot(d, x), py = simd_dot(d, y), pz = simd_dot(d, z)
                let e = pz - (c[0] + c[1] * px + c[2] * py + c[3] * px * px + c[4] * px * py + c[5] * py * py)
                sum += w * e * e; weight += w
            }
            let fitted = simd_normalize(z - x * c[1] - y * c[2])
            return ((sum / weight).squareRoot() * radius * 1000, angle(fitted, z))
        }
        var residual = [Distribution](repeating: Distribution(), count: 4), normalError = [Distribution](repeating: Distribution(), count: 4)
        var offset = 0
        for k in 0..<3 {
            for s in 0..<samples[k].count {
                guard let f = fits[offset + s] else { continue }
                residual[k].add(f.residual); normalError[k].add(f.normalError)
                residual[3].add(f.residual); normalError[3].add(f.normalError)
            }
            offset += samples[k].count
        }

        // Guard: the grain on the stone tops, as the height's deviation from a plane over 2 mm.
        let topSamples = samples[1]
        let grains = parallelMap(topSamples.count, chunk: 64) { s -> Double? in
            let v = topSamples[s]
            let o = points[v], z = shaded[v]
            let x = simd_normalize(simd_cross(abs(z.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0), z))
            let y = simd_cross(z, x)
            let near = trianglesNear(o, grainRadius)
            guard near.count >= 10 else { return nil }
            var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3), r = [Double](repeating: 0, count: 3)
            var topArea = 0.0, area = 0.0
            for t in near {
                area += areas[Int(t)]
                if kind[Int(t)] == 1 { topArea += areas[Int(t)] }
            }
            guard topArea >= 0.97 * area else { return nil }
            for t in near where !meanH[Int(t)].isNaN {
                let d = centroids[Int(t)] - o, w = areas[Int(t)]
                let f = [1, simd_dot(d, x), simd_dot(d, y)]
                for a in 0..<3 {
                    r[a] += w * f[a] * meanH[Int(t)]
                    for b in 0..<3 { m[a][b] += w * f[a] * f[b] }
                }
            }
            guard let c = solve(m, r) else { return nil }
            var sum = 0.0, weight = 0.0
            for t in near where !meanH[Int(t)].isNaN {
                let d = centroids[Int(t)] - o, w = areas[Int(t)]
                let e = meanH[Int(t)] - (c[0] + c[1] * simd_dot(d, x) + c[2] * simd_dot(d, y))
                sum += w * e * e; weight += w
            }
            return (sum / weight).squareRoot() * 1000
        }
        var grain = Distribution()
        for g in grains { if let g { grain.add(g) } }

        // Outlines: the level lines of h a quarter and halfway up the relief.
        func outline(_ fraction: Double) -> [String: Any] {
            let level = hLo + fraction * range
            var nodeOf: [UInt64: Int32] = [:]
            var nodes: [SIMD3<Double>] = []
            var links: [SIMD2<Int32>] = []
            var below = 0.0
            var slopes = Distribution()
            func node(_ a: Int32, _ b: Int32) -> Int32 {
                let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                if let i = nodeOf[key] { return i }
                let lowV = Int(min(a, b)), highV = Int(max(a, b))
                let t = (level - h[lowV]) / (h[highV] - h[lowV])
                let i = Int32(nodes.count)
                nodeOf[key] = i
                nodes.append(points[lowV] + (points[highV] - points[lowV]) * t)
                links.append(SIMD2(-1, -1))
                return i
            }
            func link(_ a: Int32, _ b: Int32) {
                if links[Int(a)].x < 0 { links[Int(a)].x = b } else if links[Int(a)].y < 0 { links[Int(a)].y = b }
            }
            for t in 0..<tn {
                let tri = tris[t]
                let hs = [h[Int(tri.x)], h[Int(tri.y)], h[Int(tri.z)]]
                guard !hs[0].isNaN, !hs[1].isNaN, !hs[2].isNaN else { continue }
                let under = hs.map { $0 < level }
                let count = under.filter { $0 }.count
                if count == 3 { below += areas[t]; continue }
                if count == 0 { continue }
                var crossing: [Int32] = []
                for k in 0..<3 where under[k] != under[(k + 1) % 3] { crossing.append(node(tri[k], tri[(k + 1) % 3])) }
                guard crossing.count == 2, crossing[0] != crossing[1] else { continue }
                link(crossing[0], crossing[1]); link(crossing[1], crossing[0])
                // The part of the triangle under the level.
                let lone = count == 1 ? under.firstIndex(of: true)! : under.firstIndex(of: false)!
                let h0 = hs[lone], h1 = hs[(lone + 1) % 3], h2 = hs[(lone + 2) % 3]
                let corner = areas[t] * ((level - h0) / (h1 - h0)) * ((level - h0) / (h2 - h0))
                below += count == 1 ? corner : areas[t] - corner
                slopes.add(slope[t], simd_length(nodes[Int(crossing[0])] - nodes[Int(crossing[1])]))
            }
            // Chains: from open ends first, then closed loops, in node order.
            var visited = [Bool](repeating: false, count: nodes.count)
            var jag = Distribution()
            var turning = Distribution()
            var length = 0.0
            func walk(from first: Int, closed: Bool) {
                var chain = [first]
                visited[first] = true
                var previous = -1, current = first
                while true {
                    let l = links[current]
                    var next = Int(l.x)
                    if next < 0 || next == previous || visited[next] { next = Int(l.y) }
                    if next < 0 || visited[next] { break }
                    visited[next] = true
                    chain.append(next)
                    previous = current; current = next
                }
                let count = chain.count
                guard count >= 3 else { return }
                var s = [Double](repeating: 0, count: count)
                for i in 1..<count { s[i] = s[i - 1] + simd_length(nodes[chain[i]] - nodes[chain[i - 1]]) }
                let closing = closed ? simd_length(nodes[chain[0]] - nodes[chain[count - 1]]) : 0
                let total = s[count - 1] + closing
                length += total
                let half = outlineWindow / 2
                guard total > 2 * outlineWindow else { return }
                func weight(_ i: Int) -> Double {
                    let before = i > 0 ? s[i] - s[i - 1] : closing
                    let after = i < count - 1 ? s[i + 1] - s[i] : closing
                    return (before + after) / 2
                }
                for i in 0..<count {
                    if !closed, s[i] < half || total - s[i] < half { continue }
                    // Turning angle at the node.
                    let a = nodes[chain[(i + count - 1) % count]], b = nodes[chain[i]], c = nodes[chain[(i + 1) % count]]
                    if closed || (i > 0 && i < count - 1), simd_length(b - a) > 0, simd_length(c - b) > 0 {
                        turning.add(angle(b - a, c - b), weight(i))
                    }
                    // The nodes within half a window along the line, either way.
                    var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
                    var r = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
                    var used = 0
                    func take(_ j: Int, _ at: Double) {
                        let u = at / half, w = weight(j), p = nodes[chain[j]] - b
                        let f = [1, u, u * u]
                        for a in 0..<3 {
                            for c in 0..<3 { m[a][c] += w * f[a] * f[c]; r[c][a] += w * f[a] * p[c] }
                        }
                        used += 1
                    }
                    take(i, 0)
                    var j = i, at = 0.0
                    while true {
                        let nextIndex = j + 1 < count ? j + 1 : (closed ? 0 : -1)
                        guard nextIndex >= 0 else { break }
                        at += j + 1 < count ? s[j + 1] - s[j] : closing
                        guard at <= half, nextIndex != i else { break }
                        take(nextIndex, at); j = nextIndex
                    }
                    j = i; at = 0
                    while true {
                        let nextIndex = j > 0 ? j - 1 : (closed ? count - 1 : -1)
                        guard nextIndex >= 0 else { break }
                        at -= j > 0 ? s[j] - s[j - 1] : closing
                        guard -at <= half, nextIndex != i else { break }
                        take(nextIndex, at); j = nextIndex
                    }
                    guard used >= 5 else { continue }
                    var centre = SIMD3<Double>.zero
                    var ok = true
                    for c in 0..<3 {
                        guard let x = solve(m, r[c]) else { ok = false; break }
                        centre[c] = x[0]
                    }
                    guard ok else { continue }
                    jag.add(simd_length(centre) * 1000, weight(i))
                }
            }
            for i in 0..<nodes.count where !visited[i] && (links[i].x < 0 || links[i].y < 0) { walk(from: i, closed: false) }
            for i in 0..<nodes.count where !visited[i] { walk(from: i, closed: true) }
            return [
                "levelMm": round(level), "lengthMm": round(length, 2),
                "jagUm": jag.summary([50, 95, 99], digits: 3, rms: true),
                "turnDeg": turning.summary([50, 95, 99], digits: 3, rms: true),
                "widthBelowMm": round(length > 0 ? 2 * below / length : 0),
                "slopeDeg": slopes.summary([10, 50, 90], digits: 3, max: false),
            ]
        }

        // Triangle quality.
        var minAngles = Distribution(), aspects = Distribution()
        var edgeLengths = [Distribution](repeating: Distribution(), count: 3)
        var slivers = 0, needles = 0
        for t in 0..<tn {
            let a = points[Int(tris[t].x)], b = points[Int(tris[t].y)], c = points[Int(tris[t].z)]
            let smallest = min(angle(b - a, c - a), angle(a - b, c - b), angle(a - c, b - c))
            minAngles.add(smallest)
            if smallest < 10 { slivers += 1 }
            if smallest < 2 { needles += 1 }
            let longest = max(simd_length(b - a), simd_length(c - b), simd_length(a - c))
            // 1 for an equilateral triangle.
            aspects.add(longest * longest * 3.0.squareRoot() / (4 * areas[t]))
            edgeLengths[Int(kind[t])].add(longest)
        }

        func byClass(_ d: [Distribution], digits: Int = 4) -> [String: Any] {
            var out: [String: Any] = ["all": d[3].summary(digits: digits)]
            for k in 0..<3 { out[classNames[k]] = d[k].summary(digits: digits) }
            if d.count > 4 { out["rim"] = d[4].summary(digits: digits) }
            return out
        }
        // How far the stone tops are from the base surface, µm: on a design without relief or
        // grain on the tops (the plain fixture) they should lie on it exactly.
        var topHeights = Distribution()
        for v in 0..<n where vertexKind[v] == 1 && !rim[v] && !h[v].isNaN { topHeights.add(h[v] * 1000, vertexArea[v]) }
        var topHeight = topHeights.summary([5, 50, 95], digits: 2, max: false)
        if !topHeights.pairs.isEmpty {
            var total = 0.0, sum = 0.0, squares = 0.0
            for p in topHeights.pairs.sorted(by: { $0.value < $1.value }) { total += p.weight; sum += p.value * p.weight; squares += p.value * p.value * p.weight }
            topHeight["std"] = round((squares / total - (sum / total) * (sum / total)).squareRoot(), 2)
        }
        var heightSquares = 0.0, heightWeight = 0.0
        for v in 0..<n where !h[v].isNaN { heightSquares += h[v] * h[v] * vertexArea[v]; heightWeight += vertexArea[v] }
        let foot = outline(0.25), mid = outline(0.5)
        return [
            "triangles": mesh.triangleCount,
            "texturedTriangles": tn,
            "texturedPoints": n,
            "degenerateTriangles": degenerate,
            "nonManifoldEdges": nonManifold,
            "unmatchedPoints": unmatched,
            "shading": [
                "ringNoiseDeg": byClass(ringNoise),
                "dihedralDeg": byClass(dihedral),
                "split": [
                    "areaFractionOver2Deg": round(splitArea / max(interiorArea, 1e-12), 6), "pointsOver2Deg": splitCount,
                    "deg": splits.summary([99], digits: 3),
                ],
            ],
            "roughness": [
                "radiusMm": radius,
                "fitResidualUm": byClass(residual, digits: 3),
                "fitNormalErrorDeg": byClass(normalError, digits: 3),
                "topHeightUm": topHeight,
            ],
            "outline": ["windowMm": outlineWindow, "foot": foot, "mid": mid],
            "triangleQuality": [
                "minAngleDeg": minAngles.summary([1, 5, 50], digits: 2, max: false),
                "aspect": aspects.summary([50, 95, 99], digits: 2),
                "sliverFraction": round(Double(slivers) / Double(tn), 6),
                "needles": needles,
                "longestEdgeMm": [
                    "floor": edgeLengths[0].summary([50, 95], digits: 3, max: false),
                    "top": edgeLengths[1].summary([50, 95], digits: 3, max: false),
                    "shoulder": edgeLengths[2].summary([50, 95], digits: 3, max: false),
                ],
            ],
            "guards": [
                "reliefRangeMm": round(range),
                "heightLowMm": round(hLo), "heightHighMm": round(hHi),
                "heightP1Mm": round(heights.percentile(0.01)), "heightP50Mm": round(heights.percentile(0.5)),
                "heightP99Mm": round(heights.percentile(0.99)),
                "heightRmsMm": round((heightSquares / max(heightWeight, 1e-12)).squareRoot()),
                "jointWidthFootMm": foot["widthBelowMm"] ?? 0, "jointWidthMidMm": mid["widthBelowMm"] ?? 0,
                "edgeSlopeMidDeg": mid["slopeDeg"] ?? [:],
                "outlineLengthMidMm": mid["lengthMm"] ?? 0,
                "topGrainUm": grain.summary([50, 90], digits: 2, max: false),
                "areaMm2": round(totalArea, 2),
                "rimAreaFraction": round(rimArea / totalArea),
                "areaFraction": [
                    "floor": round(classArea[0] / totalArea), "top": round(classArea[1] / totalArea),
                    "shoulder": round(classArea[2] / totalArea),
                ],
                "texturedTriangles": tn,
            ],
        ]
    }
}
