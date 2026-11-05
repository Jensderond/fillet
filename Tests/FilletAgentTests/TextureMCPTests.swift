import FilletCore
import Foundation
import Testing
import simd

@testable import FilletAgent

/// Coarser than export so the debug-build tests stay quick; same algorithm.
private let testQuality = TextureQuality(edgeScale: 2.5, maxTriangles: 150_000)

@Suite("MCP texture")
@MainActor
struct TextureMCPTests {
    /// A texture change keeps the body's shape but changes its shown mesh, so the viewport's key
    /// for the mesh must change with it (a new dot profile once stayed on screen as the old one).
    @Test func displayVersionFollowsTheTexture() async throws {
        var o = TextureSamples.Options()
        o.diameter = 20; o.height = 15; o.pattern = .dots
        var doc = try await TextureSamples.document(o)
        let evaluator = ModelEvaluator()
        var versions: [Int] = []
        var shapes: [ObjectIdentifier] = []
        for profile in [2.0, 0.0] {
            let i = try #require(doc.features.firstIndex { if case .texture = $0.kind { true } else { false } })
            guard case .texture(var t) = doc.features[i].kind else { return }
            t.values["profile"] = Expr(profile)
            doc.features[i].kind = .texture(t)
            let body = try #require(await evaluator.evaluate(doc).bodies.first)
            versions.append(body.displayVersion)
            shapes.append(ObjectIdentifier(body.shape))
        }
        #expect(shapes[0] == shapes[1], "the solid is the same: only the texture changed")
        #expect(versions[0] != versions[1])
    }

    /// Editing a texture's values reuses the body's fine tessellation; the result must be the
    /// same mesh a fresh evaluator makes. Edge lines stay those of the plain display mesh.
    @Test func texturedDisplayMeshIsTheSameAfterAnEdit() async throws {
        var o = TextureSamples.Options()
        o.diameter = 20; o.height = 15; o.pattern = .knit
        var doc = try await TextureSamples.document(o)
        let evaluator = ModelEvaluator()
        let plain = try #require(await ModelEvaluator().evaluate({ var d = doc; d.features.removeAll { if case .texture = $0.kind { true } else { false } }; return d }()).meshes.values.first)
        _ = await evaluator.evaluate(doc)
        let i = try #require(doc.features.firstIndex { if case .texture = $0.kind { true } else { false } })
        guard case .texture(var t) = doc.features[i].kind else { return }
        t.values["depth"] = Expr(0.6)
        doc.features[i].kind = .texture(t)
        let edited = try #require(await evaluator.evaluate(doc).meshes.values.first)
        let fresh = try #require(await ModelEvaluator().evaluate(doc).meshes.values.first)
        // Crease shading can split a vertex or two differently between runs, so compare the
        // triangles and the extent rather than the vertex arrays.
        #expect(edited.triangleCount == fresh.triangleCount)
        let a = try #require(edited.bounds), b = try #require(fresh.bounds)
        #expect(simd_length(a.min - b.min) < 1e-4 && simd_length(a.max - b.max) < 1e-4)
        #expect(edited.edges.count == plain.edges.count)
        #expect(edited.edges.map(\.count) == plain.edges.map(\.count))
        #expect(edited.triangleCount > plain.triangleCount * 4, "the relief is meshed finer than the plain body")
    }

    @Test func texturesTheSideOfACylinderAndExportsIt() async throws {
        let c = Client()
        let tools = try await c.request("tools/list")["result"]?["tools"]?.array ?? []
        let tool = try #require(tools.first { $0["name"]?.string == "texture" })
        // The schema and description come from the catalogue.
        let patterns = tool["inputSchema"]?["properties"]?["pattern"]?["enum"]?.array?.compactMap(\.string) ?? []
        #expect(patterns.contains("knit") && patterns.contains("dots"))
        #expect(tool["inputSchema"]?["properties"]?["values"]?["properties"]?["stitchWidth"] != nil)

        try await c.ok("primitive", ["kind": "cylinder", "dimensions": [20, 12], "name": "Cup"])
        try await c.ok("texture", ["body": "Cup", "faces": ["type": "cylinder"], "pattern": "dots",
                                   "values": ["diameter": 3, "spacing": 6, "raised": false]])
        let step = try #require(c.workspace.document.features.last)
        guard case .texture(let t) = step.kind else { Issue.record("expected a texture step"); return }
        #expect(t.faces.count == 1 && t.pattern == .dots && t.values["raised"] == 0)
        #expect(await c.workspace.evaluated().status[step.id] == .ok)

        let bad = try await c.call("texture", ["body": "Cup", "pattern": "dots", "values": ["stitchWidth": 3]])
        #expect(bad.isError && bad.text.contains("has no value"))

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("texture-\(UUID().uuidString).stl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await c.ok("export", ["format": "stl", "path": .string(path)])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        #expect(size > 84 + 50 * 20_000)  // textured: far more than the plain cylinder's triangles
    }

    /// Bodies the engine must keep closed: rounded edges between textured faces, hole walls and a
    /// drill point, two bodies at once, two textures on one body, and a texture before a fillet.
    @Test(arguments: ["rounded box", "holes", "two bodies", "two textures", "texture then fillet"])
    func texturedEdgeCasesStayWatertight(_ name: String) async throws {
        let c = Client()
        let box: JSONValue = ["kind": "box", "dimensions": ["width": 30, "depth": 24, "height": 16], "name": "Box"]
        switch name {
        case "rounded box":
            try await c.ok("primitive", box)
            try await c.ok("fillet", ["body": "Box", "edges": ["parallel_to": [0, 0, 1]], "radius": 5])
            try await c.ok("fillet", ["body": "Box", "edges": ["within": ["min": [-20, -20, 15.9], "max": [20, 20, 16.1]]], "radius": 2])
            try await c.ok("texture", ["body": "Box", "faces": "all", "pattern": "knit", "values": ["stitchWidth": 4, "stitchHeight": 3.5, "depth": 0.8]])
        case "holes":
            try await c.ok("primitive", box)
            try await c.ok("hole", ["body": "Box", "face": ["extreme": "+z"], "points": [[-7, 0, 16]], "diameter": 6, "through_all": true])
            try await c.ok("hole", ["body": "Box", "face": ["extreme": "+z"], "points": [[7, 0, 16]], "diameter": 6, "depth": 8])
            try await c.ok("texture", ["body": "Box", "faces": "all", "pattern": "dots",
                                       "values": ["diameter": 2.5, "spacing": 4, "rowSpacing": 4, "height": 0.6, "whole": false]])
        case "two bodies":
            try await c.ok("primitive", ["kind": "cylinder", "dimensions": [16, 14], "name": "A"])
            try await c.ok("primitive", ["kind": "cylinder", "dimensions": [16, 14], "position": [24, 0], "name": "B"])
            try await c.ok("texture", ["body": "A", "pattern": "knit", "values": ["stitchWidth": 4, "stitchHeight": 3.5]])
            try await c.ok("texture", ["body": "B", "pattern": "dots", "values": ["diameter": 4, "spacing": 6, "rowSpacing": 6]])
        case "two textures":
            try await c.ok("primitive", box)
            try await c.ok("texture", ["body": "Box", "pattern": "knit", "values": ["stitchWidth": 4, "stitchHeight": 3.5, "depth": 0.8]])
            try await c.ok("texture", ["body": "Box", "faces": ["extreme": "+z"], "pattern": "dots",
                                       "values": ["diameter": 4, "spacing": 7, "rowSpacing": 7, "height": 0.6]])
        default:
            try await c.ok("primitive", box)
            try await c.ok("texture", ["body": "Box", "pattern": "knit", "values": ["stitchWidth": 4, "stitchHeight": 3.5, "depth": 0.8]])
            try await c.ok("fillet", ["body": "Box", "edges": ["parallel_to": [0, 0, 1]], "radius": 4])
        }
        let model = await c.workspace.evaluated()
        for f in c.workspace.document.features { #expect(model.status[f.id] == .ok, "\(f.name): \(model.error(for: f.id) ?? "")") }
        #expect(model.bodies.allSatisfy { !$0.textures.isEmpty })
        for (body, mesh) in zip(model.bodies, try model.bodies.printMeshes(quality: testQuality)) {
            let check = MeshCheck.check(mesh)
            #expect(check.passes, "\(body.name): \(check)")
            let plain = try body.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)
            #expect(mesh.triangleCount > plain.triangleCount * 2, "\(body.name) is textured")
        }
    }

    /// With no faces given, a texture covers the outer side wall, as in the app: not the bed
    /// face, not the rim, not the inside of the cup.
    @Test func defaultsToTheOuterSideWalls() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "cylinder", "dimensions": [20, 30], "name": "Cup"])
        try await c.ok("shell", ["body": "Cup", "remove_faces": ["extreme": "+z"], "thickness": 2])
        try await c.ok("texture", ["body": "Cup", "pattern": "knit"])
        let step = try #require(c.workspace.document.features.last)
        guard case .texture(let t) = step.kind else { Issue.record("expected a texture step"); return }
        #expect(t.faces.count == 1)
        let model = await c.workspace.evaluated()
        #expect(model.status[step.id] == .ok)
        let shape = try #require(model.body(t.body)?.shape)
        let side = try #require(t.faces.first.flatMap { ReferenceResolver.resolve($0.signature, in: shape.faceInfos) })
        // The outer wall: as wide as the cup, not the inside 4 mm narrower.
        let info = shape.faceInfo(side)
        let bounds = try #require(shape.bounds)
        #expect(abs((info.boundsMax.x - info.boundsMin.x) - (bounds.max.x - bounds.min.x)) < 0.5)

        try await c.ok("texture", ["body": "Cup", "pattern": "dots", "faces": "all"])
        guard case .texture(let all) = c.workspace.document.features.last?.kind else { Issue.record("expected a texture step"); return }
        #expect(all.faces.isEmpty)
    }
}
