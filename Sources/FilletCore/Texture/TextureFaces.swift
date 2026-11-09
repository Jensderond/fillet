import FilletKernel
import Foundation
import simd

/// Which faces a new texture covers when nothing is picked: the outer walls of the body, the
/// faces a knitted or dotted vase, cup or box shows from the side. The app and the MCP `texture`
/// tool both start from these, so they agree.
public enum TextureFaces {
    /// Faces that face sideways (not up or down, so never the bed face or a flat top) and outwards,
    /// away from the body's vertical centre line (so not the inside wall of a vase or cup).
    /// `mesh` is the body's display mesh when one is at hand; without it the shape is meshed
    /// coarsely. Empty when the body has no such faces.
    public static func outerSides(of shape: Shape, mesh: Mesh? = nil) -> [Int] {
        let count = shape.faceCount
        guard count > 0 else { return [] }
        let m: Mesh
        if let mesh, !mesh.indices.isEmpty {
            m = mesh
        } else {
            let size = shape.bounds.map { ($0.max - $0.min).length } ?? 10
            guard let made = try? shape.tessellate(linearDeflection: max(size / 200, 0.05), angularDeflection: 0.5)
            else { return [] }
            m = made
        }
        guard let box = m.bounds else { return [] }
        let center = SIMD2<Double>(Double(box.min.x + box.max.x) / 2, Double(box.min.y + box.max.y) / 2)

        // Per face, area-weighted: how much it faces up or down, and how much it faces outward.
        var area = [Double](repeating: 0, count: count)
        var vertical = [Double](repeating: 0, count: count)
        var outward = [Double](repeating: 0, count: count)
        let p = m.positions, n = m.normals
        for t in 0..<m.triangleCount {
            let face = Int(m.triangleFaces[t])
            guard face >= 0, face < count else { continue }
            let i0 = Int(m.indices[3 * t]), i1 = Int(m.indices[3 * t + 1]), i2 = Int(m.indices[3 * t + 2])
            let a = SIMD3<Double>(p[i0]), b = SIMD3<Double>(p[i1]), c = SIMD3<Double>(p[i2])
            let cross = simd_cross(b - a, c - a)
            let w = simd_length(cross) / 2
            guard w > 0 else { continue }
            var normal = n.count == p.count ? SIMD3<Double>(n[i0] + n[i1] + n[i2]) : cross
            let len = simd_length(normal)
            guard len > 1e-12 else { continue }
            normal /= len
            let mid = (a + b + c) / 3
            var away = SIMD2(mid.x, mid.y) - center
            let r = simd_length(away)
            away = r > 1e-9 ? away / r : .zero
            area[face] += w
            vertical[face] += w * abs(normal.z)
            outward[face] += w * simd_dot(SIMD2(normal.x, normal.y), away)
        }
        return (0..<count).filter { f in
            area[f] > 0 && vertical[f] / area[f] < 0.7 && outward[f] / area[f] > 0.15
        }
    }
}
