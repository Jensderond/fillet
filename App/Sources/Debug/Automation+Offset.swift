#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

extension DebugAutomation {
    /// Sketch Offset, driven like the UI: pick a rectangle edge (the whole rectangle comes along),
    /// the pointer sets the distance and side, an inward offset that collapses says why, a
    /// selected circle is offset straight away, an L of two lines offsets as one chain with an arc
    /// around its corner, a typed negative distance goes inward, and the ring between the
    /// rectangle and its offset extrudes.
    static func sketchOffset(_ session: DesignSession) async {
        check(SketchTool.offset.shortcut == "o" && SketchTool.slot.shortcut == "s", "Offset is O, Slot moved to S")
        session.startSketch(on: .xy)
        await settle(session)
        guard let sketchID = session.sketchEditor?.sketch else { check(false, "offset: a sketch to draw in"); return }
        func shapes() -> [SketchShape] {
            if case .sketch(let s)? = session.document.feature(sketchID)?.kind { return s.shapes }
            return []
        }
        // Clear of the plate: a 60 × 30 rectangle, a Ø16 circle and an L of two lines.
        session.sketchEditor?.engine.setTool(.rectangle)
        tap(session, SIMD2(0, -70))
        tap(session, SIMD2(60, -40))
        session.sketchEditor?.engine.setTool(.circle)
        tap(session, SIMD2(90, -55))
        tap(session, SIMD2(98, -55))
        session.sketchEditor?.engine.setTool(.line)
        tap(session, SIMD2(0, -100))
        tap(session, SIMD2(30, -100))
        tap(session, SIMD2(30, -85))
        _ = session.sketchEditor?.engine.finish()
        let drawn = shapes()
        check(drawn.count == 4, "offset: drew a rectangle, a circle and two lines (\(drawn.count) shapes)")
        let rectangle = drawn.first { if case .rectangle = $0.kind { true } else { false } }?.id

        // Pick: hovering an edge previews the chain a tap takes.
        session.sketchEditor?.engine.setTool(.offset)
        check(session.sketchEditor?.engine.hint(verb: "Tap") == "Tap a curve or shape to offset", "offset: picking hint")
        hover(session, SIMD2(30, -70.2))
        check(session.sketchEditor?.engine.preview().isEmpty == false, "offset: the rectangle under the pointer previews")
        tap(session, SIMD2(30, -70.2))
        check(session.sketchEditor?.selectedShapes == Set(rectangle.map { [$0] } ?? []), "offset: a tap on an edge picks the whole rectangle")

        // Outward 5 mm with the pointer below the bottom edge.
        hover(session, SIMD2(30, -75.2))
        await settle(session)
        await snap(session, "offset-1-outward")
        check(session.sketchEditor?.engine.dimensionFields().first?.value == 5, "offset: the pointer 5.2 mm out sets 5 mm (grid)")
        let regionsBefore = session.model.sketches[sketchID]?.regions?.count ?? 0
        tap(session, SIMD2(30, -75.2))
        await settle(session)
        let ring = shapes().last
        if case .polyline(let vertices, true)? = ring?.kind {
            check(vertices.count == 8 && vertices.filter({ $0.bulge != nil }).count == 4, "offset: outward rectangle has 4 sides and 4 corner arcs")
        } else {
            check(false, "offset: outward rectangle is a closed polyline (\(String(describing: ring?.kind)))")
        }
        check(session.model.sketches[sketchID]?.regions?.count == regionsBefore + 1, "offset: the ring is a new profile")
        if let undo = session.undoManager { check(undo.undoActionName == "Offset", "offset: one undo step named Offset (\(undo.undoActionName))") }

        // Inward: 15 mm collapses the 30 mm high rectangle and says so; 10 mm works and stays a rectangle.
        tap(session, SIMD2(0.2, -55))
        hover(session, SIMD2(30, -55))
        await settle(session)
        let blocker = session.sketchEditor?.engine.blocker
        check(blocker != nil && session.sketchEditor?.engine.preview().isEmpty == true, "offset: 15 mm in collapses: \(blocker ?? "no message")")
        await snap(session, "offset-2-collapse")
        hover(session, SIMD2(30, -60))
        tap(session, SIMD2(30, -60))
        await settle(session)
        if case .rectangle(.center, _, let w, let h, _)? = shapes().last?.kind {
            check(w == 40 && h == 10, "offset: 10 mm in gives a 40 × 10 rectangle (\(w) × \(h))")
        } else {
            check(false, "offset: inward offset of a rectangle is a rectangle")
        }

        // A selected circle is picked when Offset starts.
        let circle = drawn.first { if case .circle = $0.kind { true } else { false } }?.id
        session.sketchEditor?.engine.setTool(.select)
        session.sketchEditor?.selectedShapes = Set(circle.map { [$0] } ?? [])
        session.sketchEditor?.engine.setTool(.offset)
        check(session.sketchEditor?.engine.offset.pending == circle.map { [$0] }, "offset: starts with the selected circle")
        hover(session, SIMD2(90, -45))
        tap(session, SIMD2(90, -45))
        await settle(session)
        check(shapes().last?.kind == .circle(center: Point2Expr(90, -55), diameter: 20), "offset: concentric circle 2 mm out (\(String(describing: shapes().last?.kind)))")

        // The L: picking one line takes both; outside the corner gets an arc.
        tap(session, SIMD2(15, -100))
        check(session.sketchEditor?.selectedShapes.count == 2, "offset: one line of the L picks the chain")
        hover(session, SIMD2(15, -103))
        await settle(session)
        await snap(session, "offset-3-chain")
        tap(session, SIMD2(15, -103))
        await settle(session)
        if case .polyline(let vertices, false)? = shapes().last?.kind {
            check(vertices.count == 4 && vertices.filter({ $0.bulge != nil }).count == 1, "offset: the L's offset rounds its corner")
        } else {
            check(false, "offset: the L offsets as one open polyline (\(String(describing: shapes().last?.kind)))")
        }

        // Typed: -3 on the circle goes inward, whichever side the pointer is on.
        tap(session, SIMD2(98, -55))
        hover(session, SIMD2(110, -55))
        _ = session.handleDimensionKey(.text("-3"))
        _ = session.handleDimensionKey(.returnKey)
        await settle(session)
        check(shapes().last?.kind == .circle(center: Point2Expr(90, -55), diameter: 10), "offset: typed -3 gives Ø10 (\(String(describing: shapes().last?.kind)))")

        // The ring between the rectangle and its offset extrudes.
        session.finishSketch()
        await settle(session)
        let bodies = session.model.bodies.count
        session.startExtrude()
        await settle(session)
        if let regions = session.model.sketches[sketchID]?.regions, let i = regions.region(containing: SIMD2(30, -72.5)) {
            if case .extrude(let e) = session.editingFeature?.kind, !e.regions.isEmpty {
                session.updateEditing { f in if case .extrude(var e) = f.kind { e.regions = []; f.kind = .extrude(e) } }
            }
            session.viewportDidTap(target: .region(i), hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        }
        session.updateEditing { f in if case .extrude(var e) = f.kind { e.distance = 4; e.operation = .newBody; f.kind = .extrude(e) } }
        await settle(session)
        session.commitEdit()
        await settle(session)
        let ringBody = session.model.bodies.count == bodies + 1 ? session.model.bodies.last : nil
        let expected = (70.0 * 40 - 4 * 25 + Double.pi * 25 - 60 * 30) * 4
        check(abs((ringBody?.shape.volume ?? 0) - expected) < 0.1, "offset: the ring extrudes (\(ringBody?.shape.volume ?? 0) ≈ \(expected) mm³)")
        await snap(session, "offset-4-ring")
    }
}
#endif
