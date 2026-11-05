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

    /// Sets the faces of the texture being edited (empty: every face but the bed face).
    func setTextureFaces(_ refs: [FaceRef]) {
        guard case .texture(var t) = editingFeature?.kind else { return }
        t.faces = refs
        updateEditing { $0.kind = .texture(t) }
    }
}
