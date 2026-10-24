import CFilletKernel
import Foundation
import simd

/// The closed planar regions (profiles) enclosed by a set of sketch segments,
/// detected Fusion-style: every intersection splits curves, every minimal
/// enclosed area is a region (with holes), dangling curves are ignored.
public final class SketchRegions: @unchecked Sendable {
    public let plane: Plane
    let list: OpaquePointer

    public init(plane: Plane, segments: [Segment2D]) throws {
        self.plane = plane
        // Flatten B-spline points into one buffer that outlives the C call.
        var splinePoints = [Double]()
        var splineRanges = [Range<Int>?]()
        for s in segments {
            if case .bspline(let pts) = s {
                let start = splinePoints.count / 2
                for p in pts { splinePoints.append(p.x); splinePoints.append(p.y) }
                splineRanges.append(start..<(start + pts.count))
            } else {
                splineRanges.append(nil)
            }
        }
        let fkPlane = plane.fk
        let result: OpaquePointer? = splinePoints.withUnsafeBufferPointer { buffer in
            var fkSegments = [FKSegment]()
            fkSegments.reserveCapacity(segments.count)
            for (i, s) in segments.enumerated() {
                var seg = FKSegment()
                switch s {
                case .line(let a, let b):
                    seg.kind = FK_SEG_LINE
                    seg.p = (a.x, a.y, b.x, b.y, 0, 0)
                case .arc(let a, let m, let b):
                    seg.kind = FK_SEG_ARC
                    seg.p = (a.x, a.y, m.x, m.y, b.x, b.y)
                case .circle(let c, let r):
                    seg.kind = FK_SEG_CIRCLE
                    seg.p = (c.x, c.y, r, 0, 0, 0)
                case .bspline:
                    seg.kind = FK_SEG_BSPLINE
                    if let range = splineRanges[i], let base = buffer.baseAddress {
                        seg.points = base + 2 * range.lowerBound
                        seg.pointCount = Int32(range.count)
                    }
                }
                fkSegments.append(seg)
            }
            return fkSegments.withUnsafeBufferPointer { fk_sketch_regions(fkPlane, $0.baseAddress, Int32($0.count)) }
        }
        guard let result else { throw KernelError.last("Profile detection failed") }
        list = result
    }

    deinit { fk_list_free(list) }

    public var count: Int { Int(fk_list_count(list)) }

    /// Index of the region containing the sketch point, or nil.
    public func region(containing point: SIMD2<Double>) -> Int? {
        let i = fk_region_containing(list, plane.fk, point.x, point.y)
        return i >= 0 ? Int(i) : nil
    }

    /// The region as a planar face (normal = sketch plane normal).
    public func face(_ index: Int) throws -> Shape {
        try Shape.make(fk_list_get(list, Int32(clamping: index)), "Region")
    }

    /// Area of a region in mm² (0 for an invalid index).
    public func area(_ index: Int) -> Double {
        (try? face(index))?.surfaceArea ?? 0
    }

    /// A point well inside the region (far from its boundary), in sketch coordinates.
    /// Used to persist a region selection across recomputes. Falls back to the
    /// centre of the region's bounds if no interior point could be computed.
    public func interiorPoint(_ index: Int) -> SIMD2<Double> {
        guard let f = try? face(index) else { return .zero }
        var u = 0.0, v = 0.0
        if fk_region_interior_point(f.handle, plane.fk, &u, &v) { return SIMD2(u, v) }
        if let b = f.bounds { return plane.project((b.min + b.max) / 2) }
        return .zero
    }

    /// Fuses the selected regions into one extrudable profile (touching regions merge).
    public func profile(indices: [Int]) throws -> Shape {
        let idx = indices.map { Int32(clamping: $0) }
        return try Shape.make(
            idx.withUnsafeBufferPointer { fk_profile_from_regions(list, $0.baseAddress, Int32($0.count)) }, "Profile")
    }

    /// Triangulated region in sketch coordinates (three points per triangle, counter-clockwise),
    /// for drawing translucent fills. `deflection` defaults to 1/500 of the region size.
    public func fillTriangles(_ index: Int, deflection: Double? = nil) throws -> [SIMD2<Double>] {
        let f = try face(index)
        let mesh = try f.tessellate(linearDeflection: deflection ?? defaultDeflection(f), angularDeflection: 0.2)
        let pts = mesh.positions.map { plane.project(Vec3($0)) }
        var out = [SIMD2<Double>]()
        out.reserveCapacity(mesh.indices.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = pts[Int(mesh.indices[t])], b = pts[Int(mesh.indices[t + 1])], c = pts[Int(mesh.indices[t + 2])]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if cross >= 0 { out += [a, b, c] } else { out += [a, c, b] }
        }
        return out
    }

    /// Display triangulation of a region (alias of `fillTriangles`, empty on failure).
    public func outline(_ index: Int) -> [SIMD2<Double>] { (try? fillTriangles(index)) ?? [] }

    /// Boundary polylines of a region (outer loop and holes, one polyline per edge) in sketch coordinates.
    public func boundary(_ index: Int) -> [[SIMD2<Double>]] {
        guard let f = try? face(index), let mesh = try? f.tessellate(linearDeflection: defaultDeflection(f)) else {
            return []
        }
        return mesh.edges.filter { !$0.isEmpty }.map { $0.map { plane.project(Vec3($0)) } }
    }

    private func defaultDeflection(_ f: Shape) -> Double {
        guard let b = f.bounds else { return 0.01 }
        return max((b.max - b.min).length / 500, 0.001)
    }
}
