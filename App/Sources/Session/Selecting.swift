import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// What a selection box picks outside a step (a step decides for itself: Fillet picks edges…).
enum BoxPicks: String, CaseIterable, Hashable {
    case edges, faces, bodies

    var filter: PickFilter {
        switch self {
        case .edges: .edges
        case .faces: .faces
        case .bodies: .bodies
        }
    }

    var title: String { rawValue.capitalized }
}

/// Picking more than one thing at a time: the selection conventions (`SelectionRules`), double
/// tap for an edge's loop, tangent chains and selection boxes. Changing the selection is never an
/// undo step; picking edges or faces for a step is part of that step's edit.
extension DesignSession {
    /// The state a tap changed, so a double tap can take the first tap back and pick the loop instead.
    enum TapUndo {
        case selection([Selection])
        /// The step's picks before the tap, and the edge it tapped on the body before the step.
        /// (The tap changes the step's result, so the second tap of a double tap lands on a body
        /// whose edges are numbered differently; the first tap's edge is the one meant.)
        case feature(UUID, FeatureKind, edge: (body: BodyRef, index: Int)?)
    }

    /// Remembers what the coming tap on `target` may change (see `TapUndo`).
    func noteTap(_ target: PickTarget?) {
        if pickMode == .idle {
            tapUndo = .selection(selection)
        } else if let f = editingFeature {
            var edge: (BodyRef, Int)?
            if pickMode == .edges, case .edge(let b, let i)? = target, let (_, before) = beforeEdge(body: BodyRef(b), displayedEdge: i) {
                edge = (BodyRef(b), before)
            }
            tapUndo = .feature(f.id, f.kind, edge: edge)
        } else {
            tapUndo = nil
        }
    }

    /// Takes back the first tap of a double tap.
    private func undoFirstTap() {
        switch tapUndo {
        case .selection(let s)?: selection = s
        case .feature(let id, let kind, _)? where editingFeature?.id == id:
            updateEditing { $0.kind = kind }
        default: break
        }
        tapUndo = nil
    }

    // MARK: Taps

    /// A tap or click outside a step (see `SelectionRules`): a click replaces, a touch adds, Shift
    /// or ⌘ toggles; on empty space, it clears.
    func selectionTapped(_ target: PickTarget?, modifiers: ViewportModifiers, pointer: PointerKind) {
        guard let target, let s = Selection(target) else {
            if SelectionRules.tapOnNothingClears(modifiers: modifiers) { selection = [] }
            return
        }
        selection = SelectionRules.apply(SelectionRules.tap(modifiers: modifiers, pointer: pointer), [s], to: selection)
    }

    /// Double tap on an edge: its loop, around the face beside it under the pointer (Fusion's
    /// double click). It replaces what the first tap did. False when a double tap means nothing
    /// here (not an edge, or no edges to pick): the second tap is then an ordinary tap.
    @discardableResult
    func doubleTapped(_ target: PickTarget?, face: PickTarget?, modifiers: ViewportModifiers, pointer: PointerKind) -> Bool {
        guard case .edge(let bodyID, let index)? = target else { return false }
        let body = BodyRef(bodyID)
        var faceIndex: Int?
        if case .face(let b, let f)? = face, b == bodyID { faceIndex = f }
        switch pickMode {
        case .idle:
            guard let shape = model.body(body)?.shape,
                let loop = loopEdges(on: shape, edge: index, preferredFace: faceIndex)
            else { return false }
            undoFirstTap()
            selection = SelectionRules.apply(SelectionRules.tap(modifiers: modifiers, pointer: pointer),
                                             loop.map { .edge(body, $0) }, to: selection)
            announce("\(loop.count) edges in the loop selected")
            return true
        case .edges:
            guard let before = model.bodyBefore(body)?.shape else { return false }
            var first: Int?
            if case .feature(_, _, let tapped?)? = tapUndo, tapped.body == body { first = tapped.index }
            guard let edge = first ?? beforeEdge(body: body, displayedEdge: index)?.1 else { return false }
            let beforeFace = faceIndex.flatMap { model.faceRefBefore(body: body, displayedFace: $0) }
                .flatMap { ReferenceResolver.resolve($0.signature, in: before.faceInfos) }
            guard let loop = loopEdges(on: before, edge: edge, preferredFace: beforeFace) else { return false }
            undoFirstTap()
            addEditingEdges(body: body, beforeEdges: loop, toggle: false)
            announce("Loop of \(loop.count) edges picked")
            return true
        default:
            return false
        }
    }

    /// The loop of an edge on one of its faces: `preferredFace` when the edge bounds it, else the
    /// face turned most towards the viewer.
    func loopEdges(on shape: Shape, edge: Int, preferredFace: Int?) -> [Int]? {
        let faces = shape.edgeFaces(edge)
        let back = camera.back.normalized
        let face = preferredFace.flatMap { faces.contains($0) ? $0 : nil }
            ?? faces.max { shape.faceInfo($0).normal.dot(back) < shape.faceInfo($1).normal.dot(back) }
        guard let face else { return nil }
        return shape.loop(of: face, through: edge)
    }

    /// The body before the step being edited and the index on it of an edge picked on the
    /// displayed result.
    private func beforeEdge(body: BodyRef, displayedEdge index: Int) -> (Shape, Int)? {
        guard let ref = model.edgeRefBefore(body: body, displayedEdge: index), let before = model.bodyBefore(body)?.shape,
            let i = ReferenceResolver.resolve(ref.signature, in: before.edgeInfos)
        else { return nil }
        return (before, i)
    }

    // MARK: Chains and loops from the selection

    /// The last selected edge, which "Select tangent chain" and "Select loop" grow from.
    var lastSelectedEdge: (body: BodyRef, index: Int)? {
        for case .edge(let b, let i) in selection.reversed() { return (b, i) }
        return nil
    }

    /// Adds the tangent chain of the last selected edge to the selection.
    func selectTangentChain() {
        guard let (body, index) = lastSelectedEdge, let shape = model.body(body)?.shape else { return }
        let chain = shape.tangentChain(from: index)
        selection = SelectionRules.apply(.add, chain.map { .edge(body, $0) }, to: selection)
        announce(chain.count == 1 ? "The edge has no tangent neighbours" : "\(chain.count) edges in the chain selected")
    }

    /// Adds the loop of the last selected edge (around the face turned most towards the viewer).
    func selectLoop() {
        guard let (body, index) = lastSelectedEdge, let shape = model.body(body)?.shape,
            let loop = loopEdges(on: shape, edge: index, preferredFace: nil)
        else { return }
        selection = SelectionRules.apply(.add, loop.map { .edge(body, $0) }, to: selection)
        announce("\(loop.count) edges in the loop selected")
    }

    // MARK: Picking edges for a fillet or chamfer

    /// A tap on an edge while a fillet or chamfer is open: picks it, or takes it out again. With
    /// "Tangent chain" on, a tap picks the edge as the seed of its chain, and a tap anywhere on a
    /// picked chain takes the whole chain out.
    func toggleEditingEdge(body: BodyRef, displayedEdge index: Int) {
        guard let (before, edge) = beforeEdge(body: body, displayedEdge: index) else { return }
        updateEditing { feature in
            func toggle(_ e: inout EdgeFeature) {
                if e.edges.isEmpty { e.body = body }
                guard e.body == body else { return }
                let group = Set(e.tangentChain ? before.tangentChain(from: edge) : [edge])
                let hits = e.edges.indices.filter { k in
                    ReferenceResolver.resolve(e.edges[k].signature, in: before.edgeInfos).map(group.contains) ?? false
                }
                if hits.isEmpty {
                    e.edges.append(EdgeRef(body: body, signature: EdgeSignature(before.edgeInfo(edge))))
                } else {
                    e.edges.remove(atOffsets: IndexSet(hits))
                }
            }
            switch feature.kind {
            case .fillet(var e): toggle(&e); feature.kind = .fillet(e)
            case .chamfer(var e): toggle(&e); feature.kind = .chamfer(e)
            default: break
            }
        }
    }

    /// Adds edges of the body before the step (a loop, a box's edges) to the fillet or chamfer
    /// being edited. With "Tangent chain" on, only edges no picked chain covers yet become picks,
    /// so a loop adds one pick per chain. `toggle`: when every edge is picked already, they go.
    func addEditingEdges(body: BodyRef, beforeEdges edges: [Int], toggle: Bool) {
        guard let before = model.bodyBefore(body)?.shape, !edges.isEmpty else { return }
        updateEditing { feature in
            func add(_ e: inout EdgeFeature) {
                if e.edges.isEmpty { e.body = body }
                guard e.body == body else { return }
                let resolved = e.edges.map { ReferenceResolver.resolve($0.signature, in: before.edgeInfos) }
                var covered = Set(e.expandedEdges(resolved, on: before))
                if toggle, Set(edges).isSubset(of: covered) {
                    let out = Set(edges.flatMap { e.tangentChain ? before.tangentChain(from: $0) : [$0] })
                    e.edges = zip(e.edges, resolved).filter { _, i in i.map { !out.contains($0) } ?? true }.map(\.0)
                    return
                }
                for i in edges where !covered.contains(i) {
                    e.edges.append(EdgeRef(body: body, signature: EdgeSignature(before.edgeInfo(i))))
                    covered.formUnion(e.tangentChain ? before.tangentChain(from: i) : [i])
                }
            }
            switch feature.kind {
            case .fillet(var e): add(&e); feature.kind = .fillet(e)
            case .chamfer(var e): add(&e); feature.kind = .chamfer(e)
            default: break
            }
        }
    }

    /// Turns "Tangent chain" on or off for the fillet or chamfer being edited. Off, each chain
    /// becomes its edges, picked one by one, so what is rounded stays the same and single edges
    /// can then be taken out. On, the picks become seeds again.
    func setTangentChain(_ on: Bool) {
        guard let id = editing?.feature else { return }
        let resolved = model.resolvedEdges[id]
        updateEditing { feature in
            func set(_ e: inout EdgeFeature) {
                guard e.tangentChain != on else { return }
                if !on, let resolved, !resolved.isEmpty {
                    e.edges = resolved.map { EdgeRef(body: e.body, signature: EdgeSignature($0)) }
                }
                e.tangentChain = on
            }
            switch feature.kind {
            case .fillet(var e): set(&e); feature.kind = .fillet(e)
            case .chamfer(var e): set(&e); feature.kind = .chamfer(e)
            default: break
            }
        }
    }

    // MARK: Selection boxes

    /// What a selection box picks right now: the step's kind of pick, or the box's choice outside a
    /// step. Nothing in a sketch, while choosing a plane, placing holes or measuring: drags navigate.
    var boxFilter: PickFilter {
        switch pickMode {
        case .idle: editingFeature == nil ? boxPicks.filter : []
        case .edges: .edges
        case .faces: .faces
        case .bodies: .bodies
        default: []
        }
    }

    /// Why box select can't be used right now, or nil.
    var boxSelectUnavailableReason: String? {
        boxFilter.isEmpty ? "Box select picks edges, faces or bodies. Finish this first." : nil
    }

    func toggleBoxSelect() {
        boxSelecting.toggle()
        announce(boxSelecting ? "Box select on. Drag to select." : "Box select off")
    }

    /// A selection box was let go (see `SelectionRules.box`). In a step, boxes add to its picks
    /// (⌘ toggles), whatever the input.
    func boxSelected(_ targets: [PickTarget], box: SelectionBox) {
        switch pickMode {
        case .idle:
            let picked = targets.compactMap(Selection.init)
            selection = SelectionRules.apply(box.update, picked, to: selection)
            announce(picked.isEmpty ? "Nothing in the box" : "\(picked.count) selected")
        case .edges:
            var byBody: [UUID: [Int]] = [:]
            for case .edge(let b, let i) in targets { byBody[b, default: []].append(i) }
            for (bodyID, displayed) in byBody {
                let body = BodyRef(bodyID)
                let before = displayed.compactMap { beforeEdge(body: body, displayedEdge: $0)?.1 }
                addEditingEdges(body: body, beforeEdges: before, toggle: box.update == .toggle)
            }
            announce(targets.isEmpty ? "No edges in the box" : "\(targets.count) edges boxed")
        case .faces:
            for case .face(let b, let i) in targets {
                guard let ref = model.faceRefBefore(body: BodyRef(b), displayedFace: i) else { continue }
                let picked = editingFaceRefs.contains(ref)
                if box.update == .toggle || !picked { toggleEditingFace(body: BodyRef(b), displayedFace: i, single: false) }
            }
            announce(targets.isEmpty ? "No faces in the box" : "\(targets.count) faces boxed")
        case .bodies:
            let current = editingFeature?.kind.selectedBodies ?? []
            for case .body(let b) in targets where box.update == .toggle || !current.contains(BodyRef(b)) {
                toggleEditingBody(BodyRef(b))
            }
        default:
            break
        }
    }

    /// The faces the shell or press pull being edited has picked.
    private var editingFaceRefs: [FaceRef] {
        switch editingFeature?.kind {
        case .shell(let s): s.removeFaces
        case .pressPull(let p): p.faces
        default: []
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
