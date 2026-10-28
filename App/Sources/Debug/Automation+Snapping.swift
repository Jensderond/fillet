#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import simd

extension DebugAutomation {
    /// Snapping and alignment guides, on their own (`FILLET_SCENARIO=snapping`). Existing geometry:
    /// a 40 mm base line, an upright at its end, a slanted line crossing the base and a point.
    /// Tool events go through the session with real camera rays and touch precision, each a few
    /// screen points off its target, so the same on-screen offset must snap at every zoom.
    ///
    /// At three zooms and after a pan: horizontal and vertical guides from a vertex, the base's
    /// midpoint, the crossing, the slanted line's extension, two guides at once, and nothing 40 pt
    /// away. Then a triangle with a vertex on the base's midpoint, a rectangle corner under a
    /// vertex, and a check that guides end with the gesture and never reach the document or undo.
    /// Snapshots: `snap-<zoom>-<case>`, `snap-triangle`, `snap-rectangle`.
    static func snappingScenario(_ session: DesignSession) async {
        session.startSketch(on: .xy)
        await settle(session)
        guard let sketchID = session.sketchEditor?.sketch else { check(false, "snapping: a sketch to draw in"); return }
        func shapes() -> [SketchShape] {
            if case .sketch(let s)? = session.document.feature(sketchID)?.kind { return s.shapes }
            return []
        }
        session.sketchEditor?.engine.setTool(.line)
        for (a, b) in [(SIMD2(0.0, 0.0), SIMD2(40.0, 0.0)), (SIMD2(40.0, 0.0), SIMD2(40.0, 30.0)), (SIMD2(5.0, -10.0), SIMD2(15.0, 20.0))] {
            tap(session, a)
            tap(session, b)
            _ = session.sketchEditor?.engine.finish()
        }
        session.sketchEditor?.engine.setTool(.point)
        tap(session, SIMD2(-25, 45))
        await settle(session)
        check(shapes().count == 4, "snapping: three lines and a point drawn (\(shapes().count))")
        let crossing = SIMD2(5 + 10.0 / 3, 0)

        let views: [(name: String, distance: Double, target: Vec3)] = [
            ("near", 70, Vec3(15, 15, 0)), ("mid", 160, Vec3(15, 15, 0)), ("far", 320, Vec3(15, 15, 0)),
            ("panned", 160, Vec3(-30, 40, 0)),
        ]
        for view in views {
            session.camera.distance = view.distance
            session.camera.target = view.target
            await settle(session)
            let mmPerPoint = session.camera.worldUnitsPerPoint(at: .zero, viewSize: session.viewSize)
            log("snapping \(view.name): \(String(format: "%.3f", mmPerPoint)) mm per point")
            session.sketchEditor?.engine.setTool(.line)

            // Horizontal from the upright's top, dragging left from it.
            await gesture(session, from: SIMD2(40, 30), to: SIMD2(-8, 30), nudge: CGSize(width: 3, height: -6), "snap-\(view.name)-horizontal") { e in
                check(e.snap == .horizontal && e.cursor?.y == 30 && e.points == [SIMD2(40, 30)],
                      "snapping \(view.name): the end lines up level with the start (\(e.snap), \(String(describing: e.cursor)))")
                check(e.guides.first?.from == SIMD2(40, 30), "snapping \(view.name): a horizontal guide from the vertex")
            }
            // Vertical under the base's start.
            await gesture(session, from: SIMD2(-15, -20), to: SIMD2(0, 10), nudge: CGSize(width: 6, height: 2), "snap-\(view.name)-vertical") { e in
                check(e.snap == .vertical && e.cursor?.x == 0, "snapping \(view.name): vertical with (0, 0) (\(e.snap), \(String(describing: e.cursor)))")
            }
            // Midpoint, crossing and extension.
            await gesture(session, from: SIMD2(20, -25), to: SIMD2(20, 0), nudge: CGSize(width: 5, height: 5), "snap-\(view.name)-midpoint") { e in
                check(e.snap == .point(.midpoint) && e.cursor == SIMD2(20, 0), "snapping \(view.name): the base's midpoint (\(e.snap))")
                check(e.markers == [.target(SIMD2(20, 0), .midpoint)], "snapping \(view.name): a midpoint marker")
            }
            await gesture(session, from: SIMD2(-15, -25), to: crossing, nudge: CGSize(width: -5, height: 4), "snap-\(view.name)-intersection") { e in
                check(e.snap == .point(.intersection) && (e.cursor.map { simd_distance($0, crossing) < 1e-9 } ?? false),
                      "snapping \(view.name): the crossing, exactly (\(e.snap), \(String(describing: e.cursor)))")
            }
            await gesture(session, from: SIMD2(-15, 60), to: SIMD2(25, 50), nudge: CGSize(width: 6, height: 2), "snap-\(view.name)-extension") { e in
                let onLine = e.cursor.map { c in abs((c.x - 15) * 30 - (c.y - 20) * 10) < 1e-6 } ?? false
                check(e.snap == .extension && onLine, "snapping \(view.name): on the slanted line's extension (\(e.snap), \(String(describing: e.cursor)))")
            }
            // Level with the upright's top and under the base's start at once.
            await gesture(session, from: SIMD2(-20, -20), to: SIMD2(0, 30), nudge: CGSize(width: 5, height: 5), "snap-\(view.name)-two-guides") { e in
                check(e.snap == .aligned && e.cursor == SIMD2(0, 30) && e.guides.count == 2,
                      "snapping \(view.name): two guides fix (0, 30) (\(e.snap), \(String(describing: e.cursor)))")
            }
            // Far from everything: the grid.
            await gesture(session, from: SIMD2(-20, -20), to: SIMD2(-35, -40), nudge: .zero, nil) { e in
                check(e.guides.isEmpty && e.markers.isEmpty && e.snap == .grid, "snapping \(view.name): in empty space, only the grid (\(e.snap))")
            }
        }

        // Apple Pencil is more precise than a finger, so its snap radius is smaller (6 pt × 1.5
        // against 10 pt × 1.5): 12 pt off the midpoint, a finger snaps and a hovering Pencil doesn't.
        session.camera.distance = 160
        session.camera.target = Vec3(15, 15, 0)
        await settle(session)
        session.sketchEditor?.engine.setTool(.point)
        for (pointer, snaps) in [(PointerKind.pencil, false), (.touch, true)] {
            guard let s = screenPoint(session, SIMD2(20, 0), nudge: CGSize(width: 8.5, height: 8.5)) else { continue }
            session.viewportToolHover(ViewportToolEvent(ray: session.camera.ray(at: s, viewSize: session.viewSize), location: s, pointer: pointer))
            let snapped = session.sketchEditor?.engine.snap == .point(.midpoint)
            check(snapped == snaps, "snapping: 12 pt off the midpoint, \(pointer) \(snaps ? "snaps" : "doesn't snap")")
            session.sketchEditor?.engine.cancel()
        }
        if let s = screenPoint(session, SIMD2(20, 0), nudge: CGSize(width: 4, height: 4)) {
            session.viewportToolHover(ViewportToolEvent(ray: session.camera.ray(at: s, viewSize: session.viewSize), location: s, pointer: .pencil))
            check(session.sketchEditor?.engine.cursor == SIMD2(20, 0), "snapping: a hovering Pencil 6 pt off the midpoint snaps")
            session.sketchEditor?.engine.cancel()
        }

        // A triangle with a vertex on the base's midpoint, at the middle zoom.
        session.camera.distance = 160
        session.camera.target = Vec3(15, 0, 0)
        await settle(session)
        session.sketchEditor?.engine.setTool(.line)
        let before = shapes().count
        let undoBefore = session.undoManager?.undoActionName
        // A settle after each tap: separate events, so separate undo steps, as a finger's taps are.
        for (p, nudge) in [(SIMD2(20.0, 0.0), CGSize(width: 4, height: -5)), (SIMD2(30.0, -25.0), .zero),
                           (SIMD2(10.0, -25.0), .zero), (SIMD2(20.0, 0.0), CGSize(width: -5, height: 3))]
        {
            touchTap(session, p, nudge: nudge)
            await settle(session)
        }
        let triangle = shapes().dropFirst(before).compactMap { s -> (SIMD2<Double>, SIMD2<Double>)? in
            guard case .line(let a, let b) = s.kind, let pa = try? a.evaluate(using: .empty), let pb = try? b.evaluate(using: .empty) else { return nil }
            return (pa, pb)
        }
        check(triangle.count == 3 && triangle.first?.0 == SIMD2(20, 0) && triangle.last?.1 == SIMD2(20, 0),
              "snapping: the triangle starts and closes on the base's midpoint (\(triangle))")
        check(session.sketchEditor?.engine.isIdle == true && session.sketchEditor?.engine.guides.isEmpty == true,
              "snapping: closing the triangle ends the line and its guides")
        await snap(session, "snap-triangle")
        if let undo = session.undoManager {
            check(undo.undoActionName != undoBefore || undo.canUndo, "snapping: the triangle's lines are undo steps")
            for _ in 0..<3 { undo.undo() }
            await settle(session)
            check(shapes().count == before, "snapping: three undos take the triangle back (\(shapes().count))")
            for _ in 0..<3 { undo.redo() }
            await settle(session)
            check(shapes().count == before + 3, "snapping: redo brings it back")
        }

        // A rectangle's corner under the point at (-25, 45): vertical guide, not one to its own first corner.
        session.camera.target = Vec3(-30, 25, 0)
        await settle(session)
        session.sketchEditor?.engine.setTool(.rectangle)
        touchTap(session, SIMD2(-45, 10), nudge: .zero)
        await gesture(session, from: nil, to: SIMD2(-25, 25), nudge: CGSize(width: 5, height: 0), "snap-rectangle") { e in
            check(e.snap == .vertical && e.cursor?.x == -25, "snapping: the rectangle's corner lines up under the point (\(e.snap))")
        }
        touchTap(session, SIMD2(-25, 25), nudge: CGSize(width: 5, height: 0))
        await settle(session)
        if case .rectangle(.corner, let position, let width, _, _)? = shapes().last?.kind {
            check(position == Point2Expr(-45, 10) && width == 20, "snapping: rectangle 20 mm wide from (-45, 10) (\(position), \(width))")
        } else {
            check(false, "snapping: a rectangle was drawn")
        }

        // Guides are feedback only: showing them changes neither what saves nor the undo stack.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let saved = try? encoder.encode(session.document)
        let undoName = session.undoManager?.undoActionName
        session.sketchEditor?.engine.setTool(.line)
        touchTap(session, SIMD2(-25, 0), nudge: .zero)
        session.viewportToolHover(touchEvent(session, screenPoint(session, SIMD2(-25, 30), nudge: CGSize(width: 4, height: 0)) ?? .zero))
        let scene = session.makeScene().sketch
        check(scene?.guides.isEmpty == false && scene?.markers.isEmpty == false, "snapping: hovering shows a guide")
        check((try? encoder.encode(session.document)) == saved, "snapping: the saved document is the same with guides showing")
        check(session.undoManager?.undoActionName == undoName, "snapping: guides add no undo step")
        session.viewportToolCancelled()
        session.sketchEditor?.engine.setTool(.select)
        check(session.makeScene().sketch?.guides.isEmpty == true, "snapping: no guides with Select")
    }

    // MARK: Touch input

    /// The screen point a few points (`nudge`) off a sketch point.
    private static func screenPoint(_ session: DesignSession, _ p: SIMD2<Double>, nudge: CGSize) -> CGPoint? {
        guard let sketch = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch] }),
            let s = session.camera.project(sketch.plane.point(p), viewSize: session.viewSize)
        else { return nil }
        return CGPoint(x: s.x + nudge.width, y: s.y + nudge.height)
    }

    private static func touchEvent(_ session: DesignSession, _ screen: CGPoint) -> ViewportToolEvent {
        ViewportToolEvent(ray: session.camera.ray(at: screen, viewSize: session.viewSize), location: screen, pointer: .touch)
    }

    /// A finger tap, `nudge` points off a sketch point.
    private static func touchTap(_ session: DesignSession, _ p: SIMD2<Double>, nudge: CGSize) {
        guard let s = screenPoint(session, p, nudge: nudge) else { return }
        session.viewportToolBegan(touchEvent(session, s))
        session.viewportToolEnded(touchEvent(session, s))
    }

    /// A finger pressed on `from` (unless a shape is already under way) dragged in steps to
    /// `nudge` points off `to`; `check` sees the engine there, then the gesture is cancelled so
    /// nothing is drawn. Guides must be gone once it's cancelled.
    private static func gesture(_ session: DesignSession, from: SIMD2<Double>?, to: SIMD2<Double>, nudge: CGSize, _ name: String?,
                                check inspect: (SketchToolEngine) -> Void) async
    {
        guard let end = screenPoint(session, to, nudge: nudge) else { check(false, "snapping: \(to) on screen"); return }
        let start = from.flatMap { screenPoint(session, $0, nudge: .zero) } ?? end
        if from != nil { session.viewportToolBegan(touchEvent(session, start)) }
        for i in 1...12 {
            let t = CGFloat(i) / 12
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if from != nil { session.viewportToolMoved(touchEvent(session, p)) } else { session.viewportToolHover(touchEvent(session, p)) }
        }
        if let engine = session.sketchEditor?.engine { inspect(engine) }
        if let name {
            await settle(session)
            await snap(session, name)
        }
        if from != nil {
            session.viewportToolCancelled()
            check(session.sketchEditor?.engine.guides.isEmpty == true && session.makeScene().sketch?.guides.isEmpty == true,
                  "snapping: guides go with the gesture")
        }
    }
}
#endif
