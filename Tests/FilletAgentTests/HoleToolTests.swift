import FilletCore
import FilletKernel
import Foundation
import Testing

@testable import FilletAgent

@Suite("Hole tool")
@MainActor
struct HoleToolTests {
    /// 60 × 40 × 20 block centred on the origin, standing on the bed (top face at z = 20).
    func base() async throws -> Client {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": 60, "depth": 40, "height": 20], "name": "Base"])
        return c
    }

    func volume(_ c: Client) async throws -> Double { try #require(await c.workspace.evaluated().bodies.first?.shape.volume) }

    @Test func drillsAtWorldPoints() async throws {
        let c = try await base()
        let r = try await c.ok("hole", [
            "body": "Base", "face": ["extreme": "+z"], "points": [[-20, 0, 20], [20, 0, 20]],
            "diameter": 6, "through_all": true, "name": "Bolt holes",
        ])
        #expect(r["step"]?["type"] == "hole")
        #expect(r["face_plane"]?["normal"]?.array?[2].number == 1)
        let centers = try #require(r["hole_centers"]?.array)
        #expect(centers.count == 2)
        #expect(centers.contains { $0.array?[0].number == -20 && $0.array?[2].number == 20 })
        let expected = 60.0 * 40 * 20 - 2 * .pi * 9 * 20
        #expect(abs(try await volume(c) - expected) < 1e-3)
        guard case .hole(let h) = c.workspace.document.features.last?.kind else { Issue.record("not a hole"); return }
        #expect(h.extent == .throughAll && h.centers.count == 2)
    }

    @Test func counterboreAtFaceCoordinatesWithAParameter() async throws {
        let c = try await base()
        try await c.ok("set_parameter", ["name": "bolt", "expression": "4"])
        try await c.ok("hole", [
            "body": "Base", "face": ["extreme": "+z"], "centers": [[0, 0]], "diameter": "bolt", "depth": 12,
            "tip_angle": 0, "hole_type": "counterbore", "counterbore_diameter": "bolt * 2", "counterbore_depth": 4,
        ])
        let removed: Double = .pi * (16 * 4 + 4 * 8)
        #expect(abs(try await volume(c) - (60 * 40 * 20 - removed)) < 1e-3)
        try await c.ok("set_parameter", ["name": "bolt", "expression": "5"])
        let wider: Double = .pi * (25 * 4 + 6.25 * 8)
        #expect(abs(try await volume(c) - (60 * 40 * 20 - wider)) < 1e-3)
    }

    @Test func patternRepeatsTheHoleStep() async throws {
        let c = try await base()
        try await c.ok("hole", ["body": "Base", "face": ["extreme": "+z"], "points": [[-20, 0, 20]],
                                "diameter": 6, "through_all": true, "name": "Bolt hole"])
        let both = try await c.call("pattern", ["bodies": "Base", "features": "Bolt hole", "layout": "linear",
                                                "axis": "x", "count": 3, "spacing": 20])
        #expect(both.isError && both.text.contains("exactly one"))
        try await c.ok("pattern", ["features": ["Bolt hole"], "layout": "linear", "axis": "x", "count": 3, "spacing": 20])
        guard case .pattern(let p) = c.workspace.document.features.last?.kind else { Issue.record("not a pattern"); return }
        #expect(p.objects == .features && p.features.count == 1)
        #expect(abs(try await volume(c) - (60.0 * 40 * 20 - 3 * .pi * 9 * 20)) < 1e-3)
    }

    @Test func refusesBadInput() async throws {
        let c = try await base()
        let off = try await c.call("hole", ["body": "Base", "face": ["extreme": "+z"], "points": [[0, 0, 5]]])
        #expect(off.isError && off.text.contains("off the face"))
        let none = try await c.call("hole", ["body": "Base", "face": ["extreme": "+z"]])
        #expect(none.isError && none.text.contains("at least one"))
        let deep = try await c.call("hole", ["body": "Base", "face": ["extreme": "+z"], "centers": [[0, 0]],
                                             "hole_type": "counterbore", "depth": 2, "counterbore_depth": 3])
        #expect(deep.isError && deep.text.contains("Counterbore depth"))
        #expect(c.workspace.document.features.count == 1)
    }
}
