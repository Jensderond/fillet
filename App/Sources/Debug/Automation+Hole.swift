#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DebugAutomation {
    /// Hole, driven like the UI: start with nothing picked, tap the plate's top face (the first
    /// tap picks the face and places a hole), tap again for a second hole, tap a hole to take it
    /// out, then switch to a counterbore through all and commit.
    static func holeScenario(_ session: DesignSession) async {
        guard let body = session.model.bodies.first, let box = body.shape.bounds else { check(false, "a body to drill"); return }
        let top = box.max.z
        let ray = Ray(origin: .zero, direction: .unitZ)
        func volume() -> Double { session.model.bodies.first?.shape.volume ?? 0 }
        func hole() -> Hole? { session.editingHole }
        func tap(at p: Vec3) -> PickHit? {
            let hit = pick(session, at: p)
            session.viewportDidTap(target: hit?.target, hit: hit, ray: ray, location: .zero, modifiers: [])
            return hit
        }

        session.selection = []
        check(session.unavailableReason(.hole) == nil, "Hole is available with a body")
        let before = volume()
        session.startHole()
        await settle(session)
        check(session.pickMode == .holePoints && session.choosingHoleFace && session.makeScene().pickableFaces != nil,
              "Hole with nothing picked waits for a flat face (only flat faces pickable)")
        await snap(session, "11a-hole-choose-face")

        // Clear of the pocket (which moved to x 42…64 with the widening) and the rounded corners.
        let first = Vec3(box.max.x - 10, box.min.y + 8, top), second = Vec3(box.max.x - 10, box.max.y - 8, top)
        let hit = tap(at: first)
        await settle(session)
        guard case .face? = hit?.target else { check(false, "a tap on the top face hits a face (\(String(describing: hit?.target)))"); return }
        check(hole()?.face != nil && hole()?.centers.count == 1, "the first tap picks the face and places a hole")
        let drilled: Double = .pi * 6.25 * (10 + 2.5 / tan(59 * .pi / 180) / 3)
        check(abs((before - volume()) - drilled) < 0.01, "a Ø5 × 10 mm drilled hole removes \(before - volume()) ≈ \(drilled) mm³")
        if let h = hole(), let (_, plane) = session.holeFace(h), let c = try? h.centers[0].evaluate(using: session.model.parameters.evaluator) {
            check(plane.point(c).distance(to: first) < 0.1, "the hole is where the face was tapped (\(plane.point(c)))")
        }

        _ = tap(at: second)
        await settle(session)
        check(hole()?.centers.count == 2 && session.holeMarkers().count == 4, "a second tap adds a hole, both with centre marks")
        check(session.viewportSummary.contains("2 holes placed"), "VoiceOver summary: \(session.viewportSummary)")
        await snap(session, "11b-hole-two")

        _ = tap(at: first)
        await settle(session)
        check(hole()?.centers.count == 1, "tapping a placed hole removes it")
        _ = tap(at: first)
        await settle(session)
        check(hole()?.centers.count == 2, "and tapping there again puts it back")

        session.updateEditing { f in
            if case .hole(var h) = f.kind { h.holeType = .counterbore; h.extent = .throughAll; f.kind = .hole(h) }
        }
        await settle(session)
        let h = session.model.bodies.first.map { _ in session.model.error(for: session.editing?.feature ?? UUID()) }
        check(h == .some(nil), "counterbore through all works (\(String(describing: h)))")
        let cbore: Double = 2 * .pi * (20.25 * 3 + 6.25 * (top - box.min.z - 3))
        check(abs((before - volume()) - cbore) < 0.01, "two Ø9 × 3 counterbored through holes remove \(before - volume()) ≈ \(cbore) mm³")
        await snap(session, "11c-hole-counterbore")

        session.commitEdit()
        await settle(session)
        check(session.document.features.last?.name == "Hole 1" && session.failedFeatures.isEmpty, "Hole 1 committed, nothing failed")
        checkUndoState(session, expectUndo: true, "Undo available after Hole 1")
        await snap(session, "11d-hole-done")
    }
}
#endif
