import FilletCore
import Foundation

extension FilletTools {
    /// Moves faces along their normals (Fusion's Press Pull on a face).
    var pressPull: MCPTool {
        MCPTool(
            name: "press_pull", title: "Press Pull",
            description: """
                Moves faces of a body along their outward normals, like Fusion's Press Pull on a face: a positive \
                distance adds material (a top face goes up, a hole narrows), a negative one removes it. The faces \
                next to them stretch to follow and the body stays one body. Works on flat and round faces.
                """,
            inputSchema: Self.object(["body": Self.body, "faces": Self.selection,
                                      "distance": Self.expr("Distance along the faces' normals (negative pushes in)"),
                                      "name": Self.name],
                                     required: ["body", "faces", "distance"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let b = try r.body(try a.string("body"))
            let refs = try r.faces(of: b, a["faces"], key: "faces").compactMap { r.model.faceRef(body: b.ref, face: $0) }
            guard !refs.isEmpty else { throw ToolError("`faces` matched no faces of \(r.bodyLabel(b))") }
            return try await add(ws, .pressPull(PressPull(body: b.ref, faces: refs, distance: try a.expr("distance"))), base: "Press Pull", a)
        }
    }
}
