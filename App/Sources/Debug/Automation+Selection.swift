#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DebugAutomation {
    /// Selection, on its own (`FILLET_SCENARIO=selection`): an 80 × 40 × 12 plate with its
    /// vertical edges rounded (r 8), so its top outline is one tangent chain of four lines and four
    /// arcs. Taps go through the editor's viewport picker at real screen points, then to the
    /// session's tap handlers (as the viewport's gestures call them); boxes go through the
    /// viewport controller, which draws them and picks what they hold.
    ///
    /// Checks: one tap in Fillet picks the whole chain; Tangent chain off picks single edges; a
    /// double tap picks a face's loop; click replaces, Shift toggles, touch adds, empty clears;
    /// window and crossing boxes for edges and faces, outside and inside a step; none of it is an
    /// undo step. Snapshots: `s01`…`s09`.
    static func selectionScenario(_ session: DesignSession) async {
        // Sketch 1 → Extrude 1 → Fillet 1 (the four vertical edges, r 8).
        session.startSketch(on: .xy)
        await settle(session)
        session.sketchEditor?.engine.setTool(.rectangle)
        tap(session, SIMD2(0, 0))
        tap(session, SIMD2(80, 40))
        await settle(session)
        session.startExtrude()
        session.updateEditing { f in if case .extrude(var e) = f.kind { e.distance = 12; f.kind = .extrude(e) } }
        await settle(session)
        session.commitEdit()
        await settle(session)
        guard let plate = session.model.bodies.first else { check(false, "the plate exists"); return }
        session.selection = plate.shape.edgeInfos.indices.filter { abs(plate.shape.edgeInfos[$0].tangentAtMid.z) > 0.99 }
            .map { .edge(plate.ref, $0) }
        session.startEdgeFeature(fillet: true)
        session.updateEditing { f in if case .fillet(var e) = f.kind { e.size = 8; f.kind = .fillet(e) } }
        await settle(session)
        session.commitEdit()
        await settle(session)
        check(session.failedFeatures.isEmpty && session.model.bodies.count == 1, "rounded plate built")
        lookAtPlate(session)
        await settle(session)
        await snap(session, "s01-rounded-plate")
        let undoBefore = session.canUndo
        let document = session.document

        // Fillet with nothing selected; one tap on the top front edge picks the whole outline.
        session.selection = []
        session.startEdgeFeature(fillet: true)
        await settle(session)
        check(session.pickMode == .edges, "Fillet picks edges")
        if case .fillet(let f)? = session.editingFeature?.kind { check(f.tangentChain, "a new fillet has Tangent chain on") }
        tapAt(session, Vec3(40, 0, 12), pointer: .touch)
        session.updateEditing { f in if case .fillet(var e) = f.kind { e.size = 2; f.kind = .fillet(e) } }
        await settle(session)
        let filletID = session.editing?.feature ?? UUID()
        let chain = session.model.resolvedEdges[filletID] ?? []
        check(chain.count == 8 && chain.allSatisfy { abs($0.mid.z - 12) < 1e-6 } && chain.filter { $0.curve == .circle }.count == 4,
              "one tap picks the top outline as one chain: \(chain.count) edges, \(chain.filter { $0.curve == .circle }.count) arcs")
        check(session.viewportSummary.contains("8 edges picked"), "VoiceOver summary counts the chain: \(session.viewportSummary)")
        check(session.model.error(for: filletID) == nil, "the chain fillet works")
        await snap(session, "s02-chain-one-tap")

        // Tangent chain off: the chain becomes its 8 edges; a tap then drops just one.
        session.setTangentChain(false)
        await settle(session)
        if case .fillet(let f)? = session.editingFeature?.kind {
            check(!f.tangentChain && f.edges.count == 8, "chain off keeps the 8 edges as single picks (\(f.edges.count))")
        }
        // The edge is rounded in the live result now: tap the rounding's lower rim, on the front.
        tapAt(session, Vec3(40, 0, 10), pointer: .touch)
        await settle(session)
        check(session.model.resolvedEdges[filletID]?.count == 7, "with the chain off a tap drops one edge (\(session.model.resolvedEdges[filletID]?.count ?? 0))")
        await snap(session, "s03-chain-off")
        session.setTangentChain(true)
        session.cancelEdit()
        await settle(session)

        // A double tap on the top front edge, on the front face's side: the front face's loop.
        session.selection = []
        doubleTapAt(session, Vec3(40, 0, 12), faceSide: Vec3(40, 0, 10), pointer: .touch)
        await settle(session)
        let loop = session.selectedEdges
        let loopZ = Set(loop.compactMap { plateShape(session)?.edgeInfoIfValid($0.1).map { ($0.mid.z * 10).rounded() / 10 } })
        check(loop.count == 4 && loopZ.contains(12) && loopZ.contains(0),
              "a double tap picks the front face's loop: \(loop.count) edges at heights \(loopZ.sorted())")
        await snap(session, "s04-loop")
        // Select more ▸ Tangent chain grows the last edge picked into its chain.
        session.selection = loop.suffix(1).map { .edge($0.0, $0.1) }
        session.selectTangentChain()
        check(session.selectedEdges.count >= 1, "Tangent chain from the selection: \(session.selectedEdges.count) edges")

        // Click replaces, Shift-click toggles, a touch adds, a click on nothing clears.
        session.selection = []
        tapAt(session, Vec3(40, 0, 12), pointer: .mouse)
        tapAt(session, Vec3(80, 20, 12), pointer: .mouse)
        check(session.selection.count == 1, "a click replaces the selection (\(session.selection.count))")
        tapAt(session, Vec3(40, 0, 12), pointer: .mouse, modifiers: .shift)
        check(session.selection.count == 2, "Shift-click adds (\(session.selection.count))")
        tapAt(session, Vec3(40, 0, 12), pointer: .mouse, modifiers: .command)
        check(session.selection.count == 1, "⌘-click on a picked edge drops it (\(session.selection.count))")
        tapAt(session, Vec3(40, 0, 12), pointer: .touch)
        check(session.selection.count == 2, "a tap adds (\(session.selection.count))")
        session.viewportDidTap(target: nil, hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero,
                               modifiers: .shift, pointer: .mouse)
        check(session.selection.count == 2, "Shift-click on nothing keeps the selection")
        session.viewportDidTap(target: nil, hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero,
                               modifiers: [], pointer: .mouse)
        check(session.selection.isEmpty, "a click on nothing clears it")

        // Box select, edges: a window around the whole plate takes every edge in view.
        session.boxSelecting = true
        session.boxPicks = .edges
        await settle(session)
        check(markers["box-select-bar", default: 0] == 1, "the box bar shows")
        guard let controller, let around = screenBounds(session, plate: true) else { check(false, "plate on screen"); return }
        let topLeft = CGPoint(x: around.minX - 24, y: around.minY - 24), bottomRight = CGPoint(x: around.maxX + 24, y: around.maxY + 24)
        controller.beginBox(at: topLeft, pointer: .touch, modifiers: [])
        controller.dragBox(to: CGPoint(x: bottomRight.x - 1, y: bottomRight.y - 1))
        await settle(session)
        await snap(session, "s05-box-window-dragging")
        controller.endBox(at: bottomRight)
        await settle(session)
        let windowed = session.selectedEdges
        let topCount = windowed.filter { plateShape(session)?.edgeInfoIfValid($0.1).map { abs($0.mid.z - 12) < 1e-6 } == true }.count
        check(topCount == 8 && windowed.count < (plateShape(session)?.edgeCount ?? 0),
              "a window around the plate takes the visible edges, the whole top outline among them: \(windowed.count) of \(plateShape(session)?.edgeCount ?? 0)")
        check(!session.boxSelecting, "a finger box ends Box select, so one finger orbits again")
        await snap(session, "s06-box-window-result")
        // A mouse box leaves it on (the Mac orbits with the right button).
        session.boxSelecting = true
        controller.beginBox(at: topLeft, pointer: .mouse, modifiers: [])
        controller.endBox(at: bottomRight)
        check(session.boxSelecting && session.selectedEdges.count == windowed.count, "a mouse box keeps Box select on")
        await settle(session)

        // A crossing box (right to left) over just the right half of the front: whatever it touches.
        session.selection = []
        guard let front = screenPoint(session, Vec3(56, 0, 6)), let right = screenPoint(session, Vec3(80, 20, 6)) else { return }
        let a = CGPoint(x: max(front.x, right.x) + 10, y: min(front.y, right.y) - 50)
        let b = CGPoint(x: front.x, y: max(front.y, right.y) + 50)
        controller.beginBox(at: a, pointer: .touch, modifiers: [])
        controller.dragBox(to: CGPoint(x: b.x + 1, y: b.y))
        await settle(session)
        await snap(session, "s07-box-crossing-dragging")
        controller.endBox(at: b)
        await settle(session)
        let crossed = session.selectedEdges.count
        // The same rectangle as a window: only what is wholly inside it.
        session.selection = []
        controller.beginBox(at: CGPoint(x: b.x, y: a.y), pointer: .touch, modifiers: [])
        controller.endBox(at: CGPoint(x: a.x, y: b.y))
        let inside = session.selectedEdges.count
        check(crossed > inside, "crossing takes more than the same window: \(crossed) touching, \(inside) inside")

        // Faces: a crossing box over the top takes the top (and what it touches in view), never the bottom.
        session.selection = []
        session.boxPicks = .faces
        await settle(session)
        if let top = screenPoint(session, Vec3(40, 20, 12)) {
            controller.beginBox(at: CGPoint(x: top.x + 15, y: top.y - 10), pointer: .touch, modifiers: [])
            controller.endBox(at: CGPoint(x: top.x - 15, y: top.y + 10))
        }
        let faces = session.selectedFaces.compactMap { plateShape(session)?.faceInfoIfValid($0.1) }
        check(faces.count == 1 && faces.first.map { $0.normal.z > 0.99 } == true, "a small crossing box on the top takes the top face (\(faces.count))")

        // In Fillet, a box adds edges to the step (and doesn't touch the selection).
        session.selection = []
        session.startEdgeFeature(fillet: true)
        await settle(session)
        check(session.boxFilter == .edges, "in Fillet a box picks edges")
        controller.beginBox(at: a, pointer: .touch, modifiers: [])
        controller.endBox(at: b)
        session.updateEditing { f in if case .fillet(var e) = f.kind { e.size = 1; f.kind = .fillet(e) } }
        await settle(session)
        let boxed = session.model.resolvedEdges[session.editing?.feature ?? UUID()]?.count ?? 0
        check(boxed >= 8, "a crossing box in Fillet picks the chains it touches (\(boxed) edges)")
        await snap(session, "s08-box-in-fillet")
        session.cancelEdit()
        await settle(session)

        // Escape leaves box select; Box select off, a one-finger drag orbits again.
        session.boxSelecting = true
        session.escape()
        check(!session.boxSelecting, "Esc turns Box select off")
        check(session.document == document && session.canUndo == undoBefore, "selecting, chains, loops and boxes made no undo step")

        // The inspector's chain toggle, for the snapshot: Fillet on the plate with one chain picked.
        session.selection = []
        session.startEdgeFeature(fillet: true)
        await settle(session)
        tapAt(session, Vec3(40, 0, 12), pointer: .touch)
        await settle(session)
        await snap(session, "s09-inspector-chain")
        session.commitEdit()
        await settle(session)
        check(session.failedFeatures.isEmpty, "the chain fillet commits")
    }

    private static func plateShape(_ session: DesignSession) -> Shape? { session.model.bodies.first?.shape }

    /// An iso view framing the plate.
    private static func lookAtPlate(_ session: DesignSession) {
        var c = session.camera
        c.setView(.iso)
        session.camera = c
        controller?.fitAll(animated: false)
    }

    private static func screenPoint(_ session: DesignSession, _ world: Vec3) -> CGPoint? {
        // The camera and size the viewport picks with (they run ahead of the session's).
        guard let controller else { return session.camera.project(world, viewSize: session.viewSize) }
        return controller.liveCamera.project(world, viewSize: controller.viewSize)
    }

    /// The plate's bounding box corners on screen.
    private static func screenBounds(_ session: DesignSession, plate: Bool) -> CGRect? {
        guard let b = session.model.bodies.first?.shape.bounds else { return nil }
        let corners = [b.min.x, b.max.x].flatMap { x in [b.min.y, b.max.y].flatMap { y in [b.min.z, b.max.z].map { Vec3(x, y, $0) } } }
        let points = corners.compactMap { screenPoint(session, $0) }
        guard let first = points.first else { return nil }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// A tap at a world point: picked by the editor's viewport, then handled like the gesture's tap.
    private static func tapAt(_ session: DesignSession, _ world: Vec3, pointer: PointerKind, modifiers: ViewportModifiers = []) {
        guard let controller, let screen = screenPoint(session, world) else { return }
        let hit = controller.pick(at: screen, pointer: pointer)
        session.viewportDidTap(target: hit?.target, hit: hit, ray: controller.liveCamera.ray(at: screen, viewSize: controller.viewSize),
                               location: screen, modifiers: modifiers, pointer: pointer)
    }

    /// A double tap at a world point; `faceSide` is a point on the face the finger is on.
    private static func doubleTapAt(_ session: DesignSession, _ world: Vec3, faceSide: Vec3, pointer: PointerKind) {
        tapAt(session, world, pointer: pointer)
        guard let controller, let screen = screenPoint(session, world), let side = screenPoint(session, faceSide) else { return }
        // A finger lands a little to the face's side of the edge.
        let toward = CGPoint(x: side.x - screen.x, y: side.y - screen.y)
        let length = max(hypot(toward.x, toward.y), 1)
        let p = CGPoint(x: screen.x + toward.x / length * 4, y: screen.y + toward.y / length * 4)
        let hit = controller.pick(at: p, pointer: pointer)
        let face = controller.pick(at: p, pointer: pointer, filter: .faces)?.target
        _ = session.viewportDidDoubleTap(target: hit?.target, face: face, location: p, modifiers: [], pointer: pointer)
    }
}
#endif
