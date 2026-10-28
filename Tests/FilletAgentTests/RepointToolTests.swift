import FilletCore
import FilletKernel
import Foundation
import Testing

@testable import FilletAgent

/// `edit_feature` with `edges` / `faces`: a step picks again, on the bodies just before it.
@Suite("Re-pointing steps")
@MainActor
struct RepointToolTests {
    private func fillet(_ c: Client, _ name: String) throws -> EdgeFeature {
        guard case .fillet(let e) = try #require(c.workspace.document.features.first { $0.name == name }).kind else {
            throw ToolError("“\(name)” isn't a fillet")
        }
        return e
    }

    @Test func refindsAFilletsEdgeAfterAChangeMovedIt() async throws {
        let c = Client()
        try await c.ok("set_parameter", ["name": "shift", "expression": 0])
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 40, 10], "position": ["shift", 0], "name": "Block"])
        try await c.ok("fillet", ["body": "Block", "edges": ["parallel_to": [0, 0, 1], "near": [20, 20, 5], "limit": 1], "radius": 3, "name": "Corner"])
        let moved = try await c.ok("set_parameter", ["name": "shift", "expression": 12])
        let warning = try #require(moved["design"]?["warnings"]?.array?.first?.string)
        #expect(warning.contains("edit_feature"))
        let r = try await c.ok("edit_feature", ["feature": "Corner", "edges": ["parallel_to": [0, 0, 1], "near": [32, 20, 5], "limit": 1]])
        #expect(r["picked"] == "an edge of “Block”")
        let e = try fillet(c, "Corner")
        #expect(e.edges.count == 1)
        #expect(abs(e.edges[0].signature.mid.x - 32) < 1e-6 && abs(e.edges[0].signature.mid.y - 20) < 1e-6)
        // The radius changes in the same call when `changes` is given too.
        try await c.ok("edit_feature", ["feature": "Corner", "edges": ["parallel_to": [0, 0, 1], "extreme": "-x"], "changes": ["kind": ["size": "2"]]])
        let both = try fillet(c, "Corner")
        #expect(both.size.source == "2" && both.edges.count == 2 && both.edges.allSatisfy { abs($0.signature.mid.x + 8) < 1e-6 })
    }

    @Test func picksOnTheBodyJustBeforeTheStep() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 40, 10], "name": "Base"])
        try await c.ok("primitive", ["kind": "cylinder", "dimensions": ["diameter": 10, "height": 20], "at": [0, 0, 5], "name": "Peg"])
        try await c.ok("combine", ["target": "Base", "tools": "Peg", "name": "Join peg"])
        try await c.ok("fillet", ["body": "Base", "edges": ["parallel_to": [0, 0, 1], "extreme": "+x"], "radius": 2, "name": "Round"])
        try await c.ok("chamfer", ["body": "Base", "edges": ["extreme": "+z", "type": "circle"], "distance": 1, "name": "Peg top"])
        // After “Round” the body has its fillet faces; just before it, the plain box with the peg.
        let before = try await c.ok("list_edges", ["body": "Base", "before": "Round", "filter": ["parallel_to": [0, 0, 1], "type": "line", "max_length": 12]])
        #expect(before["matching"]?.number == 4)  // the box's corners (the peg's seam is longer)
        let r = try await c.ok("edit_feature", ["feature": "Round", "edges": ["created_by": "Join peg", "type": "circle"]])
        #expect(r["picked"] == "an edge of “Base”")
        let e = try fillet(c, "Round")
        #expect(e.edges.count == 1 && e.edges[0].signature.curve == .circle && abs(e.edges[0].signature.mid.z - 10) < 1e-6)
        // What a later step made isn't there yet.
        let later = try await c.call("edit_feature", ["feature": "Round", "edges": ["created_by": "Peg top"]])
        #expect(later.isError && later.text.contains("comes after “Round”"))
        // A failing pick explains itself like the fillet tool, and changes nothing.
        let doc = c.workspace.document
        let tooBig = try await c.call("edit_feature", ["feature": "Round", "edges": ["parallel_to": [0, 0, 1], "type": "line"], "changes": ["kind": ["size": 30]]])
        #expect(tooBig.isError && tooBig.text.contains("Nothing was changed"))
        #expect(c.workspace.document == doc)
    }

    @Test func pointsFaceStepsAtOtherFaces() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 30, 20], "name": "Box"])
        try await c.ok("create_sketch", ["plane": ["body": "Box", "face": ["extreme": "+z"]], "name": "Mark",
                                         "shapes": [["type": "circle", "center": [5, 0], "diameter": 4]]])
        try await c.ok("hole", ["body": "Box", "face": ["extreme": "+z"], "points": [[-10, 0, 20]], "diameter": 3, "depth": 4, "name": "Pin"])
        try await c.ok("press_pull", ["body": "Box", "faces": ["extreme": "+x"], "distance": 2, "name": "Grow"])
        try await c.ok("primitive", ["kind": "box", "dimensions": [20, 20, 20], "at": [50, 0, 0], "name": "Cup"])
        try await c.ok("shell", ["body": "Cup", "remove_faces": ["extreme": "+z"], "thickness": 2, "name": "Hollow"])

        try await c.ok("edit_feature", ["feature": "Hollow", "faces": ["extreme": "-z"]])
        try await c.ok("edit_feature", ["feature": "Grow", "faces": ["extreme": "-x"]])
        try await c.ok("edit_feature", ["feature": "Pin", "faces": ["extreme": "-z"]])
        try await c.ok("edit_feature", ["feature": "Mark", "faces": ["extreme": "+y"]])
        let doc = c.workspace.document
        func kind(_ name: String) throws -> FeatureKind { try #require(doc.features.first { $0.name == name }).kind }
        guard case .shell(let s) = try kind("Hollow"), case .pressPull(let p) = try kind("Grow"),
              case .hole(let h) = try kind("Pin"), case .sketch(let m) = try kind("Mark"),
              case .face(let markFace, _, let anchor) = m.plane else { Issue.record("unexpected kinds"); return }
        #expect(s.removeFaces.count == 1 && s.removeFaces[0].signature.normal.z < -0.99)
        #expect(p.faces.count == 1 && p.faces[0].signature.normal.x < -0.99)
        #expect(try #require(h.face).signature.normal.z < -0.99)
        #expect(markFace.signature.normal.y > 0.99 && anchor == .world)
        let model = await c.workspace.evaluated()
        #expect(doc.features.allSatisfy { model.status[$0.id] == .ok })

        let wrongKind = try await c.call("edit_feature", ["feature": "Hollow", "edges": "all"])
        #expect(wrongKind.isError && wrongKind.text.contains("give `faces`"))
        let noBody = try await c.call("edit_feature", ["feature": "Box", "faces": "all"])
        #expect(noBody.isError && noBody.text.contains("give `body`"))
        try await c.ok("scale_bodies", ["bodies": "Cup", "factors": [1, 1, 1.5], "name": "Stretch"])
        let nothingToPick = try await c.call("edit_feature", ["feature": "Stretch", "faces": "all"])
        #expect(nothingToPick.isError && nothingToPick.text.contains("no edges or faces"))
        let notFlat = try await c.call("edit_feature", ["feature": "Pin", "faces": ["type": "cylinder"]])
        #expect(notFlat.isError)
    }

    @Test func putsAStepOnAnotherBody() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Left"])
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "at": [30, 0, 0], "name": "Right"])
        try await c.ok("fillet", ["body": "Left", "edges": ["extreme": "+z"], "radius": 1, "name": "Soften"])
        try await c.ok("edit_feature", ["feature": "Soften", "body": "Right", "edges": ["extreme": "+z"]])
        let e = try fillet(c, "Soften")
        let right = try #require(c.workspace.document.features.first { $0.name == "Right" })
        #expect(e.body == BodyRef(right.id) && e.edges.allSatisfy { $0.body == e.body })
        let model = await c.workspace.evaluated()
        #expect(model.body(BodyRef(right.id))?.lastFeature == c.workspace.document.features.last?.id)
    }
}
