import FilletCore
import Foundation
import Testing

@testable import FilletAgent

/// The agents' `measure` tool: bodies, faces and edges, and distance and angle between two.
@Suite("Measure tool")
@MainActor
struct MeasureToolTests {
    @Test func facesEdgesAndBetween() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": 60, "depth": 40, "height": 20], "name": "Base"])
        try await c.ok("create_sketch", [
            "plane": ["body": "Base", "face": ["extreme": "+z"]], "name": "Hole sketch",
            "shapes": [["type": "circle", "center": [0, 0], "diameter": 16]],
        ])
        try await c.ok("extrude", ["sketch": "Hole sketch", "distance": -30, "operation": "cut", "name": "Hole"])

        let top = try await c.ok("measure", ["body": "Base", "face": ["extreme": "+z"]])
        #expect(abs((top["first"]?["area"]?.number ?? 0) - (2400 - .pi * 64)) < 0.01)
        let wall = try await c.ok("measure", ["body": "Base", "face": ["type": "cylinder"]])
        #expect(wall["first"]?["radius"]?.number == 8)

        let across = try await c.ok("measure", ["body": "Base", "face": ["extreme": "+z"], "to_face": ["extreme": "-z"]])
        #expect(across["distance"]?.number == 20 && abs(across["dz"]?.number ?? 0) == 20 && across["angle_degrees"]?.number == 180)
        let corner = try await c.ok("measure", ["body": "Base", "face": ["extreme": "+z"], "to_face": ["extreme": "+x"]])
        #expect(corner["distance"]?.number == 0 && corner["angle_degrees"]?.number == 90)

        // An ambiguous filter is refused rather than measuring the first match.
        let many = try await c.call("measure", ["body": "Base", "face": ["type": "plane"]])
        #expect(many.isError && many.text.contains("matches"))
        // Bodies alone still work as before.
        let all = try await c.ok("measure")
        #expect(all["bodies"]?.array?.count == 1)
    }
}
