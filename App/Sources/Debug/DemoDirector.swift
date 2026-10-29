#if DEBUG && os(iOS)
import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// Debug-only paced demo for screen recordings: launch with `FILLET_DEMO=1`
/// (`SIMCTL_CHILD_FILLET_DEMO=1 xcrun simctl launch …`) and the app opens on an
/// in-memory document like the automation does, but keeps the launch splash and
/// then performs the announcement story at a human pace, through the same
/// session entry points the UI uses:
///
/// sketch a 60 × 30 plate with a Ø14 hole → extrude → fillet the four vertical
/// edges → sketch a slot on the top face and cut a pocket → open Sketch 1 from the
/// timeline and widen the plate to 80 mm (every later step follows) → scrub the
/// rollback caliper → orbit with overhangs on (the print check card is in the
/// inspector) → export 3MF into the system save sheet.
///
/// Taps and Pencil strokes are drawn by `DemoTouchOverlay`, so the recording reads
/// as a person using the app. Camera flights run slower than in the app (see
/// `cameraDuration`). Every beat is logged with wall-clock time to
/// `$TMPDIR/fillet-demo/beats.txt`, for cutting the recording to a script.
/// `FILLET_DEMO_PACE=1.2` stretches every pause by that factor.
@MainActor
enum DemoDirector {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FILLET_DEMO"] != nil }

    /// How long camera flights take while the demo runs (the app uses 0.35 s).
    static var cameraDuration = 1.1

    static weak var controller: ViewportController?
    private static var ran = false
    private static var start = Date()
    private static let pace: Double = ProcessInfo.processInfo.environment["FILLET_DEMO_PACE"].flatMap(Double.init) ?? 1

    static let logURL: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fillet-demo", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("beats.txt")
    }()

    // MARK: The story

    static func run(_ session: DesignSession) async {
        guard isEnabled, !ran else { return }
        ran = true
        start = Date()
        if ProcessInfo.processInfo.environment["FILLET_DEMO"] == "snapping" {
            await snappingStory(session)
            return
        }
        beat("launch")
        session.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Pen holder.fillet")  // the title
        // The splash plays over the editor (1.6 s); let it finish and the bed settle.
        await pause(2.6)
        beat("editor")

        // 1. Sketch on the bed.
        await tap(frame: "tool.Sketch") {
            session.startSketch(on: .xy)
            // Pinched in on the corner of the bed where the part goes.
            session.frameSketch(on: StandardPlane.xy.plane, bounds: Bounds3(min: Vec3(-10, -12, 0), max: Vec3(70, 42, 0)))
        }
        beat("sketch-open")
        await settle(session)
        await pause(0.7)
        await tap(frame: "sketch-tool.rectangle") { session.sketchEditor?.engine.setTool(.rectangle) }
        await pause(0.5)
        beat("rectangle")
        // The Pencil comes in near the origin, snaps to it, and drags out the plate.
        await stroke(session, path: { t in
            let wobble = sin(t * .pi) * 1.6
            return SIMD2(-0.4 + 60.3 * t, -0.3 + 30.2 * t + wobble * (1 - t))
        }, approach: SIMD2(-7, -5), duration: 1.25)
        beat("rectangle-done")
        await pause(0.7)
        await tap(frame: "sketch-tool.circle") { session.sketchEditor?.engine.setTool(.circle) }
        await pause(0.4)
        beat("circle")
        await stroke(session, path: { t in SIMD2(15.2 + 6.9 * t, 14.8 + 0.6 * sin(t * .pi)) }, approach: nil, duration: 0.8)
        beat("circle-done")
        await pause(0.9)
        await tap(frame: "finish-sketch-button") { session.finishSketch() }
        await settle(session)
        await pause(0.5)

        // 2. Extrude: the camera swings into 3D, pick the plate, pull the arrow up.
        beat("extrude")
        await tap(frame: "tool.Extrude") { session.startExtrude() }
        beat("whoosh")
        await settle(session)
        await pause(0.4)
        if let sketch = session.model.sketches.values.first, let regions = sketch.regions,
            let i = regions.region(containing: SIMD2(45, 22))
        {
            if let p = globalPoint(sketch.plane.point(regions.interiorPoint(i)) ) ?? globalPoint(sketch.plane.point(SIMD2(45, 22))) {
                await tap(at: p) {
                    session.viewportDidTap(target: .region(i), hit: nil, ray: Ray(origin: .zero, direction: .unitZ),
                                           location: .zero, modifiers: [])
                }
            }
        }
        beat("extrude-profile")
        await settle(session)
        await pause(0.4)
        await dragHandle(session, from: 1, to: 12, duration: 1.3)
        beat("extrude-dragged")
        await pause(0.7)
        await tap(frame: "inspector-done") { session.commitEdit() }
        await settle(session)
        beat("extruded")
        await pause(0.9)

        // 3. Fillet the four vertical edges, radius easing up to 5 mm.
        beat("fillet")
        if let body = session.model.bodies.first {
            let drawn = session.model.meshes[body.ref]?.edges ?? []
            let infos = body.shape.edgeInfos
            let vertical = infos.indices.filter { i in
                infos[i].curve == .line && abs(infos[i].tangentAtMid.z) > 0.99 && i < drawn.count && !drawn[i].isEmpty
            }
            // Front corners first, then the back ones, as a hand would.
            let ordered = vertical.sorted { (infos[$0].mid.y, infos[$0].mid.x) < (infos[$1].mid.y, infos[$1].mid.x) }
            for i in ordered {
                guard let p = globalPoint(infos[i].mid + Vec3(0, 0, 2)) else { continue }
                await tap(at: p) {
                    session.viewportDidTap(target: .edge(body: body.ref.feature, index: i), hit: nil,
                                           ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
                }
                await pause(0.25)
            }
        }
        beat("fillet-edges")
        await pause(0.4)
        await tap(frame: "tool.Fillet") { session.startEdgeFeature(fillet: true) }
        await settle(session)
        await pause(0.3)
        await ease(from: 1, to: 5, step: 0.25, duration: 1.2) { r in
            session.updateEditing { f in if case .fillet(var e) = f.kind { e.size = Expr(r); f.kind = .fillet(e) } }
        }
        await settle(session)
        beat("fillet-radius")
        await pause(0.8)
        await tap(frame: "inspector-done") { session.commitEdit() }
        await settle(session)
        beat("filleted")
        await pause(0.6)

        // 4. Sketch on the top face: a slot, cut 6 mm deep.
        beat("face-sketch")
        if let body = session.model.bodies.first,
            let top = body.shape.faceInfos.firstIndex(where: { $0.surface == .plane && $0.normal.z > 0.99 }),
            let p = globalPoint(Vec3(46, 22, 12))
        {
            await tap(at: p) {
                session.viewportDidTap(target: .face(body: body.ref.feature, index: top), hit: nil,
                                       ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
            }
            await pause(0.5)
            await tap(frame: "tool.Sketch") { session.startSketch() }
            await settle(session)
            await pause(0.5)
            let slotFrame = DebugAutomation.frames["sketch-tool.slot"] != nil ? "sketch-tool.slot" : "sketch-more"
            await tap(frame: slotFrame) { session.sketchEditor?.engine.setTool(.slot) }
            await pause(0.4)
            if let plane = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch]?.plane }) {
                let a = plane.project(Vec3(36, 15, 12)), b = plane.project(Vec3(50, 15, 12)), w = plane.project(Vec3(43, 19, 12))
                await pencilTap(session, a)
                await glide(session, from: a, to: b, duration: 0.7)
                await pencilTap(session, b)
                await glide(session, from: b, to: w, duration: 0.45)
                await pencilTap(session, w)
            }
            beat("slot-done")
            await settle(session)
            await pause(0.7)
            await tap(frame: "finish-sketch-button") { session.finishSketch() }
            await settle(session)
            await pause(0.4)
            await tap(frame: "tool.Extrude") { session.startExtrude() }
            await settle(session)
            await pause(0.5)
            await tap(frame: "segmented.Operation", unit: CGPoint(x: 0.625, y: 0.5)) {
                session.updateEditing { f in if case .extrude(var e) = f.kind { e.operation = .cut; e.distance = -1; f.kind = .extrude(e) } }
            }
            await settle(session)
            await pause(0.3)
            await dragHandle(session, from: -1, to: -6, duration: 0.9)
            beat("pocket-dragged")
            await pause(0.6)
            await tap(frame: "inspector-done") { session.commitEdit() }
            await settle(session)
            // Back to a 3D view of the whole part.
            var c = session.camera
            c.setView(.iso)
            session.camera = c
            session.frameBodies()
            beat("whoosh")
            await settle(session)
            beat("pocketed")
            await pause(1.0)
        }

        // 5. The hero: open Sketch 1 from the timeline, make the plate 80 mm wide.
        beat("hero")
        if let sketchID = session.document.features.first?.id {
            await tap(frame: "station.0") { session.editSketch(sketchID) }
            await settle(session)
            beat("hero-sketch-open")
            await pause(0.5)
            await tap(frame: "sketch-tool.select") { session.sketchEditor?.engine.setTool(.select) }
            await pause(0.4)
            if let sketch = session.model.sketches[sketchID],
                let rect = sketch.source.shapes.first(where: { if case .rectangle = $0.kind { true } else { false } }),
                let p = globalPoint(sketch.plane.point(SIMD2(30, 0)))
            {
                await tap(at: p) {
                    session.viewportDidTap(target: .sketchShape(rect.id), hit: nil, ray: Ray(origin: .zero, direction: .unitZ),
                                           location: .zero, modifiers: [])
                }
                await pause(0.6)
                // Orbit to three-quarters, so the part is seen growing in 3D.
                cameraDuration = 1.4
                beat("whoosh")
                var c = session.camera
                c.setView(.iso)
                session.camera = c.framing(Bounds3(min: Vec3(-4, -4, 0), max: Vec3(84, 34, 12)), viewSize: session.viewSize,
                                           insets: session.viewInsets, margin: 1.3)
                await settle(session)
                cameraDuration = 1.1
                await pause(0.3)
                beat("hero-width")
                await tap(frame: "field.Width") {}
                await pause(0.2)
                await ease(from: 60, to: 80, step: 1, duration: 1.6) { w in
                    session.updateSketch("Edit Rectangle") { s in
                        if let i = s.shapes.firstIndex(where: { $0.id == rect.id }),
                            case .rectangle(let a, let pos, _, let h, let ang) = s.shapes[i].kind
                        {
                            s.shapes[i].kind = .rectangle(anchor: a, position: pos, width: Expr(w), height: h, angle: ang)
                        }
                    }
                }
                await settle(session)
                beat("hero-widened")
                await pause(1.2)
            }
            await tap(frame: "finish-sketch-button") { session.finishSketch() }
            await settle(session)
            session.frameBodies()
            await settle(session)
            beat("hero-done")
            await pause(0.8)

            // Scrub the caliper back to the plain plate, then play forward step by step.
            beat("rollback")
            await scrubCaliper(session, to: [4, 3, 2], stepDuration: 0.32)
            await pause(1.1)
            await scrubCaliper(session, to: [3, 4, nil], stepDuration: 0.55)
            beat("rollback-done")
            await pause(0.8)
        }

        // 6. Print check: orbit a little, overhangs on, the card in the inspector.
        beat("print-check")
        session.selection = []
        cameraDuration = 2.6
        beat("whoosh")
        var orbit = session.camera
        orbit.orbit(deltaYaw: -0.55, deltaPitch: 0.12)
        if let bounds = session.visibleBodyBounds {
            orbit = orbit.framing(bounds, viewSize: session.viewSize, insets: session.viewInsets, margin: DesignSession.bodyMargin)
        }
        session.camera = orbit
        await pause(0.9)
        await tap(frame: "tool.Overhangs") { session.showOverhangs = true }
        await settle(session)
        cameraDuration = 1.1
        beat("overhangs")
        await pause(2.0)
        await tap(frame: "tool.Overhangs") { session.showOverhangs = false }
        await pause(0.8)

        // 7. Export 3MF.
        beat("export")
        await tap(frame: "export-menu") { NotificationCenter.default.post(name: .demoExport, object: nil) }
        await pause(4.5)
        beat("end")
    }

    // MARK: Snapping to the part

    /// `FILLET_DEMO=snapping`: a sketch on a part's face snaps to the part's edges. A 60 × 30 × 8
    /// plate with a Ø7 hole 11.5 mm in from two edges. On its top face the Pencil rings the hole
    /// with a circle on the hole's centre, then puts a second hole level with the first, along the
    /// guide from its centre, and the camera closes in on both. Record it again with
    /// `FILLET_SNAP_BODY_EDGES=0` for the "before": the same strokes land on the 1 mm grid, half a
    /// millimetre off. `docs/video/record-snapping-demo.sh` records both takes.
    static func snappingStory(_ session: DesignSession) async {
        beat("launch")
        session.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Bracket.fillet")  // the title
        let sketch = Feature(name: "Sketch 1", .sketch(Sketch(plane: .xy, shapes: [
            SketchShape(.rectangle(anchor: .corner, position: Point2Expr(0, 0), width: 60, height: 30, angle: 0)),
            SketchShape(.circle(center: Point2Expr(11.5, 11.5), diameter: 7)),
        ])))
        let plate = Feature(name: "Extrude 1", .extrude(Extrude(sketch: sketch.id, regions: [RegionRef(x: 40, y: 15)], distance: 8)))
        session.perform("Plate") { doc in
            _ = doc.addFeature(sketch)
            _ = doc.addFeature(plate)
        }
        await settle(session)
        var iso = session.camera
        iso.setView(.iso)
        session.camera = iso
        session.frameBodies()
        // The splash plays over the editor (1.6 s); let it finish and the part settle.
        await pause(2.6)
        beat("story")

        // Sketch on the top face.
        guard let body = session.model.bodies.first,
            let top = body.shape.faceInfos.firstIndex(where: { $0.surface == .plane && $0.normal.z > 0.99 }),
            let p = globalPoint(Vec3(40, 22, 8))
        else { log("no plate to sketch on"); beat("end"); return }
        await tap(at: p) {
            session.viewportDidTap(target: .face(body: body.ref.feature, index: top), hit: nil,
                                   ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        }
        await pause(0.5)
        await tap(frame: "tool.Sketch") { session.startSketch() }
        await settle(session)
        guard let plane = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch]?.plane }) else {
            log("no sketch on the face"); beat("end"); return
        }
        session.frameSketch(on: plane, bounds: Bounds3(min: Vec3(-3, -3, 8), max: Vec3(63, 33, 8)))
        await settle(session)
        beat("sketch-open")
        await pause(0.8)

        // A circle around the hole: the Pencil comes in a little off its centre.
        await tap(frame: "sketch-tool.circle") { session.sketchEditor?.engine.setTool(.circle) }
        await pause(0.5)
        beat("ring")
        await glide(session, from: SIMD2(30, 24), to: SIMD2(11.8, 11.25), duration: 0.9)
        await pause(0.7)  // the centre marker shows (or, before, nothing does)
        await stroke(session, path: { t in SIMD2(11.8 + 6 * t, 11.25 + 0.3 * sin(t * .pi)) }, approach: nil, duration: 0.8)
        beat("ring-done")
        await pause(0.8)

        // A second hole level with the first: along the guide from its centre.
        beat("second-hole")
        await glide(session, from: SIMD2(17.8, 11.25), to: SIMD2(47.9, 11.3), duration: 1.4)
        await pause(0.7)
        await stroke(session, path: { t in SIMD2(47.9 + 3.5 * t, 11.3) }, approach: nil, duration: 0.6)
        beat("second-hole-done")
        await pause(0.8)

        // Close in on the first hole (centred, or half a millimetre off), then on the pair.
        beat("close-up")
        cameraDuration = 1.4
        session.frameSketch(on: plane, bounds: Bounds3(min: Vec3(3, 3, 8), max: Vec3(20, 20, 8)))
        await settle(session)
        await pause(1.6)
        session.frameSketch(on: plane, bounds: Bounds3(min: Vec3(-3, -3, 8), max: Vec3(63, 33, 8)))
        await settle(session)
        cameraDuration = 1.1
        await pause(0.8)
        await tap(frame: "finish-sketch-button") { session.finishSketch() }
        await settle(session)
        await pause(1.2)
        beat("end")
    }

    // MARK: Pointer

    /// A view-space point (viewport points) in window coordinates.
    private static func global(_ local: CGPoint) -> CGPoint {
        let origin = DebugAutomation.frames["viewport"]?.rect.origin ?? .zero
        return CGPoint(x: local.x + origin.x, y: local.y + origin.y)
    }

    private static var liveCamera: Camera? { controller?.liveCamera }

    /// Where a world point is on screen right now (the live, possibly animating camera).
    private static func globalPoint(_ world: Vec3) -> CGPoint? {
        guard let camera = liveCamera, let size = controller?.viewSize, size.width > 0,
            let p = camera.project(world, viewSize: size)
        else { return nil }
        return global(p)
    }

    /// A finger tap on a point in the window; `action` runs as the finger lifts.
    private static func tap(at p: CGPoint, _ action: () -> Void) async {
        beat("touch")
        let touch = DemoTouch.shared
        touch.kind = .finger
        touch.location = p
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) {
            touch.visible = true
            touch.pressed = true
        }
        try? await Task.sleep(for: .seconds(0.16))
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) { touch.pressed = false }
        action()
        try? await Task.sleep(for: .seconds(0.12))
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { touch.visible = false }
    }

    /// A tap on a view tagged with `automationFrame` (at a unit point inside it).
    private static func tap(frame name: String, unit: CGPoint = CGPoint(x: 0.5, y: 0.5), _ action: () -> Void) async {
        guard let r = DebugAutomation.frames[name]?.rect else {
            log("no frame \(name); acting without a touch")
            action()
            return
        }
        await tap(at: CGPoint(x: r.minX + r.width * unit.x, y: r.minY + r.height * unit.y), action)
    }

    /// The tool event for a sketch-plane point, through the live camera.
    private static func toolEvent(_ session: DesignSession, _ p: SIMD2<Double>) -> (ViewportToolEvent, CGPoint)? {
        guard let sketch = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch] }),
            let camera = liveCamera, let size = controller?.viewSize,
            let screen = camera.project(sketch.plane.point(p), viewSize: size)
        else { return nil }
        return (ViewportToolEvent(ray: camera.ray(at: screen, viewSize: size), location: screen, pressure: 0.5, pointer: .pencil),
                global(screen))
    }

    /// Apple Pencil: optionally hovers in from `approach`, then presses and drags along
    /// `path` (sketch coordinates, t = 0…1, eased) and lifts.
    private static func stroke(_ session: DesignSession, path: (Double) -> SIMD2<Double>, approach: SIMD2<Double>?,
                               duration: Double) async {
        let touch = DemoTouch.shared
        touch.kind = .pencil
        if let approach {
            await glide(session, from: approach, to: path(0), duration: 0.45)
        }
        guard let (first, at) = toolEvent(session, path(0)) else { return }
        beat("pencil")
        touch.location = at
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)) { touch.visible = true; touch.pressed = true }
        session.viewportToolBegan(first)
        let frames = max(Int(duration * pace * 60), 2)
        for f in 1...frames {
            let t = easeInOut(Double(f) / Double(frames))
            if let (event, at) = toolEvent(session, path(t)) {
                touch.location = at
                session.viewportToolMoved(event)
                logSnap(session)
            }
            try? await Task.sleep(for: .seconds(1.0 / 60))
        }
        if let (last, _) = toolEvent(session, path(1)) { session.viewportToolEnded(last) }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { touch.visible = false; touch.pressed = false }
    }

    /// Pencil hovering across the plane (drives the rubber band without touching).
    private static func glide(_ session: DesignSession, from a: SIMD2<Double>, to b: SIMD2<Double>, duration: Double) async {
        let touch = DemoTouch.shared
        touch.kind = .pencil
        let frames = max(Int(duration * pace * 60), 2)
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)) { touch.visible = true; touch.pressed = false }
        for f in 0...frames {
            let t = easeInOut(Double(f) / Double(frames))
            if let (event, at) = toolEvent(session, a + (b - a) * t) {
                touch.location = at
                session.viewportToolHover(event)
                logSnap(session)
            }
            try? await Task.sleep(for: .seconds(1.0 / 60))
        }
    }

    /// A Pencil tap on a sketch-plane point.
    private static func pencilTap(_ session: DesignSession, _ p: SIMD2<Double>) async {
        guard let (event, at) = toolEvent(session, p) else { return }
        let touch = DemoTouch.shared
        touch.kind = .pencil
        touch.location = at
        beat("pencil")
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.1)) { touch.visible = true; touch.pressed = true }
        session.viewportToolBegan(event)
        try? await Task.sleep(for: .seconds(0.1))
        session.viewportToolEnded(event)
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)) { touch.pressed = false }
        try? await Task.sleep(for: .seconds(0.12))
    }

    /// A finger on the extrude arrow, pulling it from one distance to another.
    private static func dragHandle(_ session: DesignSession, from a: Double, to b: Double, duration: Double) async {
        let touch = DemoTouch.shared
        touch.kind = .finger
        func arrowTip(_ value: Double) -> CGPoint? {
            guard case .extrude(let e) = session.editingFeature?.kind, let sketch = session.model.sketches[e.sketch],
                let regions = sketch.regions, let first = e.regions.first
            else { return nil }
            let anchor = regions.region(containing: first.point).map { regions.interiorPoint($0) } ?? first.point
            let origin = sketch.plane.point(anchor)
            guard let p0 = globalPoint(origin + sketch.plane.normal * value),
                let p1 = globalPoint(origin + sketch.plane.normal * (value + 1))
            else { return nil }
            // The arrow is drawn 48 pt past the value along its own screen direction.
            var d = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
            let len = max(hypot(d.x, d.y), 1e-6)
            d = CGPoint(x: d.x / len, y: d.y / len)
            let sign: CGFloat = value >= 0 ? 1 : -1
            return CGPoint(x: p0.x + d.x * 40 * sign, y: p0.y + d.y * 40 * sign)
        }
        session.viewportHandleDragged(id: "distance", value: a)
        await settle(session)
        guard let start = arrowTip(a) else { return }
        beat("touch")
        touch.location = start
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) { touch.visible = true; touch.pressed = true }
        try? await Task.sleep(for: .seconds(0.2))
        let frames = max(Int(duration * pace * 60), 2)
        for f in 1...frames {
            let v = a + (b - a) * easeInOut(Double(f) / Double(frames))
            session.viewportHandleDragged(id: "distance", value: v)
            if let p = arrowTip(v) { touch.location = p }
            try? await Task.sleep(for: .seconds(1.0 / 60))
        }
        try? await Task.sleep(for: .seconds(0.15))
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { touch.visible = false; touch.pressed = false }
    }

    /// Drags the rollback caliper through station boundaries (nil = the end).
    private static func scrubCaliper(_ session: DesignSession, to targets: [Int?], stepDuration: Double) async {
        let touch = DemoTouch.shared
        touch.kind = .finger
        func boundaryX(_ index: Int?) -> CGPoint? {
            let count = session.document.features.count
            let i = index ?? count
            if i < count, let r = DebugAutomation.frames["station.\(i)"]?.rect { return CGPoint(x: r.minX, y: r.minY + 22) }
            if let r = DebugAutomation.frames["station.\(count - 1)"]?.rect { return CGPoint(x: r.maxX, y: r.minY + 22) }
            return nil
        }
        guard let begin = boundaryX(session.document.rollbackIndex) else { return }
        beat("touch")
        touch.location = begin
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) { touch.visible = true; touch.pressed = true }
        try? await Task.sleep(for: .seconds(0.2))
        for target in targets {
            if let p = boundaryX(target) {
                withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: stepDuration * pace)) { touch.location = p }
            }
            try? await Task.sleep(for: .seconds(stepDuration * pace * 0.6))
            session.moveRollbackMarker(to: target)
            beat("detent")
            try? await Task.sleep(for: .seconds(stepDuration * pace * 0.4))
            await settle(session)
        }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { touch.visible = false; touch.pressed = false }
    }

    /// Logs the moment the Pencil snaps to a point or lines up (where the app ticks, too).
    private static var lastSnap: SketchSnap?
    private static func logSnap(_ session: DesignSession) {
        let snap = session.sketchEditor?.engine.snap
        defer { lastSnap = snap }
        guard snap != lastSnap else { return }
        switch snap {
        case .point, .horizontal, .vertical, .extension, .aligned: beat("snap")
        default: break
        }
    }

    // MARK: Timing

    /// Steps a value along an ease-in-out curve, rounding to `step`, calling `apply` on each change.
    private static func ease(from a: Double, to b: Double, step: Double, duration: Double, _ apply: (Double) -> Void) async {
        let frames = max(Int(duration * pace * 30), 2)
        var last = Double.nan
        for f in 0...frames {
            let v = ((a + (b - a) * easeInOut(Double(f) / Double(frames))) / step).rounded() * step
            if v != last {
                apply(v)
                last = v
            }
            try? await Task.sleep(for: .seconds(1.0 / 30))
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds * pace))
    }

    /// Waits for recompute and for a camera flight to land.
    private static func settle(_ session: DesignSession) async {
        try? await Task.sleep(for: .milliseconds(80))
        while session.isRecomputing { try? await Task.sleep(for: .milliseconds(30)) }
        for _ in 0..<80 {
            guard let live = controller?.liveCamera, !live.isApproximatelyEqual(to: session.camera, tolerance: 1e-3) else { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: Log

    private static func beat(_ name: String) {
        let now = Date()
        log(String(format: "beat %@ t=%.3f epoch=%.3f", name, now.timeIntervalSince(start), now.timeIntervalSince1970))
    }

    private static func log(_ s: String) {
        print("[demo] \(s)")
        let line = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: logURL)
        }
    }
}

extension Notification.Name {
    /// The demo asks the export menu to export 3MF (a SwiftUI `Menu` can't be opened from code).
    static let demoExport = Notification.Name("FilletDemoExport")
}

/// Where the demo's finger or Pencil is, drawn over the whole window.
@MainActor @Observable
final class DemoTouch {
    static let shared = DemoTouch()
    enum Kind { case finger, pencil }
    var location: CGPoint = .zero
    var kind: Kind = .finger
    var visible = false
    var pressed = false
}

/// A soft touch marker like the system's "show touches": a translucent disc for a finger,
/// a small ink point with a halo for Apple Pencil. It takes no hits.
struct DemoTouchOverlay: View {
    private let touch = DemoTouch.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            marker
                .scaleEffect(touch.visible ? (touch.pressed ? 0.88 : 1) : 0.92, anchor: .center)
                .opacity(touch.visible ? 1 : 0)
                .position(touch.location)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var marker: some View {
        switch touch.kind {
        case .finger:
            Circle()
                .fill(Color(hex: 0x1D2B45).opacity(0.16))
                .overlay(Circle().strokeBorder(Color(hex: 0x1D2B45).opacity(0.32), lineWidth: 1.5))
                .background(Circle().fill(.white.opacity(0.35)).blur(radius: 6))
                .frame(width: 46, height: 46)
        case .pencil:
            ZStack {
                Circle().fill(Color(hex: 0x1D2B45).opacity(0.12)).frame(width: 26, height: 26)
                Circle().fill(Color(hex: 0x1D2B45).opacity(0.85)).frame(width: 7, height: 7)
            }
        }
    }
}
#endif
