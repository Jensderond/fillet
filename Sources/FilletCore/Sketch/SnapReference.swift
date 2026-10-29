import FilletKernel
import Foundation

/// Existing geometry a sketch snaps to without it being part of the sketch: the edges of a body
/// that lie in the sketch's plane, in sketch coordinates. Like the face edges Fusion brings into
/// a sketch on a face, they give snap points (corners, midpoints, hole centres and quadrants),
/// alignment guides from those points and extension guides past straight edges. They are never
/// drawn, saved or turned into profiles.
public struct SnapReference: Hashable, Sendable {
    /// What the curves belong to (a body's id). Never a sketch shape's id, so shapes being moved
    /// never take it out of the targets.
    public var source: UUID
    /// Lines, arcs and circles lying in the plane.
    public var curves: [Segment2D]
    /// Other points in the plane: ends of edges that only touch it (a corner of an upright edge),
    /// or of edges in it that aren't lines or circles (ellipses, splines).
    public var points: [SIMD2<Double>]

    public init(source: UUID, curves: [Segment2D] = [], points: [SIMD2<Double>] = []) {
        self.source = source; self.curves = curves; self.points = points
    }

    /// The edges in `edges` lying in `plane`, within `tolerance` mm of it.
    public init(source: UUID, edges: [EdgeInfo], in plane: Plane, tolerance: Double = 1e-4) {
        func inPlane(_ p: Vec3) -> Bool { abs(plane.signedDistance(p)) <= tolerance }
        var curves: [Segment2D] = []
        var points: [SIMD2<Double>] = []
        for edge in edges {
            let startIn = inPlane(edge.start), endIn = inPlane(edge.end)
            guard startIn || endIn else { continue }
            let a = plane.project(edge.start), m = plane.project(edge.mid), b = plane.project(edge.end)
            // Three points of a line or circle in the plane put all of it there.
            if startIn, endIn, inPlane(edge.mid) {
                switch edge.curve {
                case .line where !a.isClose(to: b, tolerance: tolerance):
                    curves.append(.line(a, b))
                    continue
                case .circle where edge.radius > tolerance:
                    // A closed circle starts and ends at its seam; `mid` is halfway round, opposite it.
                    curves.append(a.isClose(to: b, tolerance: tolerance)
                        ? .circle(center: (a + m) / 2, radius: edge.radius)
                        : .arc(start: a, through: m, end: b))
                    continue
                default:
                    break
                }
            }
            if startIn { points.append(a) }
            if endIn { points.append(b) }
        }
        self.init(source: source, curves: curves, points: points)
    }

    public var isEmpty: Bool { curves.isEmpty && points.isEmpty }
}

extension Shape {
    /// This body's edges lying in `plane`, for a sketch there to snap to (see ``SnapReference``).
    /// Cheap for a body that doesn't reach the plane: its bounds are checked before its edges.
    public func snapReference(in plane: Plane, source: UUID, tolerance: Double = 1e-4) -> SnapReference {
        if let box = bounds {
            let (lo, hi) = (box.min, box.max)
            let distances = [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { z in
                plane.signedDistance(Vec3(x, y, z))
            } } }
            if distances.allSatisfy({ $0 > tolerance }) || distances.allSatisfy({ $0 < -tolerance }) {
                return SnapReference(source: source)
            }
        }
        return SnapReference(source: source, edges: edgeInfos, in: plane, tolerance: tolerance)
    }
}
