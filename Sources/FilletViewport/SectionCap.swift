import Foundation
import simd
import FilletKernel

// CPU side of section caps: the polygon each cap is drawn on, the outline where the plane
// meets a body, the hatch direction, and whether a point is cut away (picking).

extension SectionPlane {
    /// Unit normal, nil when the normal is degenerate (no section).
    var unitNormal: Vec3? { normal.length > 1e-9 ? normal.normalized : nil }

    /// Signed distance of `p` from the plane, positive on the side that is cut away.
    func distance(_ p: Vec3) -> Double { (p - origin).dot(unitNormal ?? .zero) }

    /// Whether `p` is on the side that is cut away (the same test as the shaders' `cutAway`).
    public func cuts(_ p: Vec3) -> Bool { distance(p) > 0 }

    /// Axes in the plane: `u` runs level (along the ground) wherever the plane isn't the ground
    /// itself, so hatching at 45° to it reads like a drawing's.
    var axes: (u: Vec3, v: Vec3) {
        let n = unitNormal ?? .unitZ
        var u = Vec3.unitZ.cross(n)
        if u.length < 1e-6 { u = n.z > 0 ? .unitX : -Vec3.unitX }
        u = u.normalized
        return (u, n.cross(u))
    }

    /// Whether the plane goes through `box` (or touches it).
    func crosses(_ box: Bounds3) -> Bool {
        guard let n = unitNormal else { return false }
        // The box's half extent along the normal, against its centre's distance from the plane.
        let c = (box.min + box.max) * 0.5, h = (box.max - box.min) * 0.5
        return abs((c - origin).dot(n)) <= abs(h.x * n.x) + abs(h.y * n.y) + abs(h.z * n.z)
    }

    /// Where the plane crosses `box` (grown a little so the cap covers the whole cut), as a convex
    /// polygon in order around the plane; empty when it misses.
    func polygon(through box: Bounds3) -> [Vec3] {
        guard let n = unitNormal else { return [] }
        let pad = max((box.max - box.min).length * 0.01, 1e-3)
        let lo = box.min - Vec3(pad, pad, pad), hi = box.max + Vec3(pad, pad, pad)
        let corners = (0..<8).map { i in
            Vec3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
        }
        let d = corners.map { ($0 - origin).dot(n) }
        var points: [Vec3] = []
        for a in 0..<8 {
            for bit in [1, 2, 4] where a & bit == 0 {
                let b = a | bit
                guard (d[a] > 0) != (d[b] > 0) else { continue }
                points.append(corners[a] + (corners[b] - corners[a]) * (d[a] / (d[a] - d[b])))
            }
        }
        guard points.count >= 3 else { return [] }
        let (u, v) = axes
        let c = points.reduce(Vec3.zero, +) / Double(points.count)
        return points.sorted { atan2(($0 - c).dot(v), ($0 - c).dot(u)) < atan2(($1 - c).dot(v), ($1 - c).dot(u)) }
    }

    /// The segments where the plane cuts the mesh's triangles: the cap's outline, exactly where
    /// the stencil cap ends (both come from the same triangles).
    func outline(of mesh: Mesh) -> [(SIMD3<Float>, SIMD3<Float>)] {
        outlineSegments(of: mesh).map { (SIMD3($0.ax, $0.ay, $0.az), SIMD3($0.bx, $0.by, $0.bz)) }
    }

    /// `outline(of:)` as the line segments that draw it. The viewport slices on the GPU instead
    /// (`section_outline_vertex`); this is the same cut on the CPU, for tests and snapshots of it.
    /// It reads the mesh through raw buffers with plain loops: a debug build checks every
    /// subscript and steps every range through generic code.
    func outlineSegments(of mesh: Mesh) -> [GPULineSeg] {
        guard let n = unitNormal, !mesh.indices.isEmpty else { return [] }
        let nf = n.float, of = origin.float
        var d = [Float](repeating: 0, count: mesh.positions.count)
        var out: [GPULineSeg] = []
        mesh.positions.withUnsafeBufferPointer { p in
            d.withUnsafeMutableBufferPointer { d in
                var i = 0
                while i < p.count { d[i] = simd_dot(p[i] - of, nf); i += 1 }
            }
            d.withUnsafeBufferPointer { d in
                mesh.indices.withUnsafeBufferPointer { idx in
                    func cross(_ i: Int, _ j: Int) -> SIMD3<Float> { p[i] + (p[j] - p[i]) * (d[i] / (d[i] - d[j])) }
                    func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { out.append(GPULineSeg(a, b, dist: 0, id: 0)) }
                    var t = 0
                    while t + 2 < idx.count {
                        let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
                        t += 3
                        let sa = d[a] > 0, sb = d[b] > 0, sc = d[c] > 0
                        if sa == sb && sb == sc { continue }
                        // Two of the three edges change sides.
                        if sa == sb { add(cross(a, c), cross(b, c)) }
                        else if sa == sc { add(cross(a, b), cross(c, b)) }
                        else { add(cross(b, a), cross(c, a)) }
                    }
                }
            }
        }
        return out
    }

    /// Hatch angle (radians from `axes.u`) for the cap of the `index`th body. Neighbouring parts in
    /// a drawing's section are told apart by hatching that runs the other way, then steeper or
    /// flatter, at least 30° from each other: 45°, 135°, 15°, 105°, 75°, 165°.
    static func hatchAngle(index: Int) -> Double {
        let degrees: [Double] = [45, 135, 15, 105, 75, 165]
        return degrees[index % degrees.count] * .pi / 180
    }

    /// A cap shade for the `index`th body, so nested bodies of one colour don't merge into one cap.
    static func capShade(index: Int) -> Float {
        let shades: [Float] = [1, 0.76, 1.2]
        return shades[index % shades.count]
    }
}
