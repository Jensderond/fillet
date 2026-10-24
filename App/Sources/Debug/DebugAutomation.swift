#if DEBUG && os(macOS)
import AppKit
import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// Debug-only end-to-end scenario: launch with `FILLET_AUTOMATION=1` and the
/// app opens a new document, drives a realistic workflow through the same
/// session entry points the UI uses (tool events with real camera rays, taps
/// with pick targets, inspector updates), and writes a snapshot of the
/// viewport and the window after every step to `$TMPDIR/fillet-automation/`.
@MainActor
enum DebugAutomation {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FILLET_AUTOMATION"] != nil }

    static let outputDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fillet-automation", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func launch() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSDocumentController.shared.newDocument(nil)
        }
    }

    private static var ran = false

    static func run(_ session: DesignSession) async {
        guard isEnabled, !ran else { return }
        ran = true
        log("output: \(outputDirectory.path)")
        try? await Task.sleep(for: .seconds(1))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }) {
            window.setFrame(NSRect(x: 40, y: 40, width: 1600, height: 1000), display: true)
        }
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
        await settle(session)
        await snap(session, "02-sketch")
        check(session.model.sketches.values.first?.regions?.count == 2, "sketch has 2 regions")

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
            session.camera = Camera(target: Vec3(40, 15, 6), distance: 220)
            await settle(session)
            await snap(session, "09-widened")
            check(session.model.status.values.allSatisfy { if case .failed = $0 { false } else { true } }, "all features ok after widening")
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
        if ProcessInfo.processInfo.environment["FILLET_AUTOMATION_KEEP_OPEN"] == nil {
            NSApp.terminate(nil)
        }
    }

    // MARK: Helpers

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log("\(ok ? "✔" : "✘") \(what)")
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

    private static func snap(_ session: DesignSession, _ name: String) async {
        let size = CGSize(width: max(session.viewSize.width, 400), height: max(session.viewSize.height, 300))
        if let image = ViewportRenderer.snapshot(scene: session.makeScene(), camera: session.camera, size: size, scale: 2) {
            write(image, name + "-viewport")
        }
        if let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 })?.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage { write(image, name + "-window") }
        }
        log("snapshot \(name)")
    }

    private static func write(_ image: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name + ".png"))
    }
}

extension DesignSession {
    /// The sketch the extrude being edited uses.
    var unconsumedSketchForEditing: UUID? {
        if case .extrude(let e) = editingFeature?.kind { return e.sketch }
        return nil
    }
}
#endif
