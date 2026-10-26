import FilletCore
import FilletKernel
import Foundation
import Testing

@testable import FilletAgent

@Suite("Hole tool presets")
@MainActor
struct HolePresetToolTests {
    /// 60 × 40 × 20 block centred on the origin, standing on the bed (top face at z = 20).
    func base() async throws -> Client {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": 60, "depth": 40, "height": 20], "name": "Base"])
        return c
    }

    func volume(_ c: Client) async throws -> Double { try #require(await c.workspace.evaluated().bodies.first?.shape.volume) }

    @Test func presetSizesTheHoleAndAddsTheClearance() async throws {
        let c = try await base()
        let r = try await c.ok("hole", [
            "body": "Base", "face": ["extreme": "+z"], "points": [[-20, 0, 20]], "preset": "m3-clearance", "through_all": true,
        ])
        #expect(r["preset"] == "M3 clearance")
        #expect(r["added_parameter"] == "clearance = 0.2 mm")
        #expect(abs(try await volume(c) - (60.0 * 40 * 20 - .pi * 1.8 * 1.8 * 20)) < 1e-3)
        guard case .hole(let h) = c.workspace.document.features.last?.kind else { Issue.record("not a hole"); return }
        #expect(h.preset == HolePreset(.m3, .clearance) && h.diameter == "3.4 + clearance")

        // Tuning the clearance resizes the hole; a second clearance preset reuses the parameter.
        try await c.ok("set_parameter", ["name": "clearance", "expression": "0.4"])
        #expect(abs(try await volume(c) - (60.0 * 40 * 20 - .pi * 1.9 * 1.9 * 20)) < 1e-3)
        let again = try await c.ok("hole", ["body": "Base", "face": ["extreme": "+z"], "points": [[20, 0, 20]], "preset": "M4 counterbore"])
        #expect(again["added_parameter"] == nil)
        #expect(c.workspace.document.parameters.filter { $0.name == "clearance" }.count == 1)
    }

    @Test func argumentsOverrideThePreset() async throws {
        let c = try await base()
        let r = try await c.ok("hole", [
            "body": "Base", "face": ["extreme": "+z"], "centers": [[0, 0]], "preset": "m3-insert", "depth": 8,
        ])
        // An insert grips, so no clearance parameter; the depth given wins over the preset's 6.7.
        #expect(r["preset"] == "M3 heat-set insert (edited)")
        #expect(r["added_parameter"] == nil && c.workspace.document.parameters.isEmpty)
        guard case .hole(let h) = c.workspace.document.features.last?.kind else { Issue.record("not a hole"); return }
        #expect(h.diameter == 4 && h.depth == 8)

        let bad = try await c.call("hole", ["body": "Base", "face": ["extreme": "+z"], "centers": [[0, 0]], "preset": "m7-clearance"])
        #expect(bad.isError && bad.text.contains("Unknown `preset`"))
    }
}
