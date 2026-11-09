import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension TextureCatalog {
    /// The Texture tool, menu item and timeline step (patterns have their own symbols for the
    /// pattern picker).
    static let toolSymbol = "circle.hexagongrid"
}

@MainActor
private enum TextureSideCache {
    static var last: (shape: Shape, faces: [Int])?
}

/// The faces each shown relief covers, by body, with the shape and textures they were found for.
@MainActor
private enum TexturedFaceCache {
    static var faces: [BodyRef: (shape: Shape, textures: [BodyTexture], faces: Set<Int>)] = [:]
}

/// Surface textures: a texture step on picked faces of a body.
extension DesignSession {
    /// A texture on the picked faces of one body (the first face's). With no faces picked, it
    /// starts on the outer walls of the selected (or newest) body: the sides of a vase, cup or box,
    /// never its bed face or top. When it has none (a flat plate), on every face but the bed face.
    func startTexture(_ pattern: TexturePatternID? = nil) {
        let faces = selectedFaces
        guard let body = faces.first?.0 ?? selectedBodies.first ?? model.bodies.last?.ref else {
            message = "Create a body first"; return
        }
        var refs = faces.filter { $0.0 == body }.compactMap { model.faceRef(body: $0.0, face: $0.1) }
        if refs.isEmpty { refs = textureSideFaces(of: body) }
        selection = []
        let id = pattern ?? TextureCatalog.patterns.first?.id ?? .knit
        beginNewFeature(Feature(name: nextName("Texture"), .texture(Texture(body: body, faces: refs, pattern: id))))
    }

    /// The outer side faces of a body as shown (see ``TextureFaces/outerSides(of:mesh:)``).
    /// Cached per shape, since the inspector asks on every redraw.
    func textureSideFaces(of body: BodyRef) -> [FaceRef] {
        guard let shape = model.body(body)?.shape else { return [] }
        let indices: [Int]
        if let hit = TextureSideCache.last, hit.shape === shape {
            indices = hit.faces
        } else {
            indices = TextureFaces.outerSides(of: shape, mesh: model.meshes[body])
            TextureSideCache.last = (shape, indices)
        }
        return indices.compactMap { model.faceRef(body: body, face: $0) }
    }

    // MARK: Recompute feedback

    /// The textured bodies whose relief on screen is out of date. A rebuilt relief takes a
    /// fraction of a second to a couple of seconds, and until it lands the viewport shows the old
    /// one, so the editor fades it (`makeScene(fadesStaleRelief:)`) and the inspector says so.
    ///
    /// A body counts while a recompute runs whose document differs from the one `model` came
    /// from in the parameters (any step may use them), or at or before the last step that touches
    /// the body: makes it, changes it, textures it or uses it. Steps after that can't change it,
    /// so drawing a sketch further down the timeline doesn't fade a textured vase. It errs on the
    /// side of fading: an earlier change to some other body counts as well.
    var staleReliefBodies: Set<BodyRef> {
        guard isRecomputing else { return [] }
        let textured = model.bodies.filter { !$0.textures.isEmpty }
        guard !textured.isEmpty else { return [] }
        let old = modelDocument, new = document
        if old.parameters != new.parameters { return Set(textured.map(\.ref)) }
        let before = old.activeFeatures, after = new.activeFeatures
        // The steps up to here are the same in both, in the same order.
        let first = zip(before, after).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(before.count, after.count)
        guard first < max(before.count, after.count) else { return [] }
        return Set(textured.filter { body in
            let touches = { (f: Feature) in f.id == body.ref.feature || f.referencedFeatures.contains(body.ref.feature) }
            return first <= max(before.lastIndex(where: touches) ?? -1, after.lastIndex(where: touches) ?? -1)
        }.map(\.ref))
    }

    /// The texture step being edited is being rebuilt: from a change to it (or to what it lies
    /// on) until the recompute that has it lands. A new texture counts before it shows at all.
    var isEditedTextureUpdating: Bool {
        guard isRecomputing, let id = editing?.feature, let feature = document.feature(id),
            case .texture(let t) = feature.kind
        else { return false }
        return modelDocument.feature(id) != feature || staleReliefBodies.contains(t.body)
    }

    /// The faces of `body` its textures cover, as found on its shape: the faces its relief is on.
    /// Cached per shape and textures, since the scene is rebuilt on every change while it fades.
    func texturedFaces(of body: EvaluatedBody) -> Set<Int> {
        if let hit = TexturedFaceCache.faces[body.ref], hit.shape === body.shape, hit.textures == body.textures {
            return hit.faces
        }
        let faces = Set(body.textures.flatMap { TextureEngine.faces(of: $0, on: body.shape) })
        if TexturedFaceCache.faces.count > 16 { TexturedFaceCache.faces.removeAll() }
        TexturedFaceCache.faces[body.ref] = (body.shape, body.textures, faces)
        return faces
    }

    /// Sets the faces of the texture being edited (empty: every face but the bed face).
    func setTextureFaces(_ refs: [FaceRef]) {
        guard case .texture(var t) = editingFeature?.kind else { return }
        t.faces = refs
        updateEditing { $0.kind = .texture(t) }
    }
}
