#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DebugAutomation {
    /// Press Pull, like Fusion's Q: a picked top face is pulled up by dragging its arrow, then
    /// driven by a parameter; picked edges start a fillet instead; with nothing picked, faces
    /// are picked in the viewport.
    static func pressPull(_ session: DesignSession) async {
        session.selection = []
        session.camera = session.camera.viewing(.iso)
        session.frameBodies()
        await settle(session)
        guard let body = session.model.bodies.first, let box = body.shape.bounds else { check(false, "a body to press pull"); return }
        let ray = Ray(origin: .zero, direction: .unitZ)
        check(session.unavailableReason(.pressPull) == nil, "Press Pull is available with a body")

        // Edges picked: Press Pull is a fillet.
        if let edge = body.shape.edgeInfos.indices.first(where: { body.shape.edgeInfos[$0].curve == .line }) {
            session.selection = [.edge(body.ref, edge)]
            session.startPressPull()
            await settle(session)
            check(session.editingKind == "fillet", "Press Pull with an edge picked starts a fillet (\(session.editingKind ?? "nothing"))")
            session.cancelEdit()
            await settle(session)
        }

        // Nothing picked (every sketch is used): a Press Pull waiting for faces, picked in the viewport.
        session.selection = []
        session.startPressPull()
        await settle(session)
        check(session.editingKind == "pressPull" && session.pickMode == .faces, "Press Pull with nothing picked waits for faces")
        let topPoint = Vec3(box.max.x - 10, box.min.y + 8, box.max.z)
        let pickHit = pick(session, at: topPoint)
        session.viewportDidTap(target: pickHit?.target, hit: pickHit, ray: ray, location: .zero, modifiers: [])
        await settle(session)
        if case .pressPull(let p)? = session.editingFeature?.kind {
            check(p.faces.count == 1 && session.viewportSummary.contains("1 face picked"), "a tap on the top face picks it (\(p.faces.count) faces)")
        } else {
            check(false, "a tap on the top face picks it")
        }
        session.cancelEdit()
        await settle(session)

        // The top face picked first, then Press Pull: its arrow drags it up.
        let before = session.model.bodies.first?.shape.volume ?? 0
        let hit = pick(session, at: topPoint)
        guard case .face(_, let top)? = hit?.target else { check(false, "the top face can be picked (\(String(describing: hit?.target)))"); return }
        let area = body.shape.faceInfo(top).area
        session.viewportDidTap(target: hit?.target, hit: hit, ray: ray, location: .zero, modifiers: [])
        check(session.selectedFaces.count == 1, "top face selected")
        session.startPressPull()
        await settle(session)
        let handle = session.makeScene().handles.first { $0.id == DesignSession.pressPullHandleID }
        check(handle.map { abs($0.direction.z - 1) < 1e-6 && abs($0.origin.z - box.max.z) < 1e-6 } ?? false,
              "an arrow points up from the top face (\(String(describing: handle?.origin)))")
        session.viewportHandleDragged(id: DesignSession.pressPullHandleID, value: 6)
        await settle(session)
        var volume = session.model.bodies.first?.shape.volume ?? 0
        check(session.model.bodies.count == 1 && abs(volume - before - area * 6) < 0.01,
              "dragging the arrow to 6 mm adds the top face × 6 (\(Int(volume - before)) ≈ \(Int(area * 6)) mm³)")
        check(session.makeScene().selection.contains { if case .face = $0 { true } else { false } },
              "the pulled face shows as picked")
        await snap(session, "11-press-pull-editing")
        session.commitEdit()
        await settle(session)

        // A parameter drives the distance; a negative value pushes the face in.
        guard let id = session.document.features.last(where: { if case .pressPull = $0.kind { true } else { false } })?.id else {
            check(false, "Press Pull 1 in the timeline"); return
        }
        session.perform("Add Parameter") { $0.parameters.append(Parameter(name: "lift", expression: -2)) }
        session.perform("Distance from lift") { doc in
            if let i = doc.index(of: id), case .pressPull(var p) = doc.features[i].kind {
                p.distance = "lift"
                doc.features[i].kind = .pressPull(p)
            }
        }
        await settle(session)
        volume = session.model.bodies.first?.shape.volume ?? 0
        check(session.model.error(for: id) == nil && abs(volume - before + area * 2) < 0.01,
              "lift = -2 pushes the top face in (\(Int(volume - before)) ≈ \(Int(-area * 2)) mm³)")
        await snap(session, "12-press-pushed")
    }
}
#endif
