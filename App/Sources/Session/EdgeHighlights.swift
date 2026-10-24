import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DesignSession {
    /// Picked edges, drawn thick and haloed over the model: the selection, plus, while a
    /// fillet or chamfer is open, the sharp edges it replaces (dashed, from the body before it).
    /// Those are the edges the evaluator resolved the feature's references to, not a second
    /// resolution here, so after a parametric change they are exactly the edges it rounds.
    func edgeHighlights() -> [EdgeHighlight] {
        var result: [EdgeHighlight] = []
        for case .edge(let body, let index) in selection {
            guard let edges = model.meshes[body]?.edges, index < edges.count, edges[index].count >= 2 else { continue }
            result.append(EdgeHighlight(points: edges[index].map { Vec3(Double($0.x), Double($0.y), Double($0.z)) }))
        }
        switch editingFeature?.kind {
        case .fillet, .chamfer:
            guard let id = editing?.feature else { break }
            for edge in model.resolvedEdges[id] ?? [] {
                result.append(EdgeHighlight(points: edge.polyline, dashed: true))
            }
        default:
            break
        }
        return result
    }
}

extension EdgeInfo {
    /// A drawable approximation from the edge's start, middle and end: straight for lines, an
    /// arc (or full circle) through the three points for circles, a bent line otherwise.
    var polyline: [Vec3] {
        switch curve {
        case .line:
            return [start, end]
        case .circle where radius > 1e-6:
            return Self.circleArc(start: start, mid: mid, end: end, tangentAtMid: tangentAtMid, radius: radius) ?? [start, mid, end]
        default:
            return [start, mid, end]
        }
    }

    private static func circleArc(start: Vec3, mid: Vec3, end: Vec3, tangentAtMid: Vec3, radius: Double) -> [Vec3]? {
        let closed = start.distance(to: end) < 1e-6
        // The circle's plane contains the tangent at the middle and the chord back to the start.
        let toStart = start - mid
        let normal = tangentAtMid.cross(toStart).normalized
        guard normal.length > 0.5 else { return nil }
        // Centre: from the middle point, towards the inside of the curve.
        let inward = normal.cross(tangentAtMid).normalized
        let centre = inward.dot(toStart) >= 0 ? mid + inward * radius : mid - inward * radius
        let u = (start - centre).normalized, v = normal.cross(u)
        func angle(_ p: Vec3) -> Double {
            let d = p - centre
            var a = atan2(d.dot(v), d.dot(u))
            if a < 0 { a += 2 * .pi }
            return a
        }
        var sweep = closed ? 2 * .pi : angle(end)
        // Go the way that passes through the middle point.
        if !closed, angle(mid) > sweep { sweep -= 2 * .pi }
        let steps = max(8, Int(abs(sweep) / (.pi / 24)))
        return (0...steps).map { k in
            let a = sweep * Double(k) / Double(steps)
            return centre + (u * cos(a) + v * sin(a)) * radius
        }
    }
}
