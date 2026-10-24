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
/// lays out at landscape size; `FILLET_WIDTH=700` narrows the editor to a Split View width.
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
    /// lays the editor out at the 13" landscape size and scales it down to fit the portrait screen.
    static var simulatedLandscape: CGSize? {
        ProcessInfo.processInfo.environment["FILLET_ORIENTATION"] == "landscape" ? CGSize(width: 1376, height: 1032) : nil
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
            // Frontmost and key, so SwiftUI updates and draws it like a window in use
            // (an occluded window gets its view updates late) and the undo state is the window's.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        #endif
        try? await Task.sleep(for: .milliseconds(300))
        await settle(session)
        await snap(session, "01-empty")

        // Sketch on the bed: a 60×30 rectangle with a Ø14 hole.
        session.startSketch(on: .xy)
        await settle(session)
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
        session.commitEdit()
        await settle(session)
        check(session.model.status.values.allSatisfy { if case .failed = $0 { false } else { true } }, "no failed features")

        // Sketch on the top face and cut a pocket.
        if let body = session.model.bodies.first,
            let top = body.shape.faceInfos.firstIndex(where: { $0.surface == .plane && $0.normal.z > 0.99 })
        {
            session.selection = [.face(body.ref, top)]
            session.startSketch()
            await settle(session)
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
        }

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
    #endif

    /// How many views carrying each `automationMarker` are currently on screen.
    static var markers: [String: Int] = [:]

    private static func snap(_ session: DesignSession, _ name: String) async {
        let size = CGSize(width: max(session.viewSize.width, 400), height: max(session.viewSize.height, 300))
        if let image = ViewportRenderer.snapshot(scene: session.makeScene(), camera: session.camera, size: size, scale: 2,
                                                 appearance: snapshotAppearance) {
            write(image, name + "-viewport")
        }
        #if os(iOS)
        log("snapshot \(name)")
        try? await Task.sleep(for: iPadScreenshotPause)
        #else
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
                log("geometry \(name): \(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height)) session.viewSize=\(session.viewSize) content=\(content.bounds.size)")
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
    }
}
#endif
#endif

extension View {
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
