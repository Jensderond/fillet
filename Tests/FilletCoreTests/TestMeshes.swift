import FilletKernel
import Foundation

/// Hand-built meshes for print analysis and export tests.
enum TestMeshes {
    static func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> Mesh {
        Mesh(
            positions: positions, normals: Array(repeating: .zero, count: positions.count), indices: indices,
            triangleFaces: Array(repeating: 0, count: indices.count / 3), edges: [])
    }

    /// Indexed, outward-oriented box with 8 shared vertices and 12 triangles.
    static func box(_ lo: SIMD3<Float> = .zero, size s: SIMD3<Float>) -> Mesh {
        let p: [SIMD3<Float>] = [
            lo, lo + SIMD3(s.x, 0, 0), lo + SIMD3(s.x, s.y, 0), lo + SIMD3(0, s.y, 0),
            lo + SIMD3(0, 0, s.z), lo + SIMD3(s.x, 0, s.z), lo + s, lo + SIMD3(0, s.y, s.z),
        ]
        let i: [UInt32] = [
            0, 2, 1, 0, 3, 2,  // bottom
            4, 5, 6, 4, 6, 7,  // top
            0, 1, 5, 0, 5, 4,  // front (-y)
            2, 3, 7, 2, 7, 6,  // back (+y)
            0, 4, 7, 0, 7, 3,  // left (-x)
            1, 2, 6, 1, 6, 5,  // right (+x)
        ]
        return mesh(p, i)
    }

    static func cube(_ lo: SIMD3<Float> = .zero, size: Float) -> Mesh { box(lo, size: SIMD3(repeating: size)) }

    /// Same box as a triangle soup (3 unshared vertices per triangle), like
    /// per-face kernel tessellation.
    static func soup(_ m: Mesh) -> Mesh {
        mesh(m.indices.map { m.positions[Int($0)] }, (0..<UInt32(m.indices.count)).map { $0 })
    }

    /// Upside-down square pyramid: apex at the origin, base square of half-size
    /// `a` at height `h`.
    static func invertedPyramid(a: Float, h: Float) -> Mesh {
        let p: [SIMD3<Float>] = [.zero, SIMD3(-a, -a, h), SIMD3(a, -a, h), SIMD3(a, a, h), SIMD3(-a, a, h)]
        let i: [UInt32] = [1, 2, 3, 1, 3, 4, 0, 2, 1, 0, 3, 2, 0, 4, 3, 0, 1, 4]
        return mesh(p, i)
    }
}
