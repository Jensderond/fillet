import Foundation
import simd

/// Merges mesh vertices that lie within a tolerance of each other, using a
/// spatial hash so it runs in roughly linear time.
struct MeshWelder {
    let tolerance: Double
    private(set) var points: [SIMD3<Double>] = []
    private var grid: [SIMD3<Int64>: [Int]] = [:]

    init(tolerance: Double) { self.tolerance = max(tolerance, 0) }

    /// Index of the welded vertex for `p`, adding it when no existing vertex is close enough.
    mutating func index(of p: SIMD3<Double>) -> Int {
        let cell = cellOf(p)
        if tolerance > 0 {
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let key = cell &+ SIMD3(Int64(dx), Int64(dy), Int64(dz))
                        if let candidates = grid[key] {
                            for i in candidates where simd_distance(points[i], p) <= tolerance { return i }
                        }
                    }
                }
            }
        } else if let candidates = grid[cell], let i = candidates.first(where: { points[$0] == p }) {
            return i
        }
        points.append(p)
        grid[cell, default: []].append(points.count - 1)
        return points.count - 1
    }

    private func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int64> {
        let size = tolerance > 0 ? tolerance : 1e-3
        let q = (p / size).rounded(.down)
        let limit = Double(Int64.max / 4)
        return SIMD3(
            Int64(max(-limit, min(limit, q.x))), Int64(max(-limit, min(limit, q.y))),
            Int64(max(-limit, min(limit, q.z))))
    }
}
