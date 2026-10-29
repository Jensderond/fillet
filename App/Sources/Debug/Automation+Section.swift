#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DebugAutomation {
    /// Section view, on its own (`FILLET_SCENARIO=section`): a 60 × 30 × 12 plate with a Ø14 hole.
    /// The plane is picked through the editor's viewport picker at real screen points; the arrow
    /// and a tilt grip are dragged through the viewport controller as a pointer drags them (a
    /// finger on iPad); typed values go through the session as the panel and the pill send them.
    ///
    /// Checks: the tool offers the origin planes and flat faces; a tap on XZ cuts there with the
    /// cut-away side facing the camera; dragging the arrow slides it with a live readout; the cut
    /// stays put while orbiting; flip keeps the plane and swaps the side; typed offsets and tilts;
    /// a grip tilts about the handles' centre; Escape puts the handles away and the cut stays;
    /// the tool turns it off and back on at the same plane; a flat face is a plane too; other
    /// tools take over the handles but keep the cut; none of it touches the document or undo.
    /// Snapshots: `sec01`…`sec10`.
    static func sectionScenario(_ session: DesignSession) async {
        session.startSketch(on: .xy)
        await settle(session)
        session.sketchEditor?.engine.setTool(.rectangle)
        tap(session, SIMD2(0, 0))
        tap(session, SIMD2(60, 30))
        session.sketchEditor?.engine.setTool(.circle)
        tap(session, SIMD2(15, 15))
        tap(session, SIMD2(22, 15))
        await settle(session)
        session.startExtrude()
        await settle(session)
        if let sketch = session.model.sketches.values.first, let i = sketch.regions?.region(containing: SIMD2(45, 20)) {
            session.viewportDidTap(target: .region(i), hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        }
        session.updateEditing { f in if case .extrude(var e) = f.kind { e.distance = 12; f.kind = .extrude(e) } }
        await settle(session)
        session.commitEdit()
        await settle(session)
        guard let plate = session.model.bodies.first else { check(false, "section: the plate exists"); return }
        check(abs(plate.shape.volume - (60 * 30 * 12 - Double.pi * 49 * 12)) < 0.01, "section: a plate with a hole")
        session.selection = []
        session.camera = session.camera.viewing(.iso)
        session.frameBodies()
        await settle(session)
        await snap(session, "sec00-plate")
        let documentBefore = session.document
        let undoBefore = (session.canUndo, session.canRedo)
        func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= tol } ?? false }
        func near(_ a: Vec3?, _ b: Vec3, _ tol: Double = 1e-6) -> Bool { a.map { $0.distance(to: b) <= tol } ?? false }
        func handle(_ id: String) -> Handle? { session.makeScene().handles.first { $0.id == id } }
        #if os(iOS)
        let pointer = PointerKind.touch
        #else
        let pointer = PointerKind.mouse
        #endif

        // The tool with nothing picked offers the origin planes and the flat faces.
        session.toggleSection()
        await settle(session)
        var scene = session.makeScene()
        check(session.pickMode == .sectionPlane && session.pickFilter == [.faces, .referencePlanes] && scene.referencePlanes.count == 3
              && scene.pickableFaces?[plate.ref.feature]?.isEmpty == false && scene.section == nil,
              "Section with nothing picked offers the 3 origin planes and the flat faces")
        check(markers["section-plane-bar", default: 0] == 1, "the section plane bar shows once")
        // Above the plate, on the front plane: nothing else is in front of it there.
        let xzHit = pick(session, at: Vec3(30, 0, 40))
        check(xzHit?.target == .referencePlane("xz"), "a tap above the plate on the front plane picks XZ (\(String(describing: xzHit?.target)))")
        session.viewportHoverChanged(target: xzHit?.target)
        await settle(session)
        await snap(session, "sec01-choose-plane")
        session.viewportDidTap(target: xzHit?.target, hit: xzHit, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        await settle(session)
        scene = session.makeScene()
        // The iso camera looks from -Y: that side is cut away, so the inside faces the viewer.
        check(session.section?.reference.name == "XZ plane" && near(scene.section?.normal, Vec3(0, -1, 0))
              && session.pickMode == .section && session.pickFilter.isEmpty && scene.handles.count == 3,
              "picking XZ cuts along it, the cut-away side facing the camera, with an arrow and two grips")
        // The plate stands on XZ's far side (y 0…30): cut at y = 0 nothing would show, so it starts through its middle.
        check(near(session.section?.center, Vec3(30, 15, 6)) && near(session.section?.offset, -15) && session.sectionOffsetLabel == "−15 mm",
              "a plane that misses the plate cuts through its middle (\(String(describing: session.section?.center)), \(session.sectionOffsetLabel))")
        check(frames["section-panel"] != nil, "the section panel shows")
        check(frames["section-pill-value"] != nil && frames["section-flip"] != nil, "the value pill and the flip button are on the canvas")
        await snap(session, "sec02-xz-picked")

        // Drag the arrow like a pointer: grabbed mid-shaft, moved 5 mm back along it, deeper into the plate.
        if let controller, let arrow = handle(DesignSession.sectionOffsetHandleID) {
            let cam = controller.liveCamera, size = controller.viewSize
            let wpp = cam.worldUnitsPerPoint(at: arrow.tip, viewSize: size)
            let grabWorld = arrow.tip + arrow.direction * (HandleMetrics.totalLength / 2 * wpp)
            if let grab = cam.project(grabWorld, viewSize: size), controller.beginHandleDrag(at: grab, pointer: pointer) {
                for step in 1...5 {
                    if let p = cam.project(grabWorld - arrow.direction * Double(step), viewSize: size) { controller.dragHandle(to: p) }
                }
                await settle(session)
                check(session.sectionDrag == DesignSession.sectionOffsetHandleID && session.sectionOffsetLabel == "−20 mm",
                      "mid-drag the pill reads the live offset (\(session.sectionOffsetLabel))")
                await snap(session, "sec03-dragging")
                controller.endHandleDrag()
            } else {
                check(false, "the arrow can be grabbed on screen")
            }
        }
        await settle(session)
        scene = session.makeScene()
        check(near(session.section?.offset, -20, 0.051) && near(scene.section?.origin.y, 20, 0.051) && session.sectionDrag == nil,
              "dragging the arrow 5 mm further into the plate cuts at y = \(scene.section?.origin.y ?? -1)")

        // Orbiting leaves the cut where it is in the world, with its handles.
        let planeBefore = scene.section
        let iso = session.camera
        var turned = session.camera
        turned.yaw += 0.7
        turned.pitch -= 0.2
        session.camera = turned
        await settle(session)
        scene = session.makeScene()
        check(scene.section == planeBefore && near(handle(DesignSession.sectionOffsetHandleID)?.tip, planeBefore?.origin ?? .zero),
              "the section stays put while orbiting")
        await snap(session, "sec04-orbited")
        session.camera = iso
        await settle(session)

        // Flip: the plane stays, the other side is cut away, the readout changes sign.
        session.flipSection()
        scene = session.makeScene()
        check(near(scene.section?.normal, Vec3(0, 1, 0)) && near(scene.section?.origin, planeBefore?.origin ?? .zero)
              && near(session.section?.offset, 20, 0.051) && session.sectionOffsetLabel == "20 mm",
              "flip cuts away the other side of the same plane (\(session.sectionOffsetLabel))")
        await settle(session)
        await snap(session, "sec05-flipped")
        session.flipSection()

        // Typed: what the pill and the panel's field send, an expression evaluated to a length.
        if let typed = try? session.model.parameters.evaluator.length("-(3 + 4.5)") { session.setSectionOffset(typed) }
        check(near(session.makeScene().section?.origin.y, 7.5, 1e-9), "a typed offset of -(3 + 4.5) cuts at y = 7.5")
        await settle(session)  // the viewport picks the handles it last drew

        // Tilt with the grip about Z (out along X), 30° round its arc, as a pointer drags it.
        if let controller, let grip = handle(DesignSession.sectionTiltVHandleID), case .rotation(let axis) = grip.kind {
            let cam = controller.liveCamera, size = controller.viewSize
            let radius = HandleMetrics.gripRadius * cam.worldUnitsPerPoint(at: grip.origin, viewSize: size)
            func screen(_ degrees: Double) -> CGPoint? {
                let a = degrees * .pi / 180
                return cam.project(grip.origin + (grip.direction * cos(a) + axis.cross(grip.direction) * sin(a)) * radius, viewSize: size)
            }
            if let start = screen(0), controller.beginHandleDrag(at: start, pointer: pointer) {
                for degrees in stride(from: 3.0, through: 30, by: 3) { if let p = screen(degrees) { controller.dragHandle(to: p) } }
                await settle(session)
                check(markers["section-angle-tag", default: 0] == 1, "the grip's angle shows beside it while it turns")
                await snap(session, "sec06-tilting")
                controller.endHandleDrag()
            } else {
                check(false, "the tilt grip can be grabbed on screen")
            }
        }
        await settle(session)
        scene = session.makeScene()
        let tilted = Vec3(sin(30 * Double.pi / 180), -cos(30 * Double.pi / 180), 0)
        check(near(session.section?.tiltV, 30) && near(scene.section?.normal, tilted, 1e-9) && near(scene.section?.origin, Vec3(30, 7.5, 6), 1e-9),
              "the grip tilts the cut 30° about Z through the handles (\(session.section?.tiltV ?? 0)°)")
        check(near(session.section?.offset, -7.5, 1e-9), "tilting about the handles leaves the offset reading as it was (\(session.sectionOffsetLabel))")
        // Dragged now, the arrow slides the tilted cut along its own normal and the offset follows.
        session.viewportHandleDragged(id: DesignSession.sectionOffsetHandleID, value: (session.section?.alongNormal ?? 0) - 2)
        session.viewportHandleDragEnded(id: DesignSession.sectionOffsetHandleID, value: 0)
        check(near(session.section?.offset, -7.5 - 2 * cos(30 * Double.pi / 180), 0.051) && near(session.makeScene().section?.normal, tilted, 1e-9),
              "the arrow slides the tilted cut along its normal (\(session.sectionOffsetLabel))")
        session.setSectionOffset(-7.5)
        check(near(session.section?.offset, -7.5, 1e-9) && near(session.makeScene().section?.normal, tilted, 1e-9), "a typed offset on a tilted cut")
        session.setSectionTilt(u: 20)
        check(near(session.makeScene().section.map { $0.normal.z }, -cos(30 * Double.pi / 180) * sin(20 * Double.pi / 180), 1e-9),
              "a typed tilt about X tips the cut forward")
        await snap(session, "sec07-tilted")
        session.resetSectionTilt()
        check(near(session.makeScene().section?.normal, Vec3(0, -1, 0), 1e-12) && near(session.section?.offset, -7.5, 1e-9),
              "Untilt turns it back, at the same offset")

        // Escape puts the handles away; the cut stays and the pill says so.
        session.escape()
        await settle(session)
        scene = session.makeScene()
        check(session.pickMode == .idle && scene.section != nil && scene.handles.isEmpty && markers["section-pill", default: 0] == 1,
              "Escape puts the handles away and the cut stays")
        await snap(session, "sec08-on")
        // The tool turns it off, and back on at the same plane.
        session.toggleSection()
        await settle(session)
        check(session.makeScene().section == nil && session.section != nil && session.message?.text.hasPrefix("Section view off") == true,
              "the tool turns the section off and keeps the plane")
        session.toggleSection()
        await settle(session)
        check(session.pickMode == .section && near(session.makeScene().section?.origin.y, 7.5, 1e-9), "and back on at the same plane, handles up")

        // A flat face is a plane too: the top face, cut right on it, then 6 mm down through the hole.
        session.changeSectionPlane()
        await settle(session)
        check(session.pickMode == .sectionPlane && session.makeScene().section == nil, "Change shows the whole model to pick from")
        let topHit = pick(session, at: Vec3(45, 20, 12))
        guard case .face? = topHit?.target else { check(false, "the top face can be picked (\(String(describing: topHit?.target)))"); return }
        session.viewportDidTap(target: topHit?.target, hit: topHit, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        await settle(session)
        check(session.section?.reference.name.hasPrefix("Flat face") == true && near(session.makeScene().section?.normal, Vec3(0, 0, 1), 1e-9)
              && near(session.section?.offset, 0, 1e-9), "picking the top face cuts right on it, the top side cut away")
        session.viewportHandleDragged(id: DesignSession.sectionOffsetHandleID, value: -6)
        session.viewportHandleDragEnded(id: DesignSession.sectionOffsetHandleID, value: -6)
        await settle(session)
        check(near(session.makeScene().section?.origin.z, 6, 1e-9), "dragged 6 mm down, it cuts the plate's middle")
        session.lookAtSection()
        await settle(session)
        check(session.camera.back.dot(Vec3(0, 0, 1)) > 0.999, "Look at the cut looks straight down at it")
        await snap(session, "sec09-face-looked-at")
        session.camera = iso
        await settle(session)

        check(session.document == documentBefore && session.canUndo == undoBefore.0 && session.canRedo == undoBefore.1,
              "Section view leaves the document and the undo history alone")

        // Another tool takes over the panel and the handles; the cut stays.
        session.startMeasure()
        await settle(session)
        check(session.measure != nil && session.sectionMode == .on && session.makeScene().section != nil,
              "Measure takes over from the handles and measures the cut model")
        session.endMeasure()
        session.editSection()
        session.startPressPull()
        await settle(session)
        check(session.editingKind == "pressPull" && session.sectionMode == .on && session.makeScene().section != nil
              && session.makeScene().handles.allSatisfy { !$0.id.hasPrefix("section.") },
              "a step opens with the cut still on, and its own handles")
        await snap(session, "sec10-step-in-a-section")
        session.cancelEdit()
        await settle(session)

        // Delete forgets the plane: the tool asks for one again.
        session.deleteSection()
        session.toggleSection()
        check(session.pickMode == .sectionPlane, "after Delete the tool asks for a plane again")
        session.escape()
        check(session.pickMode == .idle && session.section == nil, "Escape stops choosing")

        check(session.document == documentBefore, "the document is as it was")
        await sectionDragFrameRate(session)
    }

    /// `FILLET_SECTION_FIXTURE=<file.step or .fillet>`: imports or opens it (in place of the plate),
    /// cuts it along XZ through its middle and drags the arrow back and forth like a pointer (an
    /// event every 8 ms, ±9 mm, three times round), then lets go and turns the camera while the
    /// exact outline comes in. Logs the frame times of both (`FrameTimingReport`: frames on screen
    /// a second, frame interval, CPU and GPU time per frame and input → screen latency, p50/p95),
    /// how late the pointer's steps ran, and how many times the scene was rebuilt mid-drag (the
    /// fast path moves only the plane: none but the first step's). The bar: 58 frames/s of 60.
    static func sectionDragFrameRate(_ session: DesignSession) async {
        guard let path = ProcessInfo.processInfo.environment["FILLET_SECTION_FIXTURE"], let controller, let renderer = controller.renderer else { return }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "fillet" {
            guard let data = try? Data(contentsOf: url), let document = try? Document(data: data) else {
                check(false, "frame rate: \(path) opens"); return
            }
            session.externalUpdate(document)
        } else {
            session.importSTEP(from: url)
            await settle(session)
            for body in session.model.bodies.dropLast() { session.hiddenBodies.insert(body.ref) }
        }
        session.camera = session.camera.viewing(.iso)
        session.frameBodies()
        await settle(session)
        session.deleteSection()
        session.startSection(on: .xz)
        if let b = session.visibleBodyBounds { session.setSectionOffset(-(b.min.y + b.max.y) / 2) }
        await settle(session)
        guard let arrow = session.makeScene().handles.first(where: { $0.id == DesignSession.sectionOffsetHandleID }) else {
            check(false, "frame rate: an arrow to drag"); return
        }
        // The exact outline of the plane as it starts, so the drag starts from one.
        for _ in 0..<100 where session.sectionCurves == nil { try? await Task.sleep(for: .milliseconds(50)) }
        check(session.sectionCurves?.plane == session.shownSection && session.sectionCurves?.bodies.isEmpty == false,
              "frame rate: the exact outline comes in for the plane held still")
        let cam = controller.liveCamera, size = controller.viewSize
        let wpp = cam.worldUnitsPerPoint(at: arrow.tip, viewSize: size)
        let grabWorld = arrow.tip + arrow.direction * (HandleMetrics.totalLength / 2 * wpp)
        guard let grab = cam.project(grabWorld, viewSize: size), controller.beginHandleDrag(at: grab, pointer: .mouse) else {
            check(false, "frame rate: the arrow can be grabbed"); return
        }
        let triangles = session.model.meshes.values.reduce(0) { $0 + $1.indices.count / 3 }
        let framesBefore = renderer.framesDrawn
        let scenesBefore = renderer.sceneUpdates, movesBefore = renderer.sectionUpdates
        renderer.beginFrameTimings()
        let start = ContinuousClock.now
        let ticks = 375  // 3 s at 125 Hz
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var late: [Double] = []
        for i in 0..<ticks {
            // A triangle wave: 0.5 s out, 0.5 s back.
            let phase = Double(i % 125) / 125
            let mm = 9 * (phase < 0.5 ? phase * 4 - 1 : 3 - phase * 4)
            late.append(ms(ContinuousClock.now - (start + .milliseconds(8 * i))))
            if let p = cam.project(grabWorld + arrow.direction * mm, viewSize: size) { controller.dragHandle(to: p) }
            try? await Task.sleep(until: start + .milliseconds(8 * (i + 1)), clock: .continuous)
        }
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let fps = Double(renderer.framesDrawn - framesBefore) / seconds
        try? await Task.sleep(for: .milliseconds(50))  // the last frames reach the screen
        let drag = renderer.endFrameTimings()
        let rebuilt = renderer.sceneUpdates - scenesBefore, moved = renderer.sectionUpdates - movesBefore
        log("section drag: \(String(format: "%.1f", fps)) frames/s drawn over \(String(format: "%.2f", seconds)) s, \(triangles) triangles, \(path)")
        log("section drag frames: \(drag.summary)")
        log("section drag steps: \(ticks) pointer steps, late p50/p95 \(String(format: "%.1f/%.1f", FrameTimingReport.percentile(late, 0.5), FrameTimingReport.percentile(late, 0.95))) ms; "
            + "\(rebuilt) scene rebuilds, \(moved) plane moves")
        check(rebuilt <= 2 && moved >= ticks - 2, "frame rate: a drag moves the plane without rebuilding the scene (\(rebuilt) rebuilds, \(moved) moves)")
        check(session.sectionCurves?.plane != session.shownSection, "frame rate: mid-drag the outline is the mesh's, the exact one is for where the plane was")

        // Let go and turn the camera for 1.5 s: the exact outline comes in while frames keep coming.
        let settleStart = ContinuousClock.now
        renderer.beginFrameTimings()
        controller.endHandleDrag()
        var turned = controller.liveCamera
        turned.yaw += 0.25
        renderer.animateCamera(to: turned, duration: 1.5)
        var landed: Duration?
        while ContinuousClock.now - settleStart < .milliseconds(1600) {
            if landed == nil, session.sectionCurves?.plane == session.shownSection { landed = ContinuousClock.now - settleStart }
            try? await Task.sleep(for: .milliseconds(4))
        }
        let settled = renderer.endFrameTimings()
        func text(_ d: Duration?) -> String { d.map { String(format: "%.0f ms", ms($0)) } ?? "not yet" }
        log("section settle: exact outline in \(text(landed)) after letting go (kernel \(text(session.sectionCurvesTime))); turning meanwhile: \(settled.summary)")
        check(landed != nil, "frame rate: the exact outline comes in after letting go (\(text(landed)))")
        await settle(session)
        await snap(session, "sec11-frame-rate")
    }
}
#endif
