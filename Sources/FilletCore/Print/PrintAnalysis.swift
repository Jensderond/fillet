import FilletKernel
import Foundation
import simd

/// Filament materials for weight estimates.
public enum Material: String, Hashable, Sendable, Codable, CaseIterable {
    case pla, petg

    /// Density in g/cm³.
    public var density: Double {
        switch self {
        case .pla: 1.24
        case .petg: 1.27
        }
    }
}

/// A triangle of one of the analysed meshes.
public struct MeshTriangle: Hashable, Sendable {
    /// Index into the `meshes` array passed to ``PrintAnalysis/analyze(meshes:preset:overhangAngleDegrees:)``.
    public var mesh: Int
    /// Triangle index within that mesh.
    public var triangle: Int
}

/// Printability report for a set of meshes (all bodies of a design).
public struct PrintAnalysis: Sendable {
    /// Combined bounds of all meshes (mm); nil when there are no vertices.
    public var boundsMin: SIMD3<Double>?
    public var boundsMax: SIMD3<Double>?
    /// Bounding-box size (zero when empty).
    public var size: SIMD3<Double>
    /// The parts fit the build volume as oriented, or rotated 90° around Z.
    public var fitsOnBed: Bool
    /// They fit only when rotated 90° around Z.
    public var fitsOnlyRotated: Bool
    /// Downward-facing triangles steeper than the threshold, excluding those resting on the bed.
    public var overhangTriangles: [MeshTriangle]
    /// Total area of ``overhangTriangles`` in mm².
    public var overhangArea: Double
    /// Enclosed volume in mm³ (signed tetrahedra; meaningful for closed meshes).
    public var volume: Double
    /// Every mesh is closed and consistently oriented.
    public var isWatertight: Bool
    /// Edges used by only one triangle (holes), over all meshes.
    public var boundaryEdgeCount: Int
    /// Edges used by more than two triangles or twice in the same direction.
    public var nonManifoldEdgeCount: Int

    public var overhangCount: Int { overhangTriangles.count }

    /// Estimated filament weight in grams for a solid (100 % infill) print.
    public func grams(_ material: Material) -> Double { abs(volume) / 1000 * material.density }

    /// Analyses meshes for printing on `preset`.
    ///
    /// - Parameter overhangAngleDegrees: a downward-facing surface counts as an
    ///   overhang when it is tilted more than this from vertical (a vertical
    ///   wall is 0°, a flat ceiling 90°).
    public static func analyze(meshes: [Mesh], preset: PrinterPreset, overhangAngleDegrees: Double = 45) -> PrintAnalysis {
        var lo: SIMD3<Double>?
        var hi: SIMD3<Double>?
        for m in meshes {
            guard let b = m.bounds else { continue }
            let bmin = SIMD3<Double>(b.min), bmax = SIMD3<Double>(b.max)
            lo = lo.map { simd_min($0, bmin) } ?? bmin
            hi = hi.map { simd_max($0, bmax) } ?? bmax
        }
        var size = SIMD3<Double>.zero
        if let lo, let hi { size = hi - lo }
        let bed = preset.bedSize
        let eps = 1e-6
        let fitsAsIs = size.x <= bed.x + eps && size.y <= bed.y + eps && size.z <= bed.z + eps
        let fitsRotated = size.y <= bed.x + eps && size.x <= bed.y + eps && size.z <= bed.z + eps

        // Overhangs: overhang angle from vertical = asin(-n.z) for downward normals.
        let threshold = sin(max(0, min(90, overhangAngleDegrees)) * .pi / 180)
        let bedZ = lo?.z ?? 0
        let bedTolerance = 0.01
        var overhangs: [MeshTriangle] = []
        var overhangArea = 0.0
        var volume = 0.0
        var watertight = !meshes.isEmpty
        var boundary = 0
        var nonManifold = 0

        for (mi, mesh) in meshes.enumerated() {
            let pos = mesh.positions.map { SIMD3<Double>($0) }
            let triCount = mesh.indices.count / 3
            for t in 0..<triCount {
                guard let (a, b, c) = triangle(mesh, pos, t) else { continue }
                volume += simd_dot(a, simd_cross(b, c)) / 6
                let cross = simd_cross(b - a, c - a)
                let area2 = simd_length(cross)
                guard area2 > 1e-12 else { continue }
                let n = cross / area2
                guard -n.z > threshold + 1e-9 else { continue }
                if max(a.z, b.z, c.z) <= bedZ + bedTolerance { continue }  // resting on the bed
                overhangs.append(MeshTriangle(mesh: mi, triangle: t))
                overhangArea += area2 / 2
            }
            let topo = edgeTopology(mesh, pos)
            boundary += topo.boundary
            nonManifold += topo.nonManifold
            if topo.boundary > 0 || topo.nonManifold > 0 || triCount == 0 { watertight = false }
        }

        return PrintAnalysis(
            boundsMin: lo, boundsMax: hi, size: size, fitsOnBed: fitsAsIs || fitsRotated,
            fitsOnlyRotated: !fitsAsIs && fitsRotated, overhangTriangles: overhangs, overhangArea: overhangArea,
            volume: volume, isWatertight: watertight, boundaryEdgeCount: boundary, nonManifoldEdgeCount: nonManifold)
    }

    /// The three corners of triangle `t`, or nil when an index is out of range.
    static func triangle(_ mesh: Mesh, _ pos: [SIMD3<Double>], _ t: Int) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)? {
        let i0 = Int(mesh.indices[3 * t]), i1 = Int(mesh.indices[3 * t + 1]), i2 = Int(mesh.indices[3 * t + 2])
        guard i0 < pos.count, i1 < pos.count, i2 < pos.count else { return nil }
        return (pos[i0], pos[i1], pos[i2])
    }

    /// Counts boundary and non-manifold edges after welding vertices within 1e-4 mm.
    /// A closed, consistently oriented mesh uses every undirected edge exactly
    /// twice, once in each direction.
    static func edgeTopology(_ mesh: Mesh, _ pos: [SIMD3<Double>]) -> (boundary: Int, nonManifold: Int) {
        var welder = MeshWelder(tolerance: 1e-4)
        let remap = pos.map { welder.index(of: $0) }
        struct EdgeKey: Hashable { var a: Int, b: Int }
        var uses: [EdgeKey: (forward: Int, backward: Int)] = [:]
        for t in 0..<(mesh.indices.count / 3) {
            let raw = (0..<3).map { Int(mesh.indices[3 * t + $0]) }
            guard raw.allSatisfy({ $0 < remap.count }) else { continue }
            let v = raw.map { remap[$0] }
            guard v[0] != v[1], v[1] != v[2], v[0] != v[2] else { continue }  // degenerate after welding
            for k in 0..<3 {
                let a = v[k], b = v[(k + 1) % 3]
                let key = EdgeKey(a: min(a, b), b: max(a, b))
                var u = uses[key] ?? (0, 0)
                if a < b { u.forward += 1 } else { u.backward += 1 }
                uses[key] = u
            }
        }
        var boundary = 0, nonManifold = 0
        for u in uses.values {
            if u.forward == 1 && u.backward == 1 { continue }
            if u.forward + u.backward == 1 { boundary += 1 } else { nonManifold += 1 }
        }
        return (boundary, nonManifold)
    }
}
