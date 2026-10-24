import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// What tapping in the viewport does right now.
enum PickMode: Equatable {
    case idle
    /// Sketch mode with the select tool (or a drawing tool, which takes tool input instead).
    case sketch
    /// Choosing profile regions of a sketch (extrude, revolve).
    case regions(sketch: UUID)
    /// Choosing edges (fillet, chamfer).
    case edges
    /// Choosing faces (shell).
    case faces
    /// Choosing a single face (lay flat).
    case singleFace
    /// Choosing bodies (combine, move, mirror, pattern).
    case bodies
}

extension DesignSession {
    var pickMode: PickMode {
        if sketchEditor != nil { return .sketch }
        guard let feature = editingFeature else { return .idle }
        switch feature.kind {
        case .extrude(let e): return .regions(sketch: e.sketch)
        case .revolve(let r): return .regions(sketch: r.sketch)
        case .fillet, .chamfer: return .edges
        case .shell: return .faces
        case .layFlat: return .singleFace
        case .combine, .move, .mirror, .pattern: return .bodies
        default: return .idle
        }
    }

    var pickFilter: PickFilter {
        switch pickMode {
        case .idle: [.faces, .edges]
        case .sketch: sketchEditor?.tool == .select ? [.sketchCurves, .sketchPoints] : []
        case .regions: [.regions, .handles]
        case .edges: [.edges]
        case .faces, .singleFace, .bodies: [.faces]
        }
    }

    // MARK: Scene

    func makeScene() -> ViewportScene {
        var scene = ViewportScene()
        let selected = Set(selection.compactMap(\.pickTarget))
        for body in model.bodies {
            let mesh = model.meshes[body.ref] ?? .empty
            var highlight = BodyHighlight.none
            if pickMode == .bodies, case .some(let f) = editingFeature, f.kind.selectedBodies.contains(body.ref) {
                highlight = .selected
            } else if selection.contains(.body(body.ref)) {
                highlight = .selected
            }
            scene.bodies.append(SceneBody(
                id: body.ref.feature, mesh: mesh, version: ObjectIdentifier(body.shape).hashValue,
                visible: !hiddenBodies.contains(body.ref), highlight: highlight))
        }
        scene.selection = selected.union(editingSelectionTargets())
        scene.hover = hover?.pickTarget
        let preset = document.printerPreset
        scene.plate = BuildPlate(name: preset.name, size: preset.bedSize)
        if showOverhangs {
            let minZ = model.bodies.compactMap { $0.shape.bounds?.min.z }.min() ?? 0
            scene.overhang = OverhangStyle(thresholdDegrees: overhangAngle, bedZ: minZ)
        }
        scene.sketch = sketchOverlay()
        scene.handles = editingHandles()
        scene.measures = sketchMeasures() + handleMeasures(scene.handles)
        scene.edgeHighlights = edgeHighlights()
        return scene
    }

    /// Edges/faces of the feature being edited, shown as selected on the displayed result.
    private func editingSelectionTargets() -> Set<PickTarget> {
        guard let feature = editingFeature else { return [] }
        var targets: Set<PickTarget> = []
        switch feature.kind {
        // A fillet's or chamfer's edges are gone from its result, so resolving them there lands on
        // whatever edge is nearest (after a widening, one inside a pocket). They are drawn dashed
        // from the edges the evaluator resolved instead (`edgeHighlights`).
        case .shell(let s):
            for ref in s.removeFaces { if let i = model.resolve(ref) { targets.insert(.face(body: ref.body.feature, index: i)) } }
        case .layFlat(let l):
            if let i = model.resolve(l.face) { targets.insert(.face(body: l.body.feature, index: i)) }
        default: break
        }
        return targets
    }

    private func sketchOverlay() -> SketchOverlay? {
        let sketchID: UUID
        var regionsSelectable = false
        var selectedRegions: [RegionRef] = []
        switch pickMode {
        case .sketch:
            guard let id = sketchEditor?.sketch else { return nil }
            sketchID = id
        case .regions(let id):
            sketchID = id
            regionsSelectable = true
            if case .extrude(let e) = editingFeature?.kind { selectedRegions = e.regions }
            if case .revolve(let r) = editingFeature?.kind { selectedRegions = r.regions }
        default:
            guard let id = unconsumedSketch else { return nil }
            sketchID = id
        }
        guard let evaluated = model.sketches[sketchID] else { return nil }
        var overlay = SketchOverlay(plane: evaluated.plane)
        let editor = sketchEditor?.sketch == sketchID ? sketchEditor : nil

        // The revolve axis chosen from the sketch's lines shows as picked.
        var axisLine: UUID?
        if case .revolve(let r) = editingFeature?.kind, case .sketchLine(let id) = r.axis { axisLine = id }
        for shape in evaluated.source.shapes {
            var style: SketchCurveStyle = shape.construction ? .construction : .normal
            if editor?.selectedShapes.contains(shape.id) == true || shape.id == axisLine { style = .selected }
            else if hover == .sketchShape(sketch: sketchID, shape: shape.id) { style = .hover }
            for line in evaluated.curves[shape.id] ?? [] {
                overlay.curves.append(SketchCurve(shapeID: shape.id, points: line, style: style))
            }
            if editor != nil {
                for (i, p) in shape.snapPoints(using: model.parameters.evaluator).enumerated() where p.kind != .quadrant {
                    overlay.points.append(SketchPoint(shapeID: shape.id, index: i, position: p.position))
                }
            }
        }
        if let regions = evaluated.regions {
            for (i, triangles) in evaluated.regionFills.enumerated() {
                let selected = regionsSelectable && selectedRegions.contains { regions.region(containing: $0.point) == i }
                let hovered = regionsSelectable && hover == .region(sketch: sketchID, index: i)
                overlay.regions.append(SketchRegion(index: i, triangles: triangles, selected: selected, hover: hovered))
            }
        }
        if let editor {
            for line in editor.engine.preview() {
                overlay.curves.append(SketchCurve(shapeID: UUID(), points: line, style: .preview))
            }
            if editor.tool != .select, let c = editor.engine.cursor {
                overlay.points.append(SketchPoint(shapeID: UUID(), index: 0, position: c, style: .snap))
            }
            overlay.grid = adaptiveGrid(snap: editor.gridSize, plane: evaluated.plane)
        }
        return overlay
    }

    /// Grid lines that show the snap step itself when zoomed in enough, coarser
    /// round steps (×5, ×10…) when zoomed out; major lines land on round values.
    private func adaptiveGrid(snap: Double, plane: Plane) -> SketchGrid {
        let base = snap > 0 ? snap : 1
        let mmPerPoint = max(camera.worldUnitsPerPoint(at: plane.origin, viewSize: viewSize), 1e-6)
        let minSpacing = 4 * mmPerPoint  // lines no closer than ~4 pt on screen
        var minor = base
        var multipliers = [5.0, 2.0].makeIterator()  // 1 → 5 → 10 → 50 → 100…
        while minor < minSpacing {
            guard let m = multipliers.next() else { multipliers = [5.0, 2.0].makeIterator(); continue }
            minor *= m
        }
        let leading = minor / pow(10, floor(log10(minor)))
        let majorEvery = abs(leading - 1) < 1e-6 ? 10 : 2
        let visible = Double(max(viewSize.width, viewSize.height)) * mmPerPoint
        return SketchGrid(spacing: minor, majorEvery: majorEvery, extent: max(200, visible * 1.5))
    }

    /// Live dimensions of the shape being drawn.
    private func sketchMeasures() -> [MeasureAnnotation] {
        guard let editor = sketchEditor, let plane = model.sketches[editor.sketch]?.plane else { return [] }
        let dims = editor.engine.previewDimensions()
        guard !dims.isEmpty else { return [] }
        // Like dimension lines on a drawing: offset each one outward, away from the shape's middle.
        let all = dims.flatMap { [$0.from, $0.to] }
        let centre = all.reduce(SIMD2<Double>(0, 0), +) / Double(all.count)
        let gap = 16 * camera.worldUnitsPerPoint(at: plane.origin, viewSize: viewSize)
        return dims.enumerated().map { i, d in
            let along = d.to - d.from
            let length = (along.x * along.x + along.y * along.y).squareRoot()
            var offset = SIMD2<Double>(0, 0)
            if dims.count > 1, length > 1e-9 {
                var normal = SIMD2(-along.y, along.x) / length
                let mid = (d.from + d.to) / 2
                if ((mid - centre) * normal).sum() < 0 { normal = -normal }
                offset = normal * gap
            }
            return MeasureAnnotation(id: "draw-\(i)", from: plane.point(d.from + offset), to: plane.point(d.to + offset), label: d.label)
        }
    }

    /// The newest sketch no feature uses yet (shown so it can be extruded).
    var unconsumedSketch: UUID? {
        let active = document.activeFeatures
        let used = Set(active.flatMap(\.referencedFeatures))
        return active.last { if case .sketch = $0.kind { !used.contains($0.id) } else { false } }?.id
    }

    private func editingHandles() -> [Handle] {
        guard case .extrude(let e) = editingFeature?.kind, let sketch = model.sketches[e.sketch],
            let regions = sketch.regions, let first = e.regions.first,
            let distance = try? model.parameters.evaluator.length(e.distance)
        else { return [] }
        let anchor = regions.region(containing: first.point).map { regions.interiorPoint($0) } ?? first.point
        // Orange: it manipulates the feature being edited (active), not something picked.
        return [Handle(id: "distance", origin: sketch.plane.point(anchor), direction: sketch.plane.normal, value: distance,
                       color: ViewportColor(hex: 0xF26B1D))]
    }

    /// The live value beside each handle's arrowhead, so dragging shows the distance on the canvas.
    private func handleMeasures(_ handles: [Handle]) -> [MeasureAnnotation] {
        handles.map { h in
            let perPoint = camera.worldUnitsPerPoint(at: h.tip, viewSize: viewSize)
            let beside = h.tip + h.direction * (60 * perPoint)  // past the 48 pt arrow
            return MeasureAnnotation(id: "handle-\(h.id)", from: beside, to: beside,
                                     label: "\(ExprField.format(h.value)) mm", showsLine: false)
        }
    }
}

// MARK: - Input

extension DesignSession: ViewportDelegate {
    var wantsToolInput: Bool {
        guard let editor = sketchEditor else { return false }
        return editor.tool != .select
    }

    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers) {
        switch pickMode {
        case .idle:
            guard let target, let s = Selection(target) else { selection = []; return }
            toggleSelection(s, additive: true)
        case .sketch:
            guard let id = sketchEditor?.sketch else { return }
            switch target {
            case .sketchShape(let shape), .sketchPoint(let shape, _):
                guard model.sketches[id]?.source.shape(shape) != nil else { return }
                if sketchEditor?.selectedShapes.contains(shape) == true {
                    sketchEditor?.selectedShapes.remove(shape)
                } else {
                    sketchEditor?.selectedShapes.insert(shape)
                }
            default:
                sketchEditor?.selectedShapes = []
            }
        case .regions(let sketchID):
            guard case .region(let index) = target, let regions = model.sketches[sketchID]?.regions else { return }
            updateEditing { feature in
                func toggle(_ refs: inout [RegionRef]) {
                    if let i = refs.firstIndex(where: { regions.region(containing: $0.point) == index }) {
                        refs.remove(at: i)
                    } else {
                        refs.append(RegionRef(regions.interiorPoint(index)))
                    }
                }
                if case .extrude(var e) = feature.kind { toggle(&e.regions); feature.kind = .extrude(e) }
                if case .revolve(var r) = feature.kind { toggle(&r.regions); feature.kind = .revolve(r) }
            }
        case .edges:
            guard case .edge(let bodyID, let index) = target else { return }
            toggleEditingEdge(body: BodyRef(bodyID), displayedEdge: index)
        case .faces, .singleFace:
            guard case .face(let bodyID, let index) = target else { return }
            toggleEditingFace(body: BodyRef(bodyID), displayedFace: index, single: pickMode == .singleFace)
        case .bodies:
            guard let bodyID = target?.bodyID else { return }
            toggleEditingBody(BodyRef(bodyID))
        }
    }

    func viewportHoverChanged(target: PickTarget?) {
        let sketchID = sketchEditor?.sketch ?? { if case .regions(let s) = pickMode { s } else { nil } }()
        switch target {
        case .region(let i): hover = sketchID.map { .region(sketch: $0, index: i) }
        case .sketchShape(let shape), .sketchPoint(let shape, _): hover = sketchID.map { .sketchShape(sketch: $0, shape: shape) }
        case .some(let t): hover = Selection(t)
        case nil: hover = nil
        }
    }

    func viewportToolHover(_ event: ViewportToolEvent) {
        guard let (p, ctx) = sketchInput(event) else { return }
        sketchEditor?.engine.hover(p, context: ctx)
    }

    func viewportToolBegan(_ event: ViewportToolEvent) {
        guard let (p, ctx) = sketchInput(event) else { return }
        sketchEditor?.engine.press(p, context: ctx)
    }

    func viewportToolMoved(_ event: ViewportToolEvent) {
        guard let (p, ctx) = sketchInput(event) else { return }
        sketchEditor?.engine.drag(p, context: ctx)
    }

    func viewportToolEnded(_ event: ViewportToolEvent) {
        guard let (p, ctx) = sketchInput(event), let shapes = sketchEditor?.engine.release(p, context: ctx) else { return }
        addSketchShapes(shapes)
    }

    func viewportToolCancelled() {
        sketchEditor?.engine.cancel()
    }

    func viewportHandleDragged(id: String, value: Double) {
        guard id == "distance" else { return }
        let rounded = (value * 10).rounded() / 10
        updateEditing { feature in
            if case .extrude(var e) = feature.kind {
                e.distance = Expr(rounded == 0 ? 0.1 : rounded)
                feature.kind = .extrude(e)
            }
        }
    }

    func viewportCameraChanged(_ camera: Camera) {
        self.camera = camera
    }

    func viewportPencilToolSwitch() {
        sketchEditor?.switchPencilTool()
    }

    // MARK: Helpers

    /// Projects a tool event onto the open sketch's plane, with snapping context.
    private func sketchInput(_ event: ViewportToolEvent) -> (SIMD2<Double>, SnapContext)? {
        guard let editor = sketchEditor, let evaluated = model.sketches[editor.sketch],
            let world = evaluated.plane.intersect(rayOrigin: event.ray.origin, direction: event.ray.direction)
                ?? evaluated.plane.intersect(rayOrigin: event.ray.origin, direction: -event.ray.direction)
        else { return nil }
        let p = evaluated.plane.project(world)
        let ev = model.parameters.evaluator
        var points = evaluated.source.shapes.flatMap { $0.snapPoints(using: ev) }
        points.append(SnapPoint(position: .zero, kind: .point, shape: UUID()))  // sketch origin
        let perPoint = camera.worldUnitsPerPoint(at: world, viewSize: viewSize)
        let tolerance = perPoint * event.pointer.tolerance * 1.5
        return (p, SnapContext(points: points, tolerance: tolerance, gridSize: editor.gridSize))
    }
}

extension Selection {
    init?(_ target: PickTarget) {
        switch target {
        case .face(let b, let i): self = .face(BodyRef(b), i)
        case .edge(let b, let i): self = .edge(BodyRef(b), i)
        case .body(let b): self = .body(BodyRef(b))
        default: return nil
        }
    }

    var pickTarget: PickTarget? {
        switch self {
        case .face(let b, let i): .face(body: b.feature, index: i)
        case .edge(let b, let i): .edge(body: b.feature, index: i)
        case .body(let b): .body(b.feature)
        case .region(_, let i): .region(i)
        case .sketchShape(_, let s): .sketchShape(s)
        }
    }
}

extension FeatureKind {
    /// Bodies a body-level feature (combine, move, mirror, pattern) operates on.
    var selectedBodies: [BodyRef] {
        switch self {
        case .combine(let c): [c.target] + c.tools
        case .move(let m): m.bodies
        case .mirror(let m): m.bodies
        case .pattern(let p): p.bodies
        default: []
        }
    }
}
