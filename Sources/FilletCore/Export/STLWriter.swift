import FilletKernel
import Foundation
import simd

/// Writes binary STL (84-byte header + 50 bytes per triangle, little endian, mm).
public enum STLWriter {
    /// All triangles of all meshes in one binary STL. Normals are computed per
    /// triangle from the vertex winding (zero for degenerate triangles).
    public static func binary(meshes: [Mesh]) -> Data {
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for m in meshes {
            for t in 0..<(m.indices.count / 3) {
                let i = (Int(m.indices[3 * t]), Int(m.indices[3 * t + 1]), Int(m.indices[3 * t + 2]))
                guard i.0 < m.positions.count, i.1 < m.positions.count, i.2 < m.positions.count else { continue }
                triangles.append((m.positions[i.0], m.positions[i.1], m.positions[i.2]))
            }
        }

        var data = Data(capacity: 84 + 50 * triangles.count)
        var header = Data("Fillet binary STL (mm)".utf8)
        header.append(Data(count: 80 - header.count))
        data.append(header)
        data.append(le32: UInt32(clamping: triangles.count))
        for (a, b, c) in triangles {
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            let n = len > 0 ? cross / len : .zero
            for v in [n, a, b, c] {
                data.append(leFloat: v.x)
                data.append(leFloat: v.y)
                data.append(leFloat: v.z)
            }
            data.append(le16: 0)
        }
        return data
    }
}
