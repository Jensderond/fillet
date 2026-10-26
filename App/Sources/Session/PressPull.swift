import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// Press Pull, Fusion's context-aware tool: it does what fits the selection.
extension DesignSession {
    /// Picked edges get a fillet. A sketch with a profile to use (the open one, one no feature
    /// uses yet, or any when there is no body) gets an extrude, unless faces are picked. Otherwise
    /// a Press Pull of the picked faces starts; with none picked, faces are picked in the viewport.
    func startPressPull() {
        if !selectedEdges.isEmpty {
            startEdgeFeature(fillet: true)
        } else if let sketch = profileSketch, hasProfiles(sketch),
            sketchEditor != nil || (selectedFaces.isEmpty && (sketch == unconsumedSketch || model.bodies.isEmpty))
        {
            startExtrude()
        } else {
            startPressPullFaces()
        }
    }

    /// A Press Pull of the picked faces of one body (the first face's), or of no faces yet.
    func startPressPullFaces() {
        let faces = selectedFaces
        guard let body = faces.first?.0 ?? selectedBodies.first ?? model.bodies.last?.ref else {
            message = "Create a body first"; return
        }
        let refs = faces.filter { $0.0 == body }.compactMap { model.faceRef(body: $0.0, face: $0.1) }
        selection = []
        beginNewFeature(Feature(name: nextName("Press Pull"), .pressPull(PressPull(body: body, faces: refs, distance: 2))))
    }

    private func hasProfiles(_ sketch: UUID) -> Bool { (model.sketches[sketch]?.regions?.count ?? 0) > 0 }

    /// Why Press Pull can't run (besides another feature being open): it needs a body or a profile.
    var pressPullUnavailableReason: String? {
        if !model.bodies.isEmpty { return nil }
        if let sketch = profileSketch, hasProfiles(sketch) { return nil }
        return "Needs a body or a closed shape in a sketch. Draw one with Sketch first."
    }

    // MARK: Viewport

    static let pressPullHandleID = "pressPull"

    /// An arrow from the first flat face's place before the step to where it is moved, dragged
    /// to change the distance (like the extrude arrow).
    func pressPullHandles(_ p: PressPull) -> [Handle] {
        guard let before = model.bodyBefore(p.body)?.shape,
            let distance = try? model.parameters.evaluator.length(p.distance)
        else { return [] }
        for ref in p.faces {
            guard let i = ReferenceResolver.resolve(ref.signature, in: before.faceInfos), let plane = before.facePlane(i) else { continue }
            return [Handle(id: Self.pressPullHandleID, origin: plane.origin, direction: plane.normal, value: distance,
                           color: ViewportColor(hex: 0xF26B1D))]
        }
        return []
    }

    func dragPressPullHandle(to value: Double) {
        let rounded = (value * 10).rounded() / 10
        updateEditing { feature in
            guard case .pressPull(var p) = feature.kind else { return }
            p.distance = Expr(rounded == 0 ? (value < 0 ? -0.1 : 0.1) : rounded)
            feature.kind = .pressPull(p)
        }
    }

    /// The picked faces as shown, where the step moved them: each signature shifted along its
    /// normal by the distance, then found on the displayed body.
    func pressPullSelectionTargets(_ p: PressPull) -> Set<PickTarget> {
        guard let shown = model.body(p.body)?.shape else { return [] }
        let distance = model.error(for: editing?.feature ?? UUID()) == nil ? (try? model.parameters.evaluator.length(p.distance)) ?? 0 : 0
        let infos = shown.faceInfos
        var targets: Set<PickTarget> = []
        for ref in p.faces {
            var moved = ref.signature
            if moved.surface == .plane { moved.centroid = moved.centroid + moved.normal.normalized * distance }
            if let i = ReferenceResolver.resolve(moved, in: infos) { targets.insert(.face(body: p.body.feature, index: i)) }
        }
        return targets
    }
}
