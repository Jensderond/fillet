import FilletAgent
import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import simd

/// Product-shot renders with one fixed look, so a reference model and ours compare fairly: every
/// mesh is welded, given the same crease-aware normals, put on the bed (min z = 0, centred), drawn
/// in the same material colour under the same light, and framed by its bounding box.
@MainActor
enum LabRender {
    enum CameraPreset: String, CaseIterable {
        /// Three-quarter view from slightly above (the default product shot).
        case hero
        /// Straight at the front, slightly above.
        case front
        /// The standard isometric view.
        case iso
        /// Looking down.
        case top
        /// The middle of the front, close: a few stitches/dots across.
        case closeup
        /// Low grazing view along the side, showing relief.
        case grazing

        var angles: (yaw: Double, pitch: Double) {
            let d = Double.pi / 180
            return switch self {
            case .hero: (-35 * d, 22 * d)
            case .front: (0, 12 * d)
            case .iso: Camera.StandardView.iso.angles
            case .top: (0, 89 * d)
            case .closeup: (-20 * d, 12 * d)
            case .grazing: (-70 * d, 5 * d)
            }
        }
    }

    /// Default material: warm light grey PLA.
    static let defaultColor: UInt32 = 0xD9D4CB

    static func png(_ meshes: [Mesh], camera preset: CameraPreset, size: CGSize, color: UInt32 = defaultColor,
                    crease: Double = 60) throws -> Data {
        // One mesh on the bed, centred, with shared normals.
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for m in meshes { if let b = m.bounds { lo = simd_min(lo, b.min); hi = simd_max(hi, b.max) } }
        guard lo.x.isFinite else { throw MeshIOError.message("Nothing to render") }
        let shift = SIMD3<Float>(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z)
        var scene = ViewportScene()
        for (i, m) in meshes.enumerated() {
            let shaded = smoothShaded(m, offset: shift, creaseDegrees: crease)
            scene.bodies.append(SceneBody(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!, mesh: shaded,
                                          color: ViewportColor(hex: color), showsEdges: false, pickable: false))
        }
        scene.visualStyle = .shaded
        scene.showsGroundGrid = true
        scene.ellipticalShadows = true

        let size3 = SIMD3<Double>(hi - lo)
        let bounds = Bounds3(min: Vec3(-size3.x / 2, -size3.y / 2, 0), max: Vec3(size3.x / 2, size3.y / 2, size3.z))
        var camera = Camera()
        camera.projection = .perspective
        (camera.yaw, camera.pitch) = preset.angles
        let aspect = Double(size.width / size.height)
        switch preset {
        case .closeup:
            // A window a third of the part's height, on its front at mid height.
            let span = max(size3.z, max(size3.x, size3.y)) / 3
            let c = Vec3(0, -size3.y / 2, size3.z / 2)
            camera.fit(bounds: Bounds3(min: c - Vec3(span / 2, span / 2, span / 2), max: c + Vec3(span / 2, span / 2, span / 2)),
                       aspect: aspect, margin: 0.75)
        case .grazing:
            camera.fit(bounds: bounds, aspect: aspect, margin: 0.95)
        default:
            camera.fit(bounds: bounds, aspect: aspect, margin: 1.05)
        }
        return try DesignRendering.png(scene: scene, camera: camera, size: size, palette: DesignRendering.presentationPalette)
    }

    /// The mesh welded by position, moved by `offset`, with normals averaged over neighbouring
    /// triangles that meet at less than `creaseDegrees` (sharper edges stay sharp).
    static func smoothShaded(_ mesh: Mesh, offset: SIMD3<Float>, creaseDegrees: Double) -> Mesh {
        var index: [SIMD3<Float>: Int32] = [:]
        var points: [SIMD3<Float>] = []
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity(mesh.indices.count / 3)
        for t in 0..<(mesh.indices.count / 3) {
            var v = SIMD3<Int32>()
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[3 * t + k])]
                if let i = index[p] { v[k] = i } else {
                    v[k] = Int32(points.count)
                    index[p] = v[k]
                    points.append(p)
                }
            }
            if v.x != v.y, v.y != v.z, v.x != v.z { tris.append(v) }
        }
        let faceNormals = tris.map { t -> SIMD3<Float> in
            simd_cross(points[Int(t.y)] - points[Int(t.x)], points[Int(t.z)] - points[Int(t.x)])
        }
        // Triangles around each point.
        var start = [Int](repeating: 0, count: points.count + 1)
        for t in tris { start[Int(t.x) + 1] += 1; start[Int(t.y) + 1] += 1; start[Int(t.z) + 1] += 1 }
        for i in 0..<points.count { start[i + 1] += start[i] }
        var fill = start
        var around = [Int32](repeating: 0, count: start[points.count])
        for (i, t) in tris.enumerated() {
            for v in [t.x, t.y, t.z] { around[fill[Int(v)]] = Int32(i); fill[Int(v)] += 1 }
        }
        let cosLimit = Float(cos(creaseDegrees * .pi / 180))
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        positions.reserveCapacity(points.count * 2)
        var made: [UInt64: UInt32] = [:]
        for (i, t) in tris.enumerated() {
            let ni = simd_length(faceNormals[i]) > 0 ? simd_normalize(faceNormals[i]) : SIMD3<Float>(0, 0, 1)
            for v in [t.x, t.y, t.z] {
                var sum = SIMD3<Float>.zero
                var smallest = Int32.max
                for k in start[Int(v)]..<start[Int(v) + 1] {
                    let j = Int(around[k])
                    let nj = faceNormals[j]
                    let l = simd_length(nj)
                    guard l > 0, simd_dot(nj / l, ni) >= cosLimit else { continue }
                    sum += nj
                    smallest = min(smallest, Int32(j))
                }
                // Corners in the same smooth group share a vertex: key by point and the group's
                // lowest triangle.
                let key = UInt64(UInt32(bitPattern: v)) << 32 | UInt64(UInt32(bitPattern: smallest == Int32.max ? Int32(i) : smallest))
                if let existing = made[key] {
                    indices.append(existing)
                } else {
                    let n = UInt32(positions.count)
                    made[key] = n
                    positions.append(points[Int(v)] + offset)
                    normals.append(simd_length(sum) > 0 ? simd_normalize(sum) : ni)
                    indices.append(n)
                }
            }
        }
        return Mesh(positions: positions, normals: normals, indices: indices,
                    triangleFaces: [Int32](repeating: 0, count: indices.count / 3), edges: [])
    }
}
