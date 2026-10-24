import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// How much of the viewport the editor's floating chrome covers, measured by the editor
/// for the current platform and layout (points).
struct ChromeInsets: Equatable {
    /// Top edge in sketch mode: the sketch bar and the hint under it.
    var sketchTop: Double = 116
    /// Top edge otherwise: room for the hint pill.
    var hintTop: Double = 64
    /// A floating browser over the leading edge (medium and compact layouts).
    var leading: Double = 0
}

/// Content-aware camera: frame what's being worked on, in the part of the viewport that
/// isn't covered by floating chrome. Camera changes animate through the viewport binding,
/// which cuts instead under Reduce Motion.
extension DesignSession {
    /// The unobstructed part of the viewport for the current mode.
    var viewInsets: ViewportInsets {
        ViewportInsets(top: sketchEditor != nil ? chromeInsets.sketchTop : chromeInsets.hintTop,
                       leading: chromeInsets.leading, bottom: 24, trailing: 0)
    }

    /// Bounds of the bodies that are shown.
    var visibleBodyBounds: Bounds3? {
        Bounds3(points: model.bodies.filter { !hiddenBodies.contains($0.ref) }.flatMap { body -> [Vec3] in
            guard let b = body.shape.bounds else { return [] }
            return [b.min, b.max]
        })
    }

    /// What a sketch should show when it opens: its geometry; else the face it sits on;
    /// else a 100 mm square around the plane's origin.
    func sketchFrameBounds(sketch id: UUID?, plane: Plane, on body: BodyRef? = nil) -> Bounds3 {
        var points: [Vec3] = []
        if let id, let sketch = model.sketches[id] {
            for polylines in sketch.curves.values { for line in polylines { points += line.map { plane.point($0) } } }
        }
        if points.isEmpty, let body, let b = model.body(body)?.shape.bounds {
            // The body's footprint on the sketch plane.
            for i in 0..<8 {
                let corner = Vec3(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z)
                points.append(plane.point(plane.project(corner)))
            }
        }
        if points.isEmpty {
            points = [plane.point(u: -50, v: -50), plane.point(u: 50, v: 50)]
        }
        return Bounds3(points: points) ?? Bounds3(min: plane.origin, max: plane.origin)
    }

    /// Looks straight at a sketch plane, framing `bounds` on it.
    func frameSketch(on plane: Plane, bounds: Bounds3) {
        camera = camera.looking(at: plane).framing(bounds, viewSize: viewSize, insets: viewInsets)
    }

    /// Frames the visible bodies from the current direction (⌘0 does the same in the viewport).
    func frameBodies() {
        guard let bounds = visibleBodyBounds else { return }
        camera = camera.framing(bounds, viewSize: viewSize, insets: viewInsets, margin: Self.bodyMargin)
    }

    /// Bodies get more air than sketches: the handle, its label and the shadow sit around them.
    static let bodyMargin = 1.35
    static let bedMargin = 1 / 0.7

    private var bedBounds: Bounds3 {
        let size = document.printerPreset.bedSize
        return Bounds3(min: Vec3(-size.x / 2, -size.y / 2, 0), max: Vec3(size.x / 2, size.y / 2, 0))
    }

    /// The bed filling about 70 % of the view, for an empty document.
    func frameBed() {
        camera = camera.framing(bedBounds, viewSize: viewSize, insets: viewInsets, margin: Self.bedMargin)
    }

    /// What the camera should keep in view right now (and how much room it gets): the open
    /// sketch, else the bodies, else the bed of an empty design.
    var workingBounds: (bounds: Bounds3, margin: Double)? {
        if let editor = sketchEditor, let plane = model.sketches[editor.sketch]?.plane {
            return (sketchFrameBounds(sketch: editor.sketch, plane: plane), 1.2)
        }
        if let bodies = visibleBodyBounds { return (bodies, Self.bodyMargin) }
        return document.features.isEmpty ? (bedBounds, Self.bedMargin) : nil
    }

    /// How much of the unobstructed rect the content's larger side takes (0 when it's off screen).
    private func fill(of bounds: Bounds3, viewSize: CGSize, insets: ViewportInsets) -> Double {
        guard let box = camera.screenRect(of: bounds, viewSize: viewSize) else { return 0 }
        let safe = insets.rect(in: viewSize)
        return max(Double(box.width / safe.width), Double(box.height / safe.height))
    }

    /// The viewport was resized (a panel came or went) or chrome now covers a different part
    /// of it. Content that was framed before is framed again when it no longer fits, sits
    /// off-centre or has shrunk to a corner of a much bigger view; a view the user zoomed
    /// into on purpose is left alone.
    func viewportGeometryChanged(size: CGSize, chrome: ChromeInsets) {
        let oldSize = viewSize, oldInsets = viewInsets
        viewSize = size
        chromeInsets = chrome
        guard size.width > 0, size.height > 0 else { return }
        guard hasFramedInitialView else {
            hasFramedInitialView = true
            if visibleBodyBounds != nil { frameBodies() } else if document.features.isEmpty { frameBed() }
            return
        }
        let resized = abs(size.width - oldSize.width) > oldSize.width * 0.15 || abs(size.height - oldSize.height) > oldSize.height * 0.15
        guard resized || viewInsets != oldInsets, let (content, margin) = workingBounds else { return }
        guard camera.frames(content, viewSize: oldSize, insets: oldInsets, tolerance: 0.2) else { return }
        let shrunk = fill(of: content, viewSize: size, insets: viewInsets) < fill(of: content, viewSize: oldSize, insets: oldInsets) * 0.75
        if shrunk || !camera.frames(content, viewSize: size, insets: viewInsets, tolerance: 0.12) {
            camera = camera.framing(content, viewSize: size, insets: viewInsets, margin: margin)
        }
    }

    /// Called after each recompute: the first body of a design is framed as soon as it exists,
    /// and a sketch that has grown past the visible area is framed again right after a shape
    /// lands (not while one is being dragged out, so the paper doesn't slide under the pen).
    func reframeAfterRecompute(previousBodyCount: Int) {
        guard hasFramedInitialView else { return }
        if previousBodyCount == 0, !model.bodies.isEmpty, sketchEditor == nil {
            frameBodies()
        } else if revealSketchAfterRecompute, let editor = sketchEditor, let plane = model.sketches[editor.sketch]?.plane
        {
            revealSketchAfterRecompute = false
            let bounds = sketchFrameBounds(sketch: editor.sketch, plane: plane)
            if let box = camera.screenRect(of: bounds, viewSize: viewSize),
                !viewInsets.rect(in: viewSize).insetBy(dx: -1, dy: -1).contains(box)
            {
                camera = camera.framing(bounds, viewSize: viewSize, insets: viewInsets)
            }
        }
    }
}

// MARK: - VoiceOver

extension DesignSession {
    /// What the 3D view shows, read by VoiceOver: the design, the open sketch, what's picked.
    var viewportSummary: String {
        var parts: [String] = []
        func mm(_ v: Double) -> String { ExprField.format((v * 10).rounded() / 10) }
        if let editor = sketchEditor, let sketch = model.sketches[editor.sketch] {
            let shapes = sketch.source.shapes.count
            parts.append("\(editingFeature?.name ?? "Sketch"), \(shapes) \(shapes == 1 ? "shape" : "shapes")")
        }
        let bodies = model.bodies.filter { !hiddenBodies.contains($0.ref) }
        if let b = visibleBodyBounds {
            let s = b.size
            parts.append("\(bodies.count) \(bodies.count == 1 ? "body" : "bodies"), \(mm(s.x)) × \(mm(s.y)) × \(mm(s.z)) mm")
        } else if sketchEditor == nil {
            parts.append(document.features.isEmpty ? "Empty print bed" : "No bodies yet")
        }
        func picked(_ n: Int, _ noun: String) -> String? { n > 0 ? "\(n) \(noun)\(n == 1 ? "" : "s") picked" : nil }
        switch editingFeature?.kind {
        case .fillet(let f), .chamfer(let f): picked(f.edges.count, "edge").map { parts.append($0) }
        case .shell(let s): picked(s.removeFaces.count, "face").map { parts.append($0) }
        case .extrude(let e): picked(e.regions.count, "profile").map { parts.append($0) }
        case .revolve(let r): picked(r.regions.count, "profile").map { parts.append($0) }
        default:
            if let p = picked(selectedEdges.count, "edge") { parts.append(p) }
            if let p = picked(selectedFaces.count, "face") { parts.append(p) }
        }
        if document.activeFeatureCount < document.features.count {
            parts.append("showing step \(document.activeFeatureCount) of \(document.features.count)")
        }
        return parts.joined(separator: "; ")
    }
}
