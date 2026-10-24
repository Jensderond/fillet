import FilletCore
import FilletKernel
import Foundation

/// Creating and editing features from the current selection.
extension DesignSession {
    // MARK: Sketch

    /// New sketch on the selected planar face, or on the given origin plane.
    func startSketch(on plane: StandardPlane? = nil) {
        if plane == nil, let (body, face) = selectedFaces.first, let ref = model.faceRef(body: body, face: face),
            let facePlane = model.body(body)?.shape.facePlane(face)
        {
            newSketch(on: .face(ref, fallback: facePlane))
            // Frame the face's body footprint, so the new sketch starts where the part is.
            frameSketch(on: facePlane, bounds: sketchFrameBounds(sketch: nil, plane: facePlane, on: body))
        } else {
            let p = plane ?? .xy
            newSketch(on: .standard(p, offset: 0))
            frameSketch(on: p.plane, bounds: sketchFrameBounds(sketch: nil, plane: p.plane))
        }
    }

    /// Re-opens a sketch for editing.
    func editSketch(_ id: UUID) {
        beginEdit(id)
        if let plane = model.sketches[id]?.plane { frameSketch(on: plane, bounds: sketchFrameBounds(sketch: id, plane: plane)) }
    }

    func finishSketch() {
        sketchEditor?.engine.cancel()
        commitEdit()
    }

    /// Adds drawn shapes to the open sketch as one undo step each.
    func addSketchShapes(_ shapes: [SketchShape]) {
        guard !shapes.isEmpty, let id = sketchEditor?.sketch else { return }
        updateSketch("Add \(shapes[0].kind.typeName.capitalized)") { $0.shapes += shapes }
        sketchEditor?.selectedShapes = Set(shapes.map(\.id))
        revealSketchAfterRecompute = true
        _ = id
    }

    func deleteSelectedSketchShapes() {
        guard let selected = sketchEditor?.selectedShapes, !selected.isEmpty else { return }
        updateSketch("Delete") { $0.shapes.removeAll { selected.contains($0.id) } }
        sketchEditor?.selectedShapes = []
    }

    func toggleConstructionOfSelection() {
        guard let selected = sketchEditor?.selectedShapes, !selected.isEmpty else { return }
        updateSketch("Construction") { sketch in
            for i in sketch.shapes.indices where selected.contains(sketch.shapes[i].id) {
                sketch.shapes[i].construction.toggle()
            }
        }
    }

    /// Edits the open sketch as an undoable step (sketch mode has no cancel).
    func updateSketch(_ actionName: String, _ change: (inout Sketch) -> Void) {
        guard let id = sketchEditor?.sketch, let i = document.index(of: id),
            case .sketch(var sketch) = document.features[i].kind
        else { return }
        change(&sketch)
        perform(actionName) { $0.features[i].kind = .sketch(sketch) }
        editing?.snapshot = document
    }

    /// Escape, from the keyboard on both platforms: cancel the stroke in progress, then
    /// leave sketch mode, then cancel the feature being edited, then clear the selection.
    func escape() {
        if var editor = sketchEditor, !editor.engine.isIdle {
            editor.engine.cancel()
            sketchEditor = editor
        } else if sketchEditor != nil {
            finishSketch()
        } else if editing != nil {
            cancelEdit()
        } else {
            selection = []
        }
    }

    // MARK: Solid features

    /// The sketch an extrude/revolve should use: the open one, the newest unused one, or the newest.
    private var profileSketch: UUID? {
        if let open = sketchEditor?.sketch { return open }
        if let unused = unconsumedSketch { return unused }
        return document.activeFeatures.last { if case .sketch = $0.kind { true } else { false } }?.id
    }

    private func defaultRegions(_ sketch: UUID) -> [RegionRef] {
        guard let regions = model.sketches[sketch]?.regions, regions.count == 1 else { return [] }
        return [RegionRef(regions.interiorPoint(0))]
    }

    private func sketchIsOnFace(_ sketch: UUID) -> Bool {
        if case .sketch(let s) = document.feature(sketch)?.kind, case .face = s.plane { return true }
        return false
    }

    /// When looking straight at a sketch, swing to a 3D view so the new solid is visible (like Fusion).
    private func showIn3D(_ sketch: UUID) {
        guard let plane = model.sketches[sketch]?.plane else { return }
        let headOn = abs(camera.back.normalized.dot(plane.normal)) > 0.97
        guard headOn else { return }
        var c = camera
        c.setView(.iso)
        camera = c
    }

    func startExtrude() {
        guard let sketch = profileSketch else { message = "Draw a sketch first"; return }
        if sketchEditor != nil { finishSketch() }
        showIn3D(sketch)
        let op: Operation = sketchIsOnFace(sketch) ? .join : .newBody
        beginNewFeature(Feature(name: nextName("Extrude"), .extrude(Extrude(
            sketch: sketch, regions: defaultRegions(sketch), distance: 10, operation: op))))
    }

    func startRevolve() {
        guard let sketch = profileSketch else { message = "Draw a sketch first"; return }
        if sketchEditor != nil { finishSketch() }
        showIn3D(sketch)
        var axis = RevolveAxis.y
        if case .sketch(let s) = document.feature(sketch)?.kind,
            let line = s.shapes.first(where: { if case .line = $0.kind { $0.construction } else { false } })
        {
            axis = .sketchLine(line.id)
        }
        beginNewFeature(Feature(name: nextName("Revolve"), .revolve(Revolve(
            sketch: sketch, regions: defaultRegions(sketch), axis: axis))))
    }

    func startEdgeFeature(fillet: Bool) {
        let edges = selectedEdges
        let body = edges.first?.0 ?? selectedBodies.first ?? model.bodies.last?.ref
        guard let body else { message = "Create a body first"; return }
        let refs = edges.filter { $0.0 == body }.compactMap { model.edgeRef(body: $0.0, edge: $0.1) }
        let payload = EdgeFeature(body: body, edges: refs, size: fillet ? 1 : 0.5)
        selection = []
        beginNewFeature(Feature(name: nextName(fillet ? "Fillet" : "Chamfer"), fillet ? .fillet(payload) : .chamfer(payload)))
    }

    func startShell() {
        let faces = selectedFaces
        guard let body = faces.first?.0 ?? selectedBodies.first ?? model.bodies.last?.ref else {
            message = "Create a body first"; return
        }
        let refs = faces.filter { $0.0 == body }.compactMap { model.faceRef(body: $0.0, face: $0.1) }
        selection = []
        beginNewFeature(Feature(name: nextName("Shell"), .shell(Shell(body: body, removeFaces: refs, thickness: 2))))
    }

    func startPrimitive(_ kind: PrimitiveKind) {
        let dims: [Expr] = switch kind {
        case .box: [20, 20, 20]
        case .cylinder: [20, 20]
        case .sphere: [20]
        case .cone: [20, 10, 20]
        case .torus: [30, 8]
        }
        beginNewFeature(Feature(name: nextName(kind.rawValue.capitalized), .primitive(Primitive(kind: kind, dimensions: dims))))
    }

    func startCombine() {
        let bodies = selectedBodies
        guard let target = bodies.first ?? model.bodies.first?.ref else { message = "Create two bodies first"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Combine"), .combine(Combine(target: target, tools: Array(bodies.dropFirst())))))
    }

    func startMove() {
        let bodies = selectedBodies.isEmpty ? model.bodies.map(\.ref) : selectedBodies
        guard !bodies.isEmpty else { message = "Create a body first"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Move"), .move(Move(bodies: bodies))))
    }

    func startMirror() {
        let bodies = selectedBodies.isEmpty ? model.bodies.suffix(1).map(\.ref) : selectedBodies
        guard !bodies.isEmpty else { message = "Create a body first"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Mirror"), .mirror(Mirror(bodies: bodies, plane: .standard(.yz, offset: 0)))))
    }

    func startPattern() {
        let bodies = selectedBodies.isEmpty ? model.bodies.suffix(1).map(\.ref) : selectedBodies
        guard !bodies.isEmpty else { message = "Create a body first"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Pattern"), .pattern(Pattern(
            bodies: bodies, layout: .linear(direction: .x, count: 3, spacing: 20)))))
    }

    func startLayFlat() {
        guard let (body, face) = selectedFaces.first, let ref = model.faceRef(body: body, face: face) else {
            message = "Select the flat face that should touch the bed"; return
        }
        guard model.body(body)?.shape.facePlane(face) != nil else { message = "Lay flat needs a flat face"; return }
        selection = []
        beginNewFeature(Feature(name: nextName("Lay Flat"), .layFlat(LayFlat(body: body, face: ref))))
    }

    func importSTEP(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let shape = try Shape.importSTEP(url: url)
            let name = url.deletingPathExtension().lastPathComponent
            perform("Import \(name)") { doc in
                _ = doc.addFeature(Feature(name: name, .importedSTEP(ImportedSTEP(name: name, brep: shape.brepString()))))
            }
        } catch {
            message = .error("Couldn't import \(url.lastPathComponent): \(error.userMessage)")
        }
    }

    // MARK: Picking while editing

    func toggleEditingEdge(body: BodyRef, displayedEdge index: Int) {
        guard let ref = model.edgeRefBefore(body: body, displayedEdge: index) else { return }
        updateEditing { feature in
            func toggle(_ e: inout EdgeFeature) {
                if e.edges.isEmpty { e.body = body }
                guard e.body == body else { return }
                if let i = e.edges.firstIndex(of: ref) { e.edges.remove(at: i) } else { e.edges.append(ref) }
            }
            switch feature.kind {
            case .fillet(var e): toggle(&e); feature.kind = .fillet(e)
            case .chamfer(var e): toggle(&e); feature.kind = .chamfer(e)
            default: break
            }
        }
    }

    func toggleEditingFace(body: BodyRef, displayedFace index: Int, single: Bool) {
        guard let ref = model.faceRefBefore(body: body, displayedFace: index) else { return }
        updateEditing { feature in
            switch feature.kind {
            case .shell(var s):
                if s.removeFaces.isEmpty { s.body = body }
                guard s.body == body else { return }
                if let i = s.removeFaces.firstIndex(of: ref) { s.removeFaces.remove(at: i) } else { s.removeFaces.append(ref) }
                feature.kind = .shell(s)
            case .layFlat:
                guard single, let before = model.bodyBefore(body)?.shape,
                    let i = ReferenceResolver.resolve(ref.signature, in: before.faceInfos), before.facePlane(i) != nil
                else { return }
                feature.kind = .layFlat(LayFlat(body: body, face: ref))
            default: break
            }
        }
    }

    func toggleEditingBody(_ body: BodyRef) {
        updateEditing { feature in
            func toggle(_ list: inout [BodyRef]) {
                if let i = list.firstIndex(of: body) { list.remove(at: i) } else { list.append(body) }
            }
            switch feature.kind {
            case .combine(var c):
                if c.target == body { return }
                toggle(&c.tools)
                feature.kind = .combine(c)
            case .move(var m): toggle(&m.bodies); feature.kind = .move(m)
            case .mirror(var m): toggle(&m.bodies); feature.kind = .mirror(m)
            case .pattern(var p): toggle(&p.bodies); feature.kind = .pattern(p)
            default: break
            }
        }
    }

    // MARK: Timeline

    func deleteFeature(_ id: UUID) {
        if editing?.feature == id { cancelEdit() }
        let name = document.feature(id)?.name ?? "Feature"
        perform("Delete \(name)") { doc in _ = try? doc.deleteFeature(id) }
    }

    func setSuppressed(_ id: UUID, _ suppressed: Bool) {
        perform(suppressed ? "Suppress" : "Unsuppress") { doc in try? doc.setSuppressed(id, suppressed) }
    }

    func rename(_ id: UUID, to name: String) {
        perform("Rename") { doc in try? doc.renameFeature(id, to: name) }
    }

    func moveRollbackMarker(to index: Int?) {
        commitEdit()
        perform("Move Rollback Marker") { doc in doc.moveRollbackMarker(to: index) }
    }

    func moveFeature(_ id: UUID, to index: Int) -> Bool {
        guard document.canMoveFeature(id, to: index) else { return false }
        perform("Reorder") { doc in try? doc.moveFeature(id, to: index) }
        return true
    }
}
