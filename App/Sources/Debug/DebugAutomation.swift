import SwiftUI
#if DEBUG
#if os(macOS)
import AppKit
import MetalKit
#else
import UIKit
#endif
import FilletCore
import FilletKernel
import FilletViewport
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only end-to-end scenario: launch with `FILLET_AUTOMATION=1` and the
/// app opens a new document, drives a realistic workflow through the same
/// session entry points the UI uses (tool events with real camera rays, taps
/// with pick targets, inspector updates), and writes a snapshot of the
/// viewport and the window after every step to `$TMPDIR/fillet-automation/`.
///
/// On iPad (simulator) the app opens straight into an editor on an in-memory
/// document (see `AutomationEditor`). Window captures there come from outside:
/// each step logs `snapshot <name>` and holds still for `iPadScreenshotPause`
/// so a script can run `simctl io screenshot`. `FILLET_ORIENTATION=landscape`
/// lays out at the 12.9" landscape size; `FILLET_WIDTH=700` narrows the editor to a Split View width.
///
/// Every step also checks the layout against the window: the editor is exactly as wide as
/// its window, the tool strip and timeline sit inside it, and in sketch mode every sketch
/// tool is either visible in the viewport or folded into "More shapes".
@MainActor
enum DebugAutomation {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FILLET_AUTOMATION"] != nil }

    static let outputDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fillet-automation", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    #if os(macOS)
    static func launch() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSDocumentController.shared.newDocument(nil)
        }
    }
    #else
    /// Editor width for a Split View check (`FILLET_WIDTH`), nil for the full window.
    static var forcedWidth: CGFloat? {
        ProcessInfo.processInfo.environment["FILLET_WIDTH"].flatMap(Double.init).map { CGFloat($0) }
    }

    /// iPadOS 26 refuses programmatic rotation in windowed mode, so `FILLET_ORIENTATION=landscape`
    /// lays the editor out at the 12.9" landscape size (the owner's iPad Pro, 1366 × 1024 pt) and
    /// scales it down to fit the portrait screen.
    static var simulatedLandscape: CGSize? {
        ProcessInfo.processInfo.environment["FILLET_ORIENTATION"] == "landscape" ? CGSize(width: 1366, height: 1024) : nil
    }

    /// Time each step holds still for an external `simctl io screenshot`.
    static let iPadScreenshotPause: Duration = .seconds(3)
    #endif

    private static var ran = false
    /// The editor's viewport controller, to compare its live (animated) camera with the session's.
    static weak var controller: ViewportController?

    static func run(_ session: DesignSession) async {
        guard isEnabled, !ran else { return }
        ran = true
        #if os(macOS)
        switch ProcessInfo.processInfo.environment["FILLET_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        log("output: \(outputDirectory.path)")
        try? await Task.sleep(for: .seconds(1))
        #if os(macOS)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }) {
            window.setFrame(NSRect(x: 40, y: 40, width: 1600, height: 1000), display: true)
            // In front and key, so it draws like a window in use and the undo state is the window's.
            if window.isZoomed { window.zoom(nil) }
            window.setFrame(NSRect(x: 40, y: 40, width: 1600, height: 1000), display: true)
            window.orderFrontRegardless()
            window.makeKey()
        }
        #endif
        try? await Task.sleep(for: .milliseconds(300))
        await settle(session)
        await snap(session, "01-empty")

        // Sketch on the bed, picked like in Fusion: Sketch shows the origin planes, tap XY.
        session.startSketch()
        await settle(session)
        check(session.pickMode == .sketchPlane && session.makeScene().referencePlanes.count == 3,
              "Sketch with nothing picked offers the 3 origin planes")
        await snap(session, "01b-choose-plane")
        check(markers["sketch-plane-bar", default: 0] == 1, "the plane bar shows once")
        let bedHit = pick(session, at: Vec3(25, -25, 0))
        check(bedHit?.target == .referencePlane("xy"), "a tap on the bed plane picks XY (\(String(describing: bedHit?.target)))")
        session.viewportHoverChanged(target: bedHit?.target)
        check(session.hover == .originPlane(.xy), "hovering the plane lights it (and its chip)")
        await settle(session)
        await snap(session, "01c-hover-plane")
        if let bedHit { session.viewportDidTap(target: bedHit.target, hit: bedHit, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: []) }
        await settle(session)
        if case .sketch(let s)? = session.editingFeature?.kind, case .standard(.xy, _) = s.plane, session.sketchEditor != nil {
            check(!session.choosingSketchPlane, "picking XY opens a sketch on it")
        } else {
            check(false, "picking XY opens a sketch on it")
        }
        // A 60×30 rectangle with a Ø14 hole.
        session.sketchEditor?.engine.setTool(.rectangle)
        tap(session, SIMD2(0, 0))
        tap(session, SIMD2(60, 30))
        session.sketchEditor?.engine.setTool(.circle)
        tap(session, SIMD2(15, 15))
        tap(session, SIMD2(22, 15))
        // Mid-draw state: a centre rectangle with its live dimensions.
        session.sketchEditor?.engine.setTool(.centerRectangle)
        tap(session, SIMD2(45, 15))
        hover(session, SIMD2(52.6, 19.2))
        await settle(session)
        await snap(session, "02a-drawing")
        checkInView(session, session.sketchFrameBounds(sketch: session.sketchEditor?.sketch,
                                                       plane: session.model.sketches.values.first?.plane ?? StandardPlane.xy.plane),
                    "sketch geometry inside the visible viewport")
        check(markers["finish-sketch", default: 0] == 1, "exactly one Finish sketch button (\(markers["finish-sketch", default: 0]))")
        session.sketchEditor?.engine.cancel()
        session.sketchEditor?.engine.setTool(.circle)
        await settle(session)
        await snap(session, "02-sketch")
        check(session.model.sketches.values.first?.regions?.count == 2, "sketch has 2 regions")
        #if os(macOS)
        await typeIntoDimensionField(session)
        await dragToMove(session)
        await typeSizesWhileDrawing(session)
        #endif

        // Extrude the plate (not the hole).
        session.startExtrude()
        await settle(session)
        if let sketch = session.model.sketches.values.first, let i = sketch.regions?.region(containing: SIMD2(45, 20)) {
            session.viewportDidTap(target: .region(i), hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        }
        await settle(session)
        session.viewportHandleDragged(id: "distance", value: 12)
        await settle(session)
        await snap(session, "03-extrude-editing")
        session.commitEdit()
        await settle(session)
        await snap(session, "04-extruded")
        checkCentred(session, "first body framed in the visible viewport")
        checkUndoState(session, expectUndo: true, "Undo available after the first extrude")
        let plate = 60.0 * 30 * 12 - Double.pi * 49 * 12
        check(abs((session.model.bodies.first?.shape.volume ?? 0) - plate) < 0.01, "extruded volume \(session.model.bodies.first?.shape.volume ?? 0) ≈ \(plate)")

        // Pick the four vertical edges and fillet them.
        if let body = session.model.bodies.first {
            let drawn = session.model.meshes[body.ref]?.edges ?? []
            for (i, e) in body.shape.edgeInfos.enumerated()
            where e.curve == .line && abs(e.tangentAtMid.z) > 0.99 && i < drawn.count && !drawn[i].isEmpty {
                session.viewportDidTap(target: .edge(body: body.ref.feature, index: i), hit: nil,
                                       ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
            }
        }
        check(session.selectedEdges.count == 4, "4 edges selected (\(session.selectedEdges.count))")
        session.startEdgeFeature(fillet: true)
        session.updateEditing { f in if case .fillet(var e) = f.kind { e.size = 5; f.kind = .fillet(e) } }
        await settle(session)
        await snap(session, "05-fillet-editing")
        check(session.viewportSummary.contains("4 edges picked") && session.viewportSummary.contains("1 body"),
              "3D view summary for VoiceOver: \(session.viewportSummary)")
        session.commitEdit()
        await settle(session)
        check(session.model.status.values.allSatisfy { if case .failed = $0 { false } else { true } }, "no failed features")

        // Sketch on the top face, picked in the viewport after Sketch, and cut a pocket.
        if let body = session.model.bodies.first,
            let top = body.shape.faceInfos.firstIndex(where: { $0.surface == .plane && $0.normal.z > 0.99 })
        {
            session.selection = []
            session.startSketch()
            await settle(session)
            let curved = body.shape.faceInfos.indices.filter { body.shape.facePlane($0) == nil }
            check(!curved.isEmpty && session.planarFaces()[body.ref.feature]?.isDisjoint(with: curved) == true,
                  "the filleted corners (\(curved.count) curved faces) can't be picked to sketch on")
            await snap(session, "05b-choose-face")
            let topHit = pick(session, at: Vec3(43, 15, 12))
            check(topHit?.target == .face(body: body.ref.feature, index: top), "a tap on the top face picks it (\(String(describing: topHit?.target)))")
            session.viewportDidTap(target: topHit?.target, hit: topHit, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
            await settle(session)
            if case .sketch(let s)? = session.editingFeature?.kind, case .face = s.plane {} else { check(false, "picking the top face opens a sketch on it") }
            session.sketchEditor?.engine.setTool(.slot)
            if let plane = session.model.sketches[session.sketchEditor!.sketch]?.plane {
                for p in [Vec3(36, 15, 12), Vec3(50, 15, 12), Vec3(43, 19, 12)] { tap(session, plane.project(p)) }
            }
            await settle(session)
            await snap(session, "06-sketch-on-face")
            session.startExtrude()
            await settle(session)
            // A single profile is preselected; only tap when nothing is selected yet.
            if case .extrude(let e) = session.editingFeature?.kind, e.regions.isEmpty,
                let regions = session.model.sketches[e.sketch]?.regions, regions.count > 0
            {
                session.viewportDidTap(target: .region(0), hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
            }
            session.updateEditing { f in if case .extrude(var e) = f.kind { e.distance = -6; e.operation = .cut; f.kind = .extrude(e) } }
            await settle(session)
            session.commitEdit()
            await settle(session)
            await snap(session, "07-pocket")
        }

        session.showOverhangs = true
        session.camera = session.camera.viewing(.front)
        await settle(session)
        await snap(session, "08-overhangs")
        session.showOverhangs = false

        // Parametric change: widen the plate through the timeline.
        if let sketchID = session.document.features.first?.id {
            session.editSketch(sketchID)
            await settle(session)
            session.updateSketch("Widen") { sketch in
                if let i = sketch.shapes.firstIndex(where: { if case .rectangle = $0.kind { true } else { false } }),
                    case .rectangle(let a, let p, _, let h, let ang) = sketch.shapes[i].kind
                {
                    sketch.shapes[i].kind = .rectangle(anchor: a, position: p, width: 80, height: h, angle: ang)
                }
            }
            session.finishSketch()
            await settle(session)
            // ⌘0 from an isometric view, once the wider plate has recomputed.
            session.camera = session.camera.viewing(.iso)
            session.frameBodies()
            await settle(session)
            checkCentred(session, "widened body framed")
            await snap(session, "09-widened")
            check(session.model.status.values.allSatisfy { if case .failed = $0 { false } else { true } }, "all features ok after widening")
            await widenedFilletHighlights(session)
        }

        await failedStepBanner(session)

        // A named parameter, so the browser's parameter row shows in the next capture.
        session.perform("Add Parameter") { $0.parameters.append(Parameter(name: "wall", expression: 2)) }
        check(session.model.parameters.errors.isEmpty, "parameter evaluates")

        // Roll back to after the first extrude (the later steps hatch), then play to the end again.
        session.moveRollbackMarker(to: 2)
        await settle(session)
        await snap(session, "10-rolled-back")
        check(session.document.activeFeatureCount == 2 && session.model.bodies.count == 1, "rolled back to step 2")
        session.moveRollbackMarker(to: nil)
        await settle(session)
        check(session.document.activeFeatureCount == session.document.features.count, "rolled forward to the end")

        // Undo and Redo follow the real state: undo the rollback marker move, then redo it.
        if let undoManager = session.undoManager {
            let after = session.document
            undoManager.undo()
            await settle(session)
            checkUndoState(session, expectUndo: true, expectRedo: true, "Undo reverts and Redo becomes available")
            check(session.document != after, "Undo changed the document")
            undoManager.redo()
            await settle(session)
            checkUndoState(session, expectUndo: true, expectRedo: false, "Redo restores and Redo is spent")
            check(session.document == after, "Redo restored the document")
        } else {
            log("no undo manager in this host; undo checks skipped")
        }

        // Export.
        do {
            let data = try await session.exportData(.threeMF)
            try data.write(to: outputDirectory.appendingPathComponent("export.3mf"))
            log("3MF: \(data.count) bytes")
            let stl = try await session.exportData(.stl)
            try stl.write(to: outputDirectory.appendingPathComponent("export.stl"))
            let step = try await session.exportData(.step)
            try step.write(to: outputDirectory.appendingPathComponent("export.step"))
            log("STL: \(stl.count) bytes, STEP: \(step.count) bytes")
        } catch {
            check(false, "export failed: \(error)")
        }
        try? session.document.encoded().write(to: outputDirectory.appendingPathComponent("design.fillet"))

        log("timeline: " + session.document.features.map { "\($0.name)[\(session.model.status[$0.id].map(String.init(describing:)) ?? "-")]" }.joined(separator: " → "))
        log(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        #if os(macOS)
        if ProcessInfo.processInfo.environment["FILLET_AUTOMATION_KEEP_OPEN"] == nil {
            // A scratch document: quit without a save prompt, and without leaving an autosave
            // that the next launch would restore.
            for document in NSDocumentController.shared.documents {
                document.updateChangeCount(.changeCleared)
                document.close()
            }
            NSApp.terminate(nil)
        }
        #endif
    }

    // MARK: Helpers

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log("\(ok ? "✔" : "✘") \(what)")
    }

    /// The toolbar's undo state matches the undo manager (and the expectation).
    private static func checkUndoState(_ session: DesignSession, expectUndo: Bool, expectRedo: Bool? = nil, _ what: String) {
        guard let manager = session.undoManager else { log("no undo manager; skipped: \(what)"); return }
        let truthful = session.canUndo == manager.canUndo && session.canRedo == manager.canRedo
        let expected = session.canUndo == expectUndo && (expectRedo.map { session.canRedo == $0 } ?? true)
        check(truthful && expected, "\(what) (toolbar undo \(session.canUndo) redo \(session.canRedo), manager \(manager.canUndo)/\(manager.canRedo))")
    }

    /// A parameter drives the fillet radius; an impossible value breaks the fillet. The
    /// banner names the step, Show opens it, and fixing the value clears the banner.
    private static func failedStepBanner(_ session: DesignSession) async {
        guard let fillet = session.document.features.first(where: { if case .fillet = $0.kind { true } else { false } }) else {
            check(false, "a fillet to break"); return
        }
        func setRadius(_ value: Double) {
            session.perform("Edit Parameter") { doc in
                if let i = doc.parameters.firstIndex(where: { $0.name == "r" }) { doc.parameters[i].expression = Expr(value) }
            }
        }
        session.perform("Add Parameter") { $0.parameters.append(Parameter(name: "r", expression: 5)) }
        session.perform("Radius from r") { doc in
            if let i = doc.index(of: fillet.id), case .fillet(var e) = doc.features[i].kind {
                e.size = Expr(stringLiteral: "r")
                doc.features[i].kind = .fillet(e)
            }
        }
        await settle(session)
        check(session.model.error(for: fillet.id) == nil && session.message == nil, "fillet driven by r = 5 works")
        setRadius(40)
        await settle(session)
        check(session.message?.failedFeature == fillet.id && session.message?.kind == .error,
              "failed-step banner for \(fillet.name): \(session.message?.text ?? "none")")
        await snap(session, "09b-failed-step")
        check(markers["toast-show", default: 0] == 1, "banner has one Show button")
        check(!(session.message?.dismissesItself ?? true), "error banner doesn't dismiss itself")
        if let action = session.message?.action { session.run(action) }
        await settle(session)
        check(session.editing?.feature == fillet.id && session.model.error(for: fillet.id) != nil, "Show opens the failed step with its error")
        await snap(session, "09c-show-failed")
        session.cancelEdit()
        setRadius(5)
        await settle(session)
        check(session.message == nil && session.failedFeatures.isEmpty, "r = 5 again clears the banner and the failure")
    }

    /// After the widening, opening Fillet 1 draws its picked edges where the fillet rounds them:
    /// each dashed highlight is an edge its references resolve to on the body before it (the
    /// evaluator's own resolution), and a vertical edge at a corner of the wider plate.
    private static func widenedFilletHighlights(_ session: DesignSession) async {
        guard let fillet = session.document.features.first(where: { if case .fillet = $0.kind { true } else { false } }),
            case .fillet(let f) = fillet.kind
        else { check(false, "a fillet to open"); return }
        session.beginEdit(fillet.id)
        await settle(session)
        await snap(session, "09a-fillet-widened")
        let dashed = session.edgeHighlights().filter(\.dashed)
        guard let before = session.model.bodiesBefore?.first(where: { $0.ref == f.body })?.shape, let box = before.bounds else {
            check(false, "body before Fillet 1"); return
        }
        let resolved = f.edges.compactMap { ReferenceResolver.resolve($0.signature, in: before.edgeInfos) }.map { before.edgeInfos[$0].polyline }
        func same(_ a: [Vec3], _ b: [Vec3]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0.distance(to: $1) < 1e-6 } }
        func near(_ v: Double, _ a: Double, _ b: Double) -> Bool { abs(v - a) < 1e-3 || abs(v - b) < 1e-3 }
        let matching = dashed.filter { h in resolved.contains { same($0, h.points) } }.count
        let corners = dashed.filter { h in
            guard let a = h.points.first, let b = h.points.last else { return false }
            return abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && near(a.x, box.min.x, box.max.x) && near(a.y, box.min.y, box.max.y)
        }.count
        check(dashed.count == 4 && matching == 4 && corners == 4,
              "Fillet 1 after widening: \(dashed.count) picked edges drawn, \(matching) match the resolved edges, \(corners) at plate corners (x \(Int(box.min.x))…\(Int(box.max.x)))")
        session.cancelEdit()
        await settle(session)
    }

    /// The bodies' projected bounds sit centred in the unobstructed part of the viewport.
    private static func checkCentred(_ session: DesignSession, _ what: String) {
        guard let bounds = session.visibleBodyBounds,
            let box = session.camera.screenRect(of: bounds, viewSize: session.viewSize)
        else { check(false, what); return }
        let safe = session.viewInsets.rect(in: session.viewSize)
        let dx = (box.midX - safe.midX) / safe.width, dy = (box.midY - safe.midY) / safe.height
        let inside = box.minX >= safe.minX - 1 && box.maxX <= safe.maxX + 1 && box.minY >= safe.minY - 1 && box.maxY <= safe.maxY + 1
        check(inside && abs(dx) < 0.03 && abs(dy) < 0.03,
              "\(what) (centre off by \(Int(dx * 1000) / 10)% × \(Int(dy * 1000) / 10)%, inside: \(inside))")
    }

    /// Bounds project fully inside the unobstructed part of the viewport.
    private static func checkInView(_ session: DesignSession, _ bounds: Bounds3, _ what: String) {
        guard let box = session.camera.screenRect(of: bounds, viewSize: session.viewSize) else { check(false, what); return }
        let safe = session.viewInsets.rect(in: session.viewSize)
        check(safe.insetBy(dx: -1, dy: -1).contains(box), "\(what) (\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height)) in \(Int(safe.minX)),\(Int(safe.minY)) \(Int(safe.width))×\(Int(safe.height)))")
    }

    /// Width of the window the editor lays out in: the simulated landscape or Split View width
    /// on the iPad, else the real window.
    private static var windowWidth: CGFloat? {
        #if os(macOS)
        NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 })?.contentView?.bounds.width
        #else
        if let landscape = simulatedLandscape { return landscape.width }
        if let forcedWidth { return forcedWidth }
        return deviceWindowWidth
        #endif
    }

    #if os(iOS)
    private static var deviceWindowWidth: CGFloat? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.bounds.width
    }
    #endif

    /// A recorded frame in the points the editor lays out in. Frames are global (named coordinate
    /// spaces don't reach into the navigation stack's hosting controller), and global coordinates
    /// include the simulated landscape's scale-down.
    private static func layoutFrame(_ name: String) -> CGRect? {
        guard let rect = frames[name]?.rect else { return nil }
        #if os(iOS)
        if let landscape = simulatedLandscape, let device = deviceWindowWidth, device > 0 {
            let scale = landscape.width / device
            return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        #endif
        return rect
    }

    /// Nothing widens the editor past its window, the tool strip and timeline sit inside it, and
    /// in sketch mode every sketch tool is reachable: visible in the viewport, or in "More shapes".
    private static func checkLayout(_ session: DesignSession, _ step: String) {
        guard let window = windowWidth, let content = layoutFrame("editor-content") else {
            check(false, "\(step): editor and window measured"); return
        }
        check(abs(content.width - window) <= 1 && content.minX >= -1,
              "\(step): editor \(Int(content.minX))…\(Int(content.maxX)) pt in a \(Int(window)) pt window")
        for name in ["tool-strip", "timeline"] {
            guard let f = layoutFrame(name) else { check(false, "\(step): \(name) measured"); continue }
            check(f.minX >= -0.5 && f.maxX <= window + 0.5, "\(step): \(name) spans \(Int(f.minX))…\(Int(f.maxX)) of \(Int(window))")
        }
        guard session.sketchEditor != nil else { return }
        // The viewport clips its overlays, so a tool counts as visible only inside the viewport.
        guard let viewport = layoutFrame("viewport")?.intersection(CGRect(x: 0, y: -1e6, width: window, height: 2e6)) else {
            check(false, "\(step): viewport measured"); return
        }
        func inside(_ r: CGRect) -> Bool { r.minX >= viewport.minX - 0.5 && r.maxX <= viewport.maxX + 0.5 }
        var visible: [String] = [], folded: [String] = [], unreachable: [String] = []
        for tool in SketchTool.allCases {
            if let f = layoutFrame("sketch-tool.\(tool.rawValue)"), inside(f) {
                visible.append(tool.rawValue)
            } else if markers["sketch-folded.\(tool.rawValue)", default: 0] > 0, let more = layoutFrame("sketch-more"), inside(more) {
                folded.append(tool.rawValue)
            } else {
                unreachable.append(tool.rawValue)
            }
        }
        check(unreachable.isEmpty, "\(step): sketch tools \(visible.count) on the bar, \(folded.count) in More shapes"
              + (unreachable.isEmpty ? "" : ", unreachable: \(unreachable.joined(separator: ", "))"))
    }

    private static func log(_ s: String) {
        print("[automation] \(s)")
        let url = outputDirectory.appendingPathComponent("log.txt")
        let line = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Waits for recompute to finish.
    private static func settle(_ session: DesignSession) async {
        try? await Task.sleep(for: .milliseconds(150))
        while session.isRecomputing { try? await Task.sleep(for: .milliseconds(30)) }
        try? await Task.sleep(for: .milliseconds(250))
        // Let a camera flight land, so captures and checks see the camera the user would.
        for _ in 0..<40 {
            guard let live = controller?.liveCamera, !live.isApproximatelyEqual(to: session.camera, tolerance: 1e-3) else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A tap at a sketch-plane point, delivered as tool events with a real camera ray.
    private static func tap(_ session: DesignSession, _ p: SIMD2<Double>) {
        guard let sketch = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch] }) else { return }
        let world = sketch.plane.point(p)
        let size = session.viewSize
        guard let screen = session.camera.project(world, viewSize: size) else { return }
        let event = ViewportToolEvent(ray: session.camera.ray(at: screen, viewSize: size), location: screen, pointer: .mouse)
        session.viewportToolBegan(event)
        session.viewportToolEnded(event)
    }

    /// What a tap on a world point would pick, through the editor's viewport (its scene and filter).
    private static func pick(_ session: DesignSession, at world: Vec3) -> PickHit? {
        guard let screen = session.camera.project(world, viewSize: session.viewSize) else { return nil }
        if let controller { return controller.pick(at: screen, pointer: .mouse) }
        return ViewportPicker().pick(scene: session.makeScene(), camera: session.camera, at: screen, viewSize: session.viewSize,
                                     filter: session.pickFilter)
    }

    /// Pointer hover over a sketch-plane point (drives the rubber-band preview).
    private static func hover(_ session: DesignSession, _ p: SIMD2<Double>) {
        guard let sketch = session.sketchEditor.flatMap({ session.model.sketches[$0.sketch] }) else { return }
        let size = session.viewSize
        guard let screen = session.camera.project(sketch.plane.point(p), viewSize: size) else { return }
        session.viewportToolHover(ViewportToolEvent(ray: session.camera.ray(at: screen, viewSize: size), location: screen, pointer: .mouse))
    }

    #if os(macOS)
    /// Typing into a focused dimension field must reach the field, not the bare-letter
    /// sketch tool shortcuts ("l" = line, "." = point), and Backspace must not delete the shape.
    private static func typeIntoDimensionField(_ session: DesignSession) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }), let content = window.contentView else { return }
        func field(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable, f.stringValue == "14" { return f }
            for s in v.subviews { if let f = field(s) { return f } }
            return nil
        }
        guard let diameter = field(content) else { check(false, "diameter field found"); return }
        let toolBefore = session.sketchEditor?.tool
        let shapesBefore = session.model.sketches.values.first?.source.shapes.count
        window.makeFirstResponder(diameter)
        try? await Task.sleep(for: .milliseconds(100))
        for (chars, code) in [("l", UInt16(37)), (".", UInt16(47)), (".", UInt16(47)), ("\u{7F}", UInt16(51))] {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        let typed = (window.firstResponder as? NSTextView)?.string ?? diameter.stringValue
        check(session.sketchEditor?.tool == toolBefore, "typing in a field keeps the sketch tool (\(String(describing: session.sketchEditor?.tool)))")
        check(typed == "l.", "typed keys reach the field (\(typed))")
        await settle(session)
        check(session.model.sketches.values.first?.source.shapes.count == shapesBefore, "Backspace in a field doesn't delete the shape")
        window.makeFirstResponder(nil)
        // The field editor's undo registration marks the untitled document edited, which
        // would make terminate wait on a save prompt; this check changed nothing in the model.
        NSDocumentController.shared.document(for: window)?.updateChangeCount(.changeCleared)
        await settle(session)
    }

    /// Select tool, through the viewport's own mouse handling: press on a shape and drag moves
    /// it live, snapped to the grid, as one undo step; a click without moving only selects.
    private static func dragToMove(_ session: DesignSession) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }), let content = window.contentView,
            let sketch = session.sketchEditor?.sketch, let plane = session.model.sketches[sketch]?.plane
        else { return }
        func find(_ v: NSView) -> MTKView? {
            if let m = v as? MTKView { return m }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let mtk = find(content) else { check(false, "viewport found"); return }
        let toolBefore = session.sketchEditor?.tool ?? .line
        session.sketchEditor?.engine.setTool(.circle)
        tap(session, SIMD2(80, 40))
        tap(session, SIMD2(85, 40))
        session.sketchEditor?.engine.setTool(.select)
        session.sketchEditor?.selectedShapes = []
        await settle(session)
        guard let circle = session.model.sketches[sketch]?.source.shapes.last?.id else { return }
        func center() -> SIMD2<Double>? {
            guard case .sketch(let s)? = session.document.feature(sketch)?.kind,
                case .circle(let c, _)? = s.shape(circle)?.kind
            else { return nil }
            return try? c.evaluate(using: .empty)
        }
        func mouse(_ type: NSEvent.EventType, _ p: SIMD2<Double>) {
            guard let screen = session.camera.project(plane.point(p), viewSize: session.viewSize) else { return }
            let location = mtk.convert(NSPoint(x: screen.x, y: mtk.bounds.height - screen.y), to: nil)
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: mtk.mouseDown(with: e)
            case .leftMouseDragged: mtk.mouseDragged(with: e)
            default: mtk.mouseUp(with: e)
            }
        }
        // No real events reach the app here, so the window's automatic undo group stays open and
        // would lump the drag in with earlier edits. A fresh manager that counts steps sees only it.
        let windowUndo = session.undoManager
        let undo = StepCountingUndoManager()
        session.undoManager = undo
        // Grab the rim of the unselected circle and drag: it selects, then moves by its centre.
        mouse(.leftMouseDown, SIMD2(85, 40))
        mouse(.leftMouseDragged, SIMD2(88, 44))
        mouse(.leftMouseDragged, SIMD2(92, 47))
        check(session.sketchEditor?.selectedShapes == [circle], "pressing an unselected shape and dragging selects it")
        check(center() == SIMD2(87, 47), "the shape follows the pointer while dragging (\(String(describing: center())))")
        check(undo.steps.isEmpty, "no undo step until the drag ends")
        await settle(session)
        mouse(.leftMouseDragged, SIMD2(95.3, 50.2))
        mouse(.leftMouseUp, SIMD2(95.3, 50.2))
        await settle(session)
        check(center() == SIMD2(90, 50), "drag moves the circle with its centre snapped to the grid (\(String(describing: center())))")
        check(undo.steps == ["Move Circle"], "the move is one undo step (\(undo.steps))")
        undo.undo()
        await settle(session)
        check(center() == SIMD2(80, 40), "undo puts the circle back (\(String(describing: center())))")
        undo.redo()
        await settle(session)
        session.undoManager = windowUndo
        // A click without moving only toggles the selection.
        mouse(.leftMouseDown, SIMD2(95, 50))
        mouse(.leftMouseUp, SIMD2(95, 50))
        await settle(session)
        check(center() == SIMD2(90, 50) && session.sketchEditor?.selectedShapes.isEmpty == true, "a click without moving only selects")
        session.sketchEditor?.selectedShapes = [circle]
        session.deleteSelectedSketchShapes()
        session.sketchEditor?.engine.setTool(toolBefore)
        await settle(session)
    }

    /// Typing sizes while drawing, through the viewport's own mouse and key handling: Tab opens
    /// the width on the canvas, the typed value locks while the pointer still picks the height,
    /// "." and "," stay digits (not the Point tool), and Return places the rectangle.
    private static func typeSizesWhileDrawing(_ session: DesignSession) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }), let content = window.contentView,
            let sketch = session.sketchEditor?.sketch, let plane = session.model.sketches[sketch]?.plane
        else { return }
        func find(_ v: NSView) -> MTKView? {
            if let m = v as? MTKView { return m }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let mtk = find(content) else { check(false, "viewport found"); return }
        func mouse(_ type: NSEvent.EventType, _ p: SIMD2<Double>) {
            guard let screen = session.camera.project(plane.point(p), viewSize: session.viewSize) else { return }
            let location = mtk.convert(NSPoint(x: screen.x, y: mtk.bounds.height - screen.y), to: nil)
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: mtk.mouseDown(with: e)
            case .mouseMoved: mtk.mouseMoved(with: e)
            default: mtk.mouseUp(with: e)
            }
        }
        func type(_ keys: String) async {
            for ch in keys {
                let code: UInt16 = ch == "\t" ? 48 : ch == "\r" ? 36 : 0
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                               charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: code)
                else { continue }
                NSApp.sendEvent(e)
                // Let the menu bar drop the bare-letter shortcuts once typing starts, as between real keys.
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        let shapesBefore = session.model.sketches[sketch]?.source.shapes.count ?? 0
        session.sketchEditor?.engine.setTool(.rectangle)
        mouse(.leftMouseDown, SIMD2(-60, 0))
        mouse(.leftMouseUp, SIMD2(-60, 0))
        mouse(.mouseMoved, SIMD2(-52.8, 6.1))
        await type("\t25.5\t12,")
        check(session.sketchEditor?.tool == .rectangle, "typing a size keeps the tool ('.' is not Point)")
        check(session.sketchEditor?.engine.locks == [0: 25.5], "Tab locks the typed width (\(String(describing: session.sketchEditor?.engine.locks)))")
        check(session.sketchEditor?.typing == SketchEditor.DimensionTyping(field: 1, text: "12,"), "the height is being typed")
        let measures = session.makeScene().measures.filter { $0.id.hasPrefix("draw-") }
        check(measures.map(\.entry) == [.locked, .typing(replacing: false)], "chips show locked width and typed height (\(measures.map(\.entry)))")
        await settle(session)
        await snap(session, "02c-typing-size")
        await type("5\r")
        await settle(session)
        let added = session.model.sketches[sketch]?.source.shapes.dropFirst(shapesBefore)
        if let shape = added?.first, added?.count == 1, case .rectangle(.corner, let pos, let w, let h, _) = shape.kind {
            check(pos == Point2Expr(-60, 0) && w == 25.5 && h == 12.5, "Return places the typed 25.5 × 12.5 rectangle (\(pos) \(w) × \(h))")
            session.sketchEditor?.selectedShapes = [shape.id]
            session.deleteSelectedSketchShapes()
        } else {
            check(false, "Return places one rectangle (\(String(describing: added)))")
        }
        check(session.sketchEditor?.typing == nil && session.sketchEditor?.engine.isIdle == true, "placing the rectangle ends typing")
        session.sketchEditor?.engine.setTool(.circle)
        await settle(session)
    }

    /// Records each undo step as the session names it (one `setActionName` per step).
    private final class StepCountingUndoManager: UndoManager {
        var steps: [String] = []
        override func setActionName(_ actionName: String) {
            if !isUndoing, !isRedoing { steps.append(actionName) }
            super.setActionName(actionName)
        }
    }
    #endif

    /// How many views carrying each `automationMarker` are currently on screen.
    static var markers: [String: Int] = [:]

    /// Where each view carrying an `automationFrame` is, in window coordinates, while it's on
    /// screen. The token tells a view's own entry from that of a newer view with the same name.
    static var frames: [String: (token: UUID, rect: CGRect)] = [:]

    private static func snap(_ session: DesignSession, _ name: String) async {
        checkLayout(session, name)
        let size = CGSize(width: max(session.viewSize.width, 400), height: max(session.viewSize.height, 300))
        if let image = ViewportRenderer.snapshot(scene: session.makeScene(), camera: session.camera, size: size, scale: 2,
                                                 appearance: snapshotAppearance) {
            write(image, name + "-viewport")
        }
        #if os(iOS)
        log("snapshot \(name)")
        try? await Task.sleep(for: iPadScreenshotPause)
        #else
        // Window management may resize an activated window; captures compare at 1600 × 1000.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }),
            window.frame.size != CGSize(width: 1600, height: 1000)
        {
            window.setFrame(NSRect(x: 40, y: 40, width: 1600, height: 1000), display: true)
            await settle(session)
        }
        // The frame view (content view's superview) includes the title bar and the window toolbar.
        if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 })?.contentView,
            let view = content.superview ?? Optional(content),
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage { write(image, name + "-window") }
        }
        if let content = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 })?.contentView {
            func find(_ v: NSView) -> NSView? {
                if v is MTKView { return v }
                for s in v.subviews { if let f = find(s) { return f } }
                return nil
            }
            if let mtk = find(content) {
                if let live = controller?.liveCamera, !live.isApproximatelyEqual(to: session.camera, tolerance: 1e-3) {
                    log("camera \(name) not landed: session yaw=\(session.camera.yaw) pitch=\(session.camera.pitch) dist=\(session.camera.distance) | live yaw=\(live.yaw) pitch=\(live.pitch) dist=\(live.distance)")
                }
                // Where the Metal view sits in the window (bottom-left origin), for compositing the captures.
                let r = mtk.convert(mtk.bounds, to: nil)
                log("geometry \(name): \(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height)) session.viewSize=\(session.viewSize) content=\(content.bounds.size) window=\(content.window?.frame ?? .zero) style=\(content.window?.styleMask.rawValue ?? 0)")
            }
        }
        log("snapshot \(name)")
        #endif
    }

    /// The viewport render follows the app's appearance, like the live viewport does.
    private static var snapshotAppearance: ViewportAppearance {
        #if os(macOS)
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        #else
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    private static func write(_ image: CGImage, _ name: String) {
        let url = outputDirectory.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

extension DesignSession {
    /// The sketch the extrude being edited uses.
    var unconsumedSketchForEditing: UUID? {
        if case .extrude(let e) = editingFeature?.kind { return e.sketch }
        return nil
    }
}
#if os(iOS)
/// The app the iPad automation launches instead of `FilletApp` (see `FilletLauncher`).
struct AutomationApp: App {
    var body: some Scene {
        WindowGroup { AutomationEditor() }
            .commands { FilletCommands() }
    }
}

/// The automation's iPad window: an editor on a fresh in-memory document, skipping the document browser.
struct AutomationEditor: View {
    @State private var document = FilletDocument()

    var body: some View {
        if let size = DebugAutomation.simulatedLandscape {
            GeometryReader { proxy in
                editor
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(proxy.size.width / size.width, anchor: .topLeading)
            }
            .background(Color.black)
            .ignoresSafeArea()
        } else {
            editor
                .frame(width: DebugAutomation.forcedWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
        }
    }

    private var editor: some View {
        NavigationStack {
            EditorView(document: $document, fileURL: nil)
        }
        .overlay {
            if DemoDirector.isEnabled { DemoTouchOverlay().ignoresSafeArea() }
        }
    }
}
#endif
#endif

#if DEBUG
/// Records the view's frame in `DebugAutomation.frames` while it's on screen.
private struct AutomationFrame: ViewModifier {
    let name: String?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                if let name { DebugAutomation.frames[name] = (token, rect) }
            }
            .onDisappear {
                if let name, DebugAutomation.frames[name]?.token == token { DebugAutomation.frames[name] = nil }
            }
    }
}
#endif

extension View {
    /// Debug builds record where views with this tag are (see `DebugAutomation.frames`), so the
    /// automation can check the layout against the window. Nil records nothing (e.g. for copies
    /// of a view that are only measured).
    func automationFrame(_ name: String?) -> some View {
        #if DEBUG
        modifier(AutomationFrame(name: name))
        #else
        self
        #endif
    }

    /// Debug builds count views with this marker while they're on screen (see `DebugAutomation.markers`),
    /// so the automation can check what the hierarchy really shows (e.g. one Finish sketch button).
    func automationMarker(_ name: String) -> some View {
        #if DEBUG
        onAppear { DebugAutomation.markers[name, default: 0] += 1 }
            .onDisappear { DebugAutomation.markers[name, default: 0] -= 1 }
        #else
        self
        #endif
    }
}
