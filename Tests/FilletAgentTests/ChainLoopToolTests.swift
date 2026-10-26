import FilletCore
import FilletKernel
import Foundation
import Testing

@testable import FilletAgent

/// The edge filter's topology keys: an edge's tangent chain and a face's loop, as the app picks them.
@Suite("Chain and loop filters")
@MainActor
struct ChainLoopToolTests {
    /// A 60 × 40 × 20 box with its vertical edges rounded: the top outline is one tangent chain.
    private func roundedBase() async throws -> Client {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": 60, "depth": 40, "height": 20], "name": "Base"])
        try await c.ok("fillet", ["body": "Base", "edges": ["parallel_to": [0, 0, 1]], "radius": 5, "name": "Corners"])
        return c
    }

    private func indices(_ json: JSONValue) -> [Int] { json["edges"]?.array?.compactMap { $0["index"]?.int } ?? [] }

    @Test func chainOfAnEdgeIsTheRoundedOutline() async throws {
        let c = try await roundedBase()
        let seed = try #require(indices(try await c.ok("list_edges", ["body": "Base", "filter": ["type": "line", "extreme": "+z", "limit": 1]])).first)
        let chain = indices(try await c.ok("list_edges", ["body": "Base", "filter": ["chain_of": .number(Double(seed))]]))
        #expect(chain.count == 8 && chain.contains(seed))
        // "tangent_chain": true grows a geometric filter's match the same way.
        let grown = indices(try await c.ok("list_edges", ["body": "Base", "filter": ["type": "line", "extreme": "+z", "limit": 1, "tangent_chain": true]]))
        #expect(Set(grown) == Set(chain))
        // Without it, the filter is as before (backward compatible).
        #expect(indices(try await c.ok("list_edges", ["body": "Base", "filter": ["type": "line", "extreme": "+z", "limit": 1]])).count == 1)
        // A fillet on the chain rounds all eight.
        try await c.ok("fillet", ["body": "Base", "edges": ["chain_of": .number(Double(seed))], "radius": 1, "name": "Top"])
        let model = await c.workspace.evaluated()
        let top = try #require(c.workspace.document.features.first { $0.name == "Top" })
        #expect(model.resolvedEdges[top.id]?.count == 8)
    }

    @Test func loopOfAFace() async throws {
        let c = try await roundedBase()
        let faces = try await c.ok("list_faces", ["body": "Base", "filter": ["extreme": "+z"]])
        let top = try #require(faces["faces"]?.array?.first?["index"]?.int)
        let loop = indices(try await c.ok("list_edges", ["body": "Base", "filter": ["loop_of_face": .number(Double(top))]]))
        #expect(loop.count == 8)
        let hole = try await c.call("list_edges", ["body": "Base", "filter": ["loop_of_face": .number(Double(top)), "loop": 1]])
        #expect(hole.isError && hole.text.contains("has 1 loop"), "\(hole.text)")
        let bad = try await c.call("list_edges", ["body": "Base", "filter": ["chain_of": 999]])
        #expect(bad.isError && bad.text.contains("`chain_of` must be an edge index"), "\(bad.text)")
    }
}
