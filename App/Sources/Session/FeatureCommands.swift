import FilletCore
import FilletKernel
import Foundation

/// Modelling tools on the tool strip whose availability depends on the design.
enum ModelTool {
    case extrude, revolve, fillet, chamfer, shell, combine, move, mirror, pattern, layFlat, overhangs, hole, pressPull
}

/// Creating and editing features from the current selection.
extension DesignSession {
    // MARK: Sketch

    /// The selected face a new sketch would go on, when it's planar.
    var sketchableFace: (body: BodyRef, index: Int)? {
        guard let (body, face) = selectedFaces.first, model.faceRef(body: body, face: face) != nil,
            model.body(body)?.shape.facePlane(face) != nil
        else { return nil }
        return (body, face)
    }

    /// New sketch on the given origin plane. Without one, on the selected planar face; with no
    /// such face, the viewport offers the origin planes and flat faces to pick from (like Fusion),
    /// and asking again while it does puts that away.
    func startSketch(on plane: StandardPlane? = nil) {
        if let plane {
            newSketch(on: .standard(plane, offset: 0))
            frameSketch(on: plane.plane, bounds: sketchFrameBounds(sketch: nil, plane: plane.plane))
        } else if let face = sketchableFace {
            startSketch(onFace: face.body, face.index)
        } else if choosingSketchPlane {
            cancelChoosingSketchPlane()
        } else {
            beginChoosingSketchPlane()
        }
    }

    /// New sketch on a planar face of a body (displayed face index).
    func startSketch(onFace body: BodyRef, _ index: Int) {
        guard let ref = model.faceRef(body: body, face: index), let plane = model.body(body)?.shape.facePlane(index) else { return }
        newSketch(on: .face(ref, fallback: plane))
        // Frame the face's body footprint, so the new sketch starts where the part is.
        frameSketch(on: plane, bounds: sketchFrameBounds(sketch: nil, plane: plane, on: body))
    }

    /// Shows the origin planes to pick a sketch plane from (the sketch open before is finished).
    func beginChoosingSketchPlane() {
        commitEdit()
        selection = []
        hover = nil
        choosingSketchPlane = true
        // Looking straight along an axis, two of the planes would be edge-on: turn to see all three.
        let back = camera.back.normalized
        if [Vec3.unitX, .unitY, .unitZ].contains(where: { abs(back.dot($0)) > 0.97 }) {
            var c = camera
            c.setView(.iso)
            camera = c
        }
    }

    func cancelChoosingSketchPlane() {
        choosingSketchPlane = false
        pendingSketchTool = nil
        hover = nil
    }

    /// A drawing tool's shortcut (R, C, L…). In sketch mode it switches tools; outside it starts
    /// a sketch like Sketch does, and the sketch opens with that tool (like Fusion).
    func startSketchTool(_ tool: SketchTool) {
        if sketchEditor != nil {
            sketchEditor?.engine.setTool(tool)
            return
        }
        guard tool != .select else { return }
        if isBusyEditing, let name = editingFeature?.name { message = "Finish \(name) first: Done or Cancel."; return }
        if !choosingSketchPlane { startSketch() }
        if sketchEditor != nil {
            sketchEditor?.engine.setTool(tool)
        } else if choosingSketchPlane {
            pendingSketchTool = tool
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

    // MARK: Moving shapes

    /// A press on a shape with Select that starts to drag. An unselected shape becomes the
    /// selection (or joins it with `adding`), then every selected shape moves with the pointer.
    func beginSketchMove(grabbing shape: UUID, point: Int?, at press: SIMD2<Double>, adding: Bool) -> Bool {
        guard var editor = sketchEditor, editor.tool == .select, editing?.feature == editor.sketch,
            case .sketch(let sketch) = document.feature(editor.sketch)?.kind, sketch.shape(shape) != nil
        else { return false }
        if !editor.selectedShapes.contains(shape) {
            editor.selectedShapes = adding ? editor.selectedShapes.union([shape]) : [shape]
        }
        editor.move = SketchMove(original: sketch, shapes: editor.selectedShapes, grabbed: shape, point: point,
                                 press: press, using: model.parameters.evaluator)
        sketchEditor = editor
        return true
    }

    /// Shows the shapes at the pointer, like a feature's live edit: no undo step yet.
    func dragSketchMove(to p: SIMD2<Double>, context: SnapContext) {
        guard let move = sketchEditor?.move else { return }
        let moved = move.moved(by: move.offset(to: p, context: context).offset, using: model.parameters.evaluator)
        updateEditing { $0.kind = .sketch(moved) }
    }

    /// Drops the shapes: the whole drag becomes one undo step.
    func endSketchMove(at p: SIMD2<Double>, context: SnapContext) {
        guard let move = sketchEditor?.move else { return }
        sketchEditor?.move = nil
        let offset = move.offset(to: p, context: context).offset
        // Back to where the drag began without an undo step, then the move as one step.
        updateEditing { $0.kind = .sketch(move.original) }
        guard offset != .zero else { return }
        let moved = move.moved(by: offset, using: model.parameters.evaluator)
        let name = move.shapes.count == 1 ? move.original.shapes.first { move.shapes.contains($0.id) }?.kind.typeName.capitalized : nil
        updateSketch("Move \(name ?? "Shapes")") { $0 = moved }
    }

    func cancelSketchMove() {
        guard let move = sketchEditor?.move else { return }
        sketchEditor?.move = nil
        updateEditing { $0.kind = .sketch(move.original) }
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

    /// Escape, from the keyboard on both platforms: stop choosing a sketch plane, stop typing a
    /// size, cancel the stroke in progress, then leave sketch mode, then cancel the feature being edited, then
    /// clear the selection.
    func escape() {
        if choosingSketchPlane {
            cancelChoosingSketchPlane()
        } else if stopTypingDimension() {
            return
        } else if var editor = sketchEditor, !editor.engine.isIdle {
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

    // MARK: Availability

    /// Why a modelling tool can't run right now, or nil when it can. The tool strip shows these
    /// tools as unavailable and explains with this text; menus and shortcuts post it as a toast.
    func unavailableReason(_ tool: ModelTool) -> String? {
        if isBusyEditing, let name = editingFeature?.name { return "Finish \(name) first: Done or Cancel." }
        let noBody = "Needs a body. Extrude a sketch first."
        switch tool {
        case .extrude, .revolve:
            guard let sketch = profileSketch else { return "Needs a sketch. Draw a closed shape with Sketch first." }
            if (model.sketches[sketch]?.regions?.count ?? 0) == 0 { return "Needs a closed shape in the sketch, like a rectangle or circle." }
            return nil
        case .fillet, .chamfer, .shell, .move, .mirror, .pattern, .overhangs, .hole:
            return model.bodies.isEmpty ? noBody : nil
        case .combine:
            return model.bodies.count < 2 ? (model.bodies.isEmpty ? noBody : "Needs two bodies. Make another one to join, cut or intersect with.") : nil
        case .layFlat:
            if model.bodies.isEmpty { return noBody }
            guard let (body, face) = selectedFaces.first, model.body(body)?.shape.facePlane(face) != nil else {
                return "\(Theme.Copy.pick) the flat face that should touch the bed first."
            }
            return nil
        case .pressPull:
            return pressPullUnavailableReason
        }
    }

    /// Starts a modelling tool from a menu or shortcut, or posts why it can't run.
    func startIfAvailable(_ tool: ModelTool, _ start: () -> Void) {
        if let reason = unavailableReason(tool) { message = ToastMessage(reason) } else { start() }
    }

    // MARK: Solid features

    /// The sketch an extrude/revolve should use: the open one, the newest unused one, or the newest.
    var profileSketch: UUID? {
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
            case .pressPull(var p):
                if p.faces.isEmpty { p.body = body }
                guard p.body == body else { return }
                if let i = p.faces.firstIndex(of: ref) { p.faces.remove(at: i) } else { p.faces.append(ref) }
                feature.kind = .pressPull(p)
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
            case .scale(var sc): toggle(&sc.bodies); feature.kind = .scale(sc)
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
