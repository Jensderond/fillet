import FilletKernel
import simd

extension Mesh {
    /// The same triangles with normals split at sharp creases, for display: each corner's normal
    /// averages only the triangles around it that meet its own at less than `degrees`.
    ///
    /// A textured mesh's normals are otherwise averaged over every triangle of the B-rep face,
    /// so a sharp step in the relief (a flat disc's straight foot) gets one normal halfway
    /// between the side and the wall, and the wall triangles next to it shade as a ragged light
    /// fringe. Positions, triangle order and ``triangleFaces`` are unchanged, so picking and
    /// edges work as before; only vertices along creases are duplicated.
    public func creaseShaded(degrees: Double = 60) -> Mesh {
        let triangleCount = indices.count / 3
        guard triangleCount > 0 else { return self }
        let vertexCount = positions.count
        var faceNormals = [SIMD3<Float>](repeating: .zero, count: triangleCount)
        for t in 0..<triangleCount {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
            faceNormals[t] = simd_cross(b - a, c - a)
        }
        // Triangles around each vertex.
        var start = [Int](repeating: 0, count: vertexCount + 1)
        for i in indices { start[Int(i) + 1] += 1 }
        for v in 0..<vertexCount { start[v + 1] += start[v] }
        var fill = start
        var around = [Int32](repeating: 0, count: indices.count)
        for t in 0..<triangleCount {
            for k in 0..<3 {
                let v = Int(indices[3 * t + k])
                around[fill[v]] = Int32(t)
                fill[v] += 1
            }
        }
        let cosLimit = Float(cos(degrees * .pi / 180))
        var outPositions: [SIMD3<Float>] = [], outNormals: [SIMD3<Float>] = []
        outPositions.reserveCapacity(vertexCount + vertexCount / 8)
        outNormals.reserveCapacity(vertexCount + vertexCount / 8)
        var outIndices = [UInt32](repeating: 0, count: indices.count)
        // Corners whose triangles fall in the same smooth group share a vertex: keyed by the
        // vertex and the group's lowest triangle. The first group of a vertex keeps its slot.
        var firstGroup = [Int32](repeating: -1, count: vertexCount)
        var firstIndex = [UInt32](repeating: 0, count: vertexCount)
        var extra: [UInt64: UInt32] = [:]
        for t in 0..<triangleCount {
            let nt = faceNormals[t]
            let lt = simd_length(nt)
            let unit = lt > 0 ? nt / lt : SIMD3<Float>(0, 0, 1)
            for k in 0..<3 {
                let v = Int(indices[3 * t + k])
                var sum = SIMD3<Float>.zero
                var lowest = Int32(t)
                for s in start[v]..<start[v + 1] {
                    let j = Int(around[s])
                    let nj = faceNormals[j]
                    let l = simd_length(nj)
                    guard l > 0, simd_dot(nj / l, unit) >= cosLimit else { continue }
                    sum += nj
                    lowest = min(lowest, Int32(j))
                }
                let normal = simd_length(sum) > 0 ? simd_normalize(sum) : unit
                let slot: UInt32
                if firstGroup[v] < 0 {
                    firstGroup[v] = lowest
                    slot = UInt32(outPositions.count)
                    firstIndex[v] = slot
                    outPositions.append(positions[v]); outNormals.append(normal)
                } else if firstGroup[v] == lowest {
                    slot = firstIndex[v]
                } else {
                    let key = UInt64(UInt32(v)) << 32 | UInt64(UInt32(bitPattern: lowest))
                    if let hit = extra[key] {
                        slot = hit
                    } else {
                        slot = UInt32(outPositions.count)
                        extra[key] = slot
                        outPositions.append(positions[v]); outNormals.append(normal)
                    }
                }
                outIndices[3 * t + k] = slot
            }
        }
        return Mesh(positions: outPositions, normals: outNormals, indices: outIndices,
                    triangleFaces: triangleFaces, edges: edges, brepVertices: brepVertices)
    }
}
