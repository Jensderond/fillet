import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import simd

/// The Hole tool: tap a flat face to drill, tap again to add more holes, tap a hole to take it
/// back out (like Fusion's Hole with several placement points).
extension DesignSession {
    /// New hole feature, on the selected flat face when there is one; otherwise the next tap on
    /// a flat face picks it (the first tap also places the first hole).
    func startHole() {
        var face: FaceRef?
        if let selected = sketchableFace { face = model.faceRef(body: selected.body, face: selected.index) }
        guard face != nil || !model.bodies.isEmpty else { message = "Create a body first"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Hole"), .hole(Hole(face: face))))
    }

    /// The hole being edited, if the open feature is one.
    var editingHole: Hole? {
        if case .hole(let h) = editingFeature?.kind { return h }
        return nil
    }

    /// The open hole has no face yet: the viewport offers only flat faces.
    var choosingHoleFace: Bool { editingHole.map { $0.face == nil } ?? false }

    /// The hole's face on the body before it (where taps are measured), and that face's plane.
    func holeFace(_ h: Hole) -> (index: Int, plane: Plane)? {
        guard let face = h.face, let before = model.bodyBefore(face.body)?.shape,
            let i = ReferenceResolver.resolve(face.signature, in: before.faceInfos), let plane = before.facePlane(i)
        else { return nil }
        return (i, plane)
    }

    /// A tap while the hole is open: removes the hole under it, or adds one where it hit the face.
    func holeTapped(target: PickTarget?, hit: PickHit?) {
        guard var h = editingHole, let hit, let bodyID = target?.bodyID else { return }
        let body = BodyRef(bodyID)
        let ev = model.parameters.evaluator

        if let face = h.face, face.body == body, let (_, plane) = holeFace(h) {
            // On a placed hole (its rim, wall or floor, or a finger's width around it): take it out.
            let p = plane.project(hit.point)
            let finger = camera.worldUnitsPerPoint(at: hit.point, viewSize: viewSize) * 22
            let reach = max(holeOuterRadius(h, using: ev), finger)
            let nearest = h.centers.indices.min { a, b in distance(h.centers[a], p, ev) < distance(h.centers[b], p, ev) }
            if let i = nearest, distance(h.centers[i], p, ev) <= reach {
                h.centers.remove(at: i)
                updateEditing { $0.kind = .hole(h) }
                return
            }
        }

        guard case .face(_, let index) = target, let ref = model.faceRefBefore(body: body, displayedFace: index),
            let before = model.bodyBefore(body)?.shape,
            let i = ReferenceResolver.resolve(ref.signature, in: before.faceInfos), let plane = before.facePlane(i)
        else {
            message = "Holes go into flat faces. \(Theme.Copy.pick) a flat face."
            return
        }
        let sameFace = h.face?.body == body && holeFace(h)?.index == i
        if !sameFace {
            // Before the first hole the face can still change; after it, holes stay on one face.
            guard h.centers.isEmpty else {
                message = "One Hole step drills one face. Choose Done, then start another Hole for this face."
                return
            }
            h.face = ref
        }
        // On a 0.1 mm grid, like dragging a handle, so the positions read cleanly in the inspector.
        let uv = holePlanePoint(hit.point, on: plane)
        h.centers.append(Point2Expr(Expr(uv.x), Expr(uv.y)))
        updateEditing { $0.kind = .hole(h) }
    }

    private func holePlanePoint(_ p: Vec3, on plane: Plane) -> SIMD2<Double> {
        let uv = plane.project(p)
        return SIMD2((uv.x * 10).rounded() / 10, (uv.y * 10).rounded() / 10)
    }

    private func distance(_ center: Point2Expr, _ p: SIMD2<Double>, _ ev: Evaluator) -> Double {
        (try? center.evaluate(using: ev)).map { simd_distance($0, p) } ?? .infinity
    }

    /// Radius of the hole at the face: the counterbore or countersink when there is one.
    private func holeOuterRadius(_ h: Hole, using ev: Evaluator) -> Double {
        let head: Expr? = switch h.holeType {
        case .simple: nil
        case .counterbore: h.counterboreDiameter
        case .countersink: h.countersinkDiameter
        }
        let d = [h.diameter, head].compactMap { $0.flatMap { try? ev.length($0) } }.max() ?? 0
        return d / 2
    }

    /// Centre marks over each hole of the open Hole step, like a drawing's: two lines crossing at
    /// the centre, reaching past the rim, so a hole reads as placed even before it's cut.
    func holeMarkers() -> [EdgeHighlight] {
        guard let h = editingHole, let (_, plane) = holeFace(h) else { return [] }
        let ev = model.parameters.evaluator
        let reach = max(holeOuterRadius(h, using: ev) * 1.4, 1)
        // Just above the face, so the marks aren't buried in it.
        let lift = plane.normal * 0.02
        return h.centers.compactMap { try? $0.evaluate(using: ev) }.flatMap { c -> [EdgeHighlight] in
            let o = plane.point(c) + lift
            return [EdgeHighlight(points: [o - plane.xDir * reach, o + plane.xDir * reach]),
                    EdgeHighlight(points: [o - plane.yDir * reach, o + plane.yDir * reach])]
        }
    }
}
