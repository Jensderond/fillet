import FilletCore
import Foundation
import Testing

@testable import FilletAgent

@Suite("MCP Press Pull")
@MainActor
struct PressPullMCPTests {
    @Test func pullsATopFaceByAParameterThenPushesIt() async throws {
        let c = Client()
        let tools = try await c.request("tools/list")["result"]?["tools"]?.array ?? []
        #expect(tools.contains { $0["name"]?.string == "press_pull" })

        try await c.ok("set_parameter", ["name": "lift", "expression": 5])
        try await c.ok("primitive", ["kind": "box", "dimensions": [20, 20, 10], "name": "Base"])
        let r = try await c.ok("press_pull", ["body": "Base", "faces": ["extreme": "+z"], "distance": "lift"])
        let bounds = try #require(r["changed_bodies"]?.array?.first?["bounds"])
        #expect(bounds["max"]?.array?[2].number == 15)
        #expect(c.workspace.document.features.map(\.name) == ["Base", "Press Pull 1"])
        #expect(abs(try #require(await c.workspace.evaluated().bodies.first).shape.volume - 6000) < 1e-3)

        try await c.ok("edit_feature", ["feature": "Press Pull 1", "changes": ["kind": ["distance": "-3"]]])
        #expect(abs(try #require(await c.workspace.evaluated().bodies.first).shape.volume - 2800) < 1e-3)

        let none = try await c.call("press_pull", ["body": "Base", "faces": ["extreme": "+z"], "distance": -20])
        #expect(none.isError)
        #expect(none.text.contains("pushed this far"))
    }
}
