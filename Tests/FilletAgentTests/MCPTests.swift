import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import Testing

@testable import FilletAgent

/// Talks to a headless server through `MCPServer.handle`, the way a transport does.
@MainActor
final class Client {
    let workspace = HeadlessWorkspace()
    let server: MCPServer
    private var nextID = 0

    init() {
        server = FilletMCP.makeServer(host: HeadlessHost(workspace: workspace))
    }

    /// A client whose workspace is shared with a "user": `userEdit` makes changes the agent didn't.
    init(sharedWith user: SharedWorkspace) {
        server = FilletMCP.makeServer(host: SharedHost(workspace: user))
    }

    func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        nextID += 1
        let body: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(nextID)), "method": .string(method), "params": params]
        let data = try #require(await server.handle(Data(body.serialized().utf8)))
        return try JSONValue(parsing: data)
    }

    /// Calls a tool; returns its text (JSON parsed when it is JSON) and whether it failed.
    func call(_ tool: String, _ args: JSONValue = [:]) async throws -> (json: JSONValue, text: String, isError: Bool) {
        let r = try await request("tools/call", ["name": .string(tool), "arguments": args])
        let result = try #require(r["result"])
        let text = result["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
        let json = (try? JSONValue(parsing: Data(text.utf8))) ?? .string(text)
        return (json, text, result["isError"]?.bool ?? false)
    }

    @discardableResult
    func ok(_ tool: String, _ args: JSONValue = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        let r = try await call(tool, args)
        #expect(!r.isError, "\(tool) failed: \(r.text)", sourceLocation: sourceLocation)
        return r.json
    }
}

/// A design the user edits too, like a window in the app: their changes aren't the agent's.
@MainActor
final class SharedWorkspace: DesignWorkspace {
    let inner = HeadlessWorkspace()
    private var userActions: [String] = []

    func userEdit(_ action: String, _ change: (inout Document) -> Void) async {
        var doc = inner.document
        change(&doc)
        _ = await inner.commit(doc, action: action)
        userActions.append(action)
    }

    var id: UUID { inner.id }
    var title: String { inner.title }
    var document: Document { inner.document }
    var hiddenBodies: Set<BodyRef> { inner.hiddenBodies }
    var camera: Camera { inner.camera }
    var viewAspect: Double { inner.viewAspect }
    func evaluated() async -> EvaluatedModel { await inner.evaluated() }
    func preview(_ candidate: Document, before: UUID?) async -> EvaluatedModel { await inner.preview(candidate, before: before) }
    func commit(_ newDocument: Document, action: String) async -> EvaluatedModel { await inner.commit(newDocument, action: action) }
    func nextUndo() -> HistoryStep? {
        inner.nextUndo().map { HistoryStep(action: $0.action, byAgent: userActions.last != $0.action) }
    }
    func nextRedo() -> String? { inner.nextRedo() }
    func undo() async -> String? {
        let action = await inner.undo()
        if action == userActions.last { userActions.removeLast() }
        return action
    }
    func redo() async -> String? { await inner.redo() }
    func setHiddenBodies(_ hidden: Set<BodyRef>) { inner.setHiddenBodies(hidden) }
    func show(_ camera: Camera) {}
    func nameFile(_ name: String) async -> FileNaming { await inner.nameFile(name) }
}

@MainActor
final class SharedHost: WorkspaceHost {
    let workspace: SharedWorkspace
    init(workspace: SharedWorkspace) { self.workspace = workspace }
    var hostDescription: String { "Test window" }
    var workspaces: [any DesignWorkspace] { [workspace] }
    var current: (any DesignWorkspace)? { workspace }
    func select(_ id: UUID) -> Bool { id == workspace.id }
    func openNewDesign() async throws -> (any DesignWorkspace)? { nil }
    func agentActivity(_ text: String?) {}
}

@Suite("MCP protocol")
@MainActor
struct MCPProtocolTests {
    @Test func initializeNegotiatesTheVersion() async throws {
        let c = Client()
        let r = try await c.request("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                                   "clientInfo": ["name": "test", "version": "1"]])
        #expect(r["result"]?["protocolVersion"] == "2025-03-26")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["instructions"]?.string?.contains("Z is up") == true)
        #expect(c.server.clientName == "test")
        let future = try await c.request("initialize", ["protocolVersion": "2099-01-01"])
        #expect(future["result"]?["protocolVersion"]?.string == MCPServer.supportedProtocolVersions[0])
    }

    @Test func listsToolsWithSchemas() async throws {
        let c = Client()
        let tools = try #require(try await c.request("tools/list")["result"]?["tools"]?.array)
        let names = Set(tools.compactMap { $0["name"]?.string })
        for expected in ["get_design", "create_sketch", "extrude", "revolve", "loft", "fillet", "render_view", "undo"] {
            #expect(names.contains(expected))
        }
        for t in tools {
            #expect(t["inputSchema"]?["type"] == "object")
            #expect(t["description"]?.string?.isEmpty == false)
        }
    }

    @Test func notificationsGetNoAnswerAndErrorsAreJSONRPC() async throws {
        let c = Client()
        let none = await c.server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(none == nil)
        let unknown = try await c.request("does/not/exist")
        #expect(unknown["error"]?["code"]?.number == -32601)
        let garbage = try JSONValue(parsing: try #require(await c.server.handle(Data("{nope".utf8))))
        #expect(garbage["error"]?["code"]?.number == -32700)
        let unknownTool = try await c.request("tools/call", ["name": "nope"])
        #expect(unknownTool["error"] != nil)
    }

    @Test func answersBatches() async throws {
        let c = Client()
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#
        let r = try JSONValue(parsing: try #require(await c.server.handle(Data(batch.utf8))))
        #expect(r.array?.count == 2)
    }
}

@Suite("Modeling tools")
@MainActor
struct ModelingToolTests {
    @Test func boxFilletAndHoleOnTheTopFace() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": 60, "depth": 40, "height": 20], "name": "Base"])
        try await c.ok("fillet", ["body": "Base", "edges": ["parallel_to": [0, 0, 1]], "radius": 5])
        let sketch = try await c.ok("create_sketch", [
            "plane": ["body": "Base", "face": ["extreme": "+z"]], "name": "Hole sketch",
            "shapes": [["type": "circle", "center": [0, 0], "diameter": 16]],
        ])
        #expect(sketch["plane"]?["origin"]?.array?[2].number == 20)
        #expect(sketch["regions"]?.array?.count == 1)
        try await c.ok("extrude", ["sketch": "Hole sketch", "distance": -30, "operation": "cut", "name": "Hole"])
        let model = await c.workspace.evaluated()
        let volume = try #require(model.bodies.first?.shape.volume)
        let expected = 60.0 * 40 * 20 - (4 - .pi) * 25 * 20 - .pi * 64 * 20
        #expect(abs(volume - expected) < 1)
        #expect(c.workspace.document.features.map(\.name) == ["Base", "Fillet 1", "Hole sketch", "Hole"])
    }

    @Test func aFailingStepIsNotAdded() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Cube"])
        let before = c.workspace.document
        let r = try await c.call("fillet", ["body": "Cube", "edges": "all", "radius": 50])
        #expect(r.isError)
        #expect(r.text.contains("Nothing was changed"))
        #expect(c.workspace.document == before)
    }

    @Test func refusesChangesThatBreakLaterSteps() async throws {
        let c = Client()
        try await c.ok("set_parameter", ["name": "size", "expression": 20])
        try await c.ok("primitive", ["kind": "box", "dimensions": ["width": "size", "depth": "size", "height": "size"], "name": "Cube"])
        try await c.ok("fillet", ["body": "Cube", "edges": "all", "radius": 4])
        let r = try await c.call("set_parameter", ["name": "size", "expression": 6])
        #expect(r.isError)
        #expect(r.text.contains("Fillet 1"))
        let forced = try await c.call("set_parameter", ["name": "size", "expression": 6, "allow_failures": true])
        #expect(!forced.isError)
        #expect(forced.json["design"]?["failed_steps"]?.array?.count == 1)
    }

    @Test func revolveHalfProfileWithASpline() async throws {
        let c = Client()
        try await c.ok("create_sketch", ["plane": "xz", "name": "Profile", "shapes": [
            ["type": "spline", "points": [[0, 0], [12, 4], [10, 20], [0, 24]]],
            ["type": "line", "a": [0, 24], "b": [0, 0]],
        ]])
        let r = try await c.ok("revolve", ["sketch": "Profile", "axis": "y", "name": "Vase"])
        let bounds = try #require(r["changed_bodies"]?.array?.first?["bounds"])
        // Revolved around world Z: symmetric in X and Y.
        #expect(bounds["min"]?.array?[0].number == bounds["min"]?.array?[1].number)
    }

    @Test func editsUndoAndRedo() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "cylinder", "dimensions": ["radius": 5, "height": 10], "name": "Peg"])
        try await c.ok("edit_feature", ["feature": "Peg", "changes": ["kind": ["dimensions": ["10", "30"]]]])
        var bounds = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(bounds.max.z - 30) < 1e-6)
        // Undo takes back the edit, not the step, and says so.
        let wrong = try await c.call("undo", ["expect": "New Peg"])
        #expect(wrong.isError && wrong.text.contains("The last change is “Edit Peg”") && wrong.text.contains("Nothing was undone"))
        let undone = try await c.ok("undo", ["expect": "Peg"])
        #expect(undone["undone"] == "Edit Peg")
        #expect(undone["effect"] == ["Reverted the edit of “Peg”: its earlier definition is back"])
        bounds = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(bounds.max.z - 10) < 1e-6)
        let redone = try await c.ok("redo", ["expect": "Edit Peg"])
        #expect(redone["effect"] == ["Redid the edit of “Peg”"])
        bounds = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(bounds.max.z - 30) < 1e-6)
        try await c.ok("undo")
        let removed = try await c.ok("undo", ["expect": "New Peg"])
        #expect(removed["effect"] == ["Removed step “Peg”"])
        let nothing = try await c.call("undo")
        #expect(nothing.isError)
    }

    @Test func undoLeavesTheUsersChangesAlone() async throws {
        let shared = SharedWorkspace()
        let c = Client(sharedWith: shared)
        try await c.ok("set_parameter", ["name": "width", "expression": 40])
        await shared.userEdit("Set width") { $0.parameters[0].expression = "55" }
        let refused = try await c.call("undo")
        #expect(refused.isError && refused.text.contains("is the user's own"))
        #expect(shared.document.parameters[0].expression.source == "55")
        let undone = try await c.ok("undo", ["expect": "Set width"])
        #expect(undone["by"] == "the user")
        #expect(undone["effect"] == ["Parameter width: 55 → 40"])
        // The agent's own change undoes without naming it.
        let own = try await c.ok("undo")
        #expect(own["by"] == "you" && own["effect"] == ["Removed parameter width"])
    }

    @Test func characterParts() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "sphere", "dimensions": ["diameter": 40], "at": [0, 0, 22], "name": "Torso"])
        try await c.ok("primitive", ["kind": "sphere", "dimensions": ["diameter": 50], "at": [0, 0, 50], "name": "Head"])
        try await c.ok("scale_bodies", ["bodies": "Head", "factors": [1.2, 1, 0.75]])
        try await c.ok("combine", ["target": "Torso", "tools": "Head"])
        // "all" skips the spheres' seams and poles and rounds the neck.
        try await c.ok("fillet", ["body": "Torso", "edges": "all", "radius": 5, "name": "Neck"])
        try await c.ok("loft", ["name": "Hat", "sections": [
            ["center": [0, 0, 64], "diameter": 40], ["center": [0, 0, 80], "diameter": 22],
            ["center": [6, 0, 92], "diameter": 10], ["center": [14, 0, 94], "diameter": 0],
        ]])
        try await c.ok("primitive", ["kind": "sphere", "dimensions": ["radius": 4], "at": [10, -18, 52], "name": "Eye"])
        try await c.ok("mirror", ["bodies": "Eye", "plane": "yz"])
        try await c.ok("set_body_color", ["bodies": ["Torso"], "color": "green"])
        try await c.ok("set_body_color", ["bodies": "Hat", "color": "#8e6bb5"])
        let doc = c.workspace.document
        #expect(doc.bodyColors.values.sorted() == ["#43A047", "#8E6BB5"])
        let design = try await c.ok("get_design")
        #expect(design["bodies"]?.array?.compactMap { $0["name"]?.string } == ["Torso", "Hat", "Eye"])
        let image = try await c.server.handle(Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"render_view","arguments":{"presentation":true,"width":200,"height":150}}}"#.utf8))
        let r = try JSONValue(parsing: try #require(image))
        let content = try #require(r["result"]?["content"]?.array)
        #expect(content.first?["type"] == "image")
        let png = try #require(Data(base64Encoded: content.first?["data"]?.string ?? ""))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func namesAndSelectorsExplainThemselves() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Block"])
        let missing = try await c.call("fillet", ["body": "Nope", "edges": "all", "radius": 1])
        #expect(missing.isError && missing.text.contains("“Block”"))
        let noEdge = try await c.call("fillet", ["body": "Block", "edges": [99], "radius": 1])
        #expect(noEdge.isError && noEdge.text.contains("12 edges"))
        let sameName = try await c.ok("primitive", ["kind": "box", "dimensions": [5, 5, 5], "at": [20, 0, 0], "name": "Block"])
        #expect(sameName["step"]?["name"] == "Block 2")
        let faces = try await c.ok("list_faces", ["body": "Block", "filter": ["normal": [0, 0, 1]]])
        #expect(faces["matching"]?.number == 1)
    }

    @Test func selectsWhatAStepMade() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 40, 10], "name": "Base"])
        try await c.ok("primitive", ["kind": "cylinder", "dimensions": ["diameter": 10, "height": 20], "at": [0, 0, 5], "name": "Peg"])
        try await c.ok("combine", ["target": "Base", "tools": "Peg", "name": "Join peg"])
        // Later steps renumber the edges; the filter still finds the seam.
        try await c.ok("primitive", ["kind": "box", "dimensions": [6, 6, 6], "at": [14, 14, 10], "operation": "join", "targets": "Base", "name": "Nub"])
        let seam = try await c.ok("list_edges", ["body": "Base", "filter": ["created_by": "Join peg", "type": "circle"]])
        let edges = try #require(seam["edges"]?.array)
        #expect(!edges.isEmpty)
        #expect(edges.allSatisfy { $0["radius"]?.number == 5 && $0["mid"]?.array?[2].number == 10 })
        let faces = try await c.ok("list_faces", ["body": "Base", "filter": ["created_by": "Join peg"]])
        // The peg's side, now ending at the box (its top face is the peg's own; the box top changed again with the nub).
        #expect(faces["faces"]?.array?.compactMap { $0["type"]?.string } == ["cylinder"])
        try await c.ok("fillet", ["body": "Base", "edges": ["created_by": "Join peg"], "radius": 2, "name": "Peg root"])
        let f = try #require(c.workspace.document.features.last)
        guard case .fillet(let e) = f.kind else { Issue.record("not a fillet"); return }
        #expect(e.edges.count == edges.count)  // the seam circle, not the peg's (unroundable) seam line
        #expect(e.edges.allSatisfy { abs($0.signature.mid.z - 10) < 1e-6 })
        let otherBody = try await c.call("list_edges", ["body": "Base", "filter": ["created_by": "Peg"]])
        #expect(otherBody.isError && otherBody.text.contains("made no edges on “Base”"))
        let gone = try await c.call("list_edges", ["body": "Base", "filter": ["created_by": "Join peg", "type": "circle"]])
        #expect(gone.isError && gone.text.contains("changed by later steps"))
    }

    @Test func warnsWhenReferencesLandElsewhere() async throws {
        let c = Client()
        try await c.ok("set_parameter", ["name": "shift", "expression": 0])
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 40, 10], "position": ["shift", 0], "name": "Block"])
        try await c.ok("fillet", ["body": "Block", "edges": ["parallel_to": [0, 0, 1], "near": [20, 20, 5], "limit": 1], "radius": 3, "name": "Corner"])
        let nudged = try await c.ok("set_parameter", ["name": "shift", "expression": 0.5])
        #expect(nudged["design"]?["warnings"] == nil)
        let moved = try await c.ok("set_parameter", ["name": "shift", "expression": 12])
        let warning = try #require(moved["design"]?["warnings"]?.array?.first?.string)
        #expect(warning.contains("“Corner”") && warning.contains("12.0 mm"))
    }

    @Test func explainsFailedFillets() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [40, 40, 4], "name": "Plate"])
        let top = try await c.ok("list_edges", ["body": "Plate", "filter": ["extreme": "+z"]])
        let topEdges = try #require(top["edges"]?.array?.compactMap { $0["index"]?.int })
        // The corners take 6 mm; the top edges of a 4 mm plate don't.
        let vertical = try await c.ok("list_edges", ["body": "Plate", "filter": ["parallel_to": [0, 0, 1]]])
        let verticalEdges = try #require(vertical["edges"]?.array?.compactMap { $0["index"]?.int })
        let both = try await c.call("fillet", ["body": "Plate", "edges": .array((topEdges + verticalEdges).map { .number(Double($0)) }), "radius": 6])
        #expect(both.isError)
        let bad = topEdges.sorted().map(String.init).joined(separator: ", ")
        #expect(both.text.contains("Edges \(bad) can't be rounded at 6 mm, even on their own (together they take up to "), "\(both.text)")
        #expect(both.text.contains("; the other 4 take the requested 6 mm together. Leave those out"), "\(both.text)")
        let all = try await c.call("fillet", ["body": "Plate", "edges": .array(topEdges.map { .number(Double($0)) }), "radius": 6])
        #expect(all.isError && all.text.contains("None of the edges can be rounded at 6 mm"), "\(all.text)")
        #expect(all.text.contains("together they take up to "), "\(all.text)")
    }

    @Test func blendDiagnosisSearch() {
        // Edges 3 and 6 fail at any size; the rest work together up to 1.8.
        var probes = 0
        let d = BlendDiagnosis.diagnose(edges: Array(0..<8), size: 3, outOfTime: { _ in false }) { edges, size in
            probes += 1
            if edges.contains(3) || edges.contains(6) { return false }
            return edges.count < 6 || size <= 1.8
        }
        #expect(d.badEdges == [3, 6])
        #expect(d.goodEdges == [0, 1, 2, 4, 5, 7])
        guard case .works(let largest) = d.size else { Issue.record("no size found"); return }
        #expect(largest > 1.6 && largest <= 1.8)
        #expect(d.badSize == .failsDownTo(3.0 / 64))
        #expect(probes < 30)
        #expect(d.message(size: 3, fillet: true) == "Edges 3, 6 can't be rounded at 3 mm, even on their own (together they fail even at 0.04 mm); the other 6 take up to \(BlendDiagnosis.format(BlendDiagnosis.floor(largest))) mm together. Leave those out (or give them a step of their own with a smaller radius) and round the rest.")
        // Out of time: says what it didn't check.
        var calls = 0
        let partial = BlendDiagnosis.diagnose(edges: Array(0..<8), size: 3, outOfTime: { _ in calls >= 2 }) { _, _ in calls += 1; return false }
        #expect(!partial.unchecked.isEmpty)
        #expect(partial.message(size: 3, fillet: false).contains("no time left to check"))
    }

    @Test func scalesAlongTiltedAxes() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "sphere", "dimensions": ["diameter": 10], "at": [0, 0, 20], "name": "Blush"])
        // A disc facing up and 45° forward: squash along that direction.
        try await c.ok("scale_bodies", ["bodies": "Blush", "factors": [1, 1, 0.3], "axes": ["z": [0, -1, 1]], "name": "Flatten"])
        let step = try await c.ok("get_feature", ["feature": "Flatten"])
        let o = try #require(step["feature"]?["kind"]?["orientation"])
        #expect(o["angle"] == "45")
        #expect(o["axis"]?["x"] == "1")
        #expect(step["summary"]?.string?.contains("turned 45°") == true)
        let body = try #require(await c.workspace.evaluated().bodies.first)
        #expect(abs(body.shape.volume - 0.3 * 4 / 3 * .pi * 125) < 1)
        let b = try #require(body.shape.bounds)
        #expect(abs(b.max.x - 5) < 0.05)
        #expect(abs(b.max.y - ((25 + 2.25) / 2).squareRoot()) < 0.05)
        // The same with an explicit turn.
        try await c.ok("undo")
        try await c.ok("scale_bodies", ["bodies": "Blush", "factors": [1, 1, 0.3], "orientation": ["axis": "x", "angle": 45], "name": "Flatten"])
        let b2 = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(b2.max.y - b.max.y) < 1e-6 && abs(b2.max.z - b.max.z) < 1e-6)
        // Two directions are squared up; parallel ones are refused.
        let frame = try ScaleAxes.turn(toAxes: ["x": [0, 1, 0], "z": [0, 0, 1]])
        #expect(frame?.angle == 90 && frame?.axis == Vec3Expr(0, 0, 1))
        #expect(try ScaleAxes.turn(toAxes: ["z": [0, 0, 2]]) == nil)
        #expect(throws: ToolError.self) { try ScaleAxes.turn(toAxes: ["x": [1, 0, 0], "z": [2, 0, 0]]) }
    }

    @Test func refusesBrokenResults() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Cube"])
        // OCCT returns a fillet this big as done, but it is no solid: the kernel refuses it as
        // too large (it used to get as far as the "would leave … without a closed solid" check).
        let r = try await c.call("fillet", ["body": "Cube", "edges": "all", "radius": 6])
        #expect(r.isError && r.text.contains("Fillet 1 failed: Fillet radius too large for the selected edges"), "\(r.text)")
        #expect(r.text.contains("Use a radius of at most"), "\(r.text)")
        #expect(c.workspace.document.features.count == 1)
    }

    @Test func adviceForFailedBooleans() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Staff"])
        try await c.ok("primitive", ["kind": "sphere", "dimensions": ["diameter": 8], "at": [0, 0, 10], "name": "Gem"])
        let model = await c.workspace.evaluated()
        let r = Resolver(document: c.workspace.document, model: model)
        let staff = try r.body("Staff"), gem = try r.body("Gem")
        let cut = Combine(target: staff.ref, tools: [gem.ref], operation: .cut)
        let swapped = await FilletTools.booleanAdvice(cut, target: staff, tool: gem, r, quick: true)
        #expect(swapped.hasPrefix("Cutting “Staff” out of “Gem” instead works (checked): combine with target “Gem”, tools “Staff”"))
        let join = Combine(target: staff.ref, tools: [gem.ref], operation: .join)
        #expect(await FilletTools.booleanAdvice(join, target: staff, tool: gem, r, quick: true).contains("0.05 mm"))
        #expect(await FilletTools.booleanAdvice(cut, target: staff, tool: gem, r, quick: false).contains("0.05 mm"))
    }

    @Test func shapeInputAcceptsArraysAndBulges() throws {
        let shapes = try ShapeInput.shapes([
            ["type": "polyline", "vertices": [[0, 0], [10, 0, 2], [10, 10]], "closed": true, "construction": true],
            ["type": "rectangle", "anchor": "center", "position": [0, 0], "width": "w", "height": 4],
        ])
        guard case .polyline(let vertices, true) = shapes[0].kind else { Issue.record("not a polyline"); return }
        #expect(shapes[0].construction)
        #expect(vertices[1].bulge == 2)
        #expect(shapes.allSatisfy { !$0.id.uuidString.isEmpty })
    }

    @Test func hugeNumbersAreNotIndices() async throws {
        let c = Client()
        try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Block"])
        let r = try await c.call("fillet", ["body": "Block", "edges": [1e300], "radius": 1])
        #expect(r.isError)
        #expect(JSONValue.number(1e20).int == nil)
        #expect(JSONValue.number(3).int == 3)
    }

    @Test func mergePatch() {
        let doc: JSONValue = ["a": 1, "b": ["c": 2, "d": 3]]
        #expect(doc.merging(patch: ["b": ["c": .null, "e": 4], "f": 5]) == ["a": 1, "b": ["d": 3, "e": 4], "f": 5])
    }
}

@Suite("Naming designs")
@MainActor
struct NamingTests {
    @Test func untitledDesignsAskForANameUntilRenamed() async throws {
        let c = Client()
        let created = try await c.ok("primitive", ["kind": "box", "dimensions": [10, 10, 10]])
        #expect(created["design"]?["name_this_design"]?.string?.contains("rename_design") == true)
        #expect(try await c.ok("get_design")["name_this_design"] != nil)

        let renamed = try await c.ok("rename_design", ["name": "  Cable clip.fillet "])
        #expect(c.workspace.document.name == "Cable clip")
        #expect(renamed["design"]?.string == "Cable clip")
        #expect(renamed["file"]?.string?.isEmpty == false)
        #expect(try await c.ok("get_design")["name_this_design"] == nil)
        let next = try await c.ok("primitive", ["kind": "sphere", "dimensions": ["diameter": 8], "at": [30, 0, 4]])
        #expect(next["design"]?["name_this_design"] == nil)

        try await c.ok("undo")
        let undone = try await c.ok("undo", ["expect": "Rename Design"])
        #expect(c.workspace.document.name == nil)
        #expect(undone["effect"]?.array?.first?.string?.contains("“Cable clip” → none") == true)
    }

    @Test func namesAreCleanedUpForFiles() async throws {
        #expect(try FilletTools.designName("iPad/Pro: stand") == "iPad-Pro- stand")
        #expect(throws: ToolError.self) { try FilletTools.designName("   ") }
        #expect(throws: ToolError.self) { try FilletTools.designName(".fillet") }
        #expect(throws: ToolError.self) { try FilletTools.designName(String(repeating: "x", count: 81)) }
    }

    @Test func aNamedNewDesignIsntNagged() async throws {
        let c = Client()
        let r = try await c.ok("new_design", ["name": "Hook", "replace_current": true])
        #expect(c.workspace.document.name == "Hook")
        #expect(r["name_this_design"] == nil)
        #expect(r["file"] != nil)
    }

    @Test func headlessFilesKeepTheirPath() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString).fillet")
        defer { try? FileManager.default.removeItem(at: url) }
        let ws = try HeadlessWorkspace(fileURL: url)
        #expect(!ws.isUntitled)
        guard case .kept = await ws.nameFile("Stand") else { Issue.record("expected the file to keep its path"); return }
        #expect(await HeadlessWorkspace().nameFile("Stand") == .unsaved)
    }
}

@Suite("HTTP transport")
@MainActor
struct HTTPTransportTests {
    func post(_ port: UInt16, _ body: String, headers: [String: String] = ["Content-Type": "application/json"]) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Sends bytes as they are (URLSession would fix up the headers) and returns the response head.
    func raw(_ port: UInt16, _ request: String) async throws -> String {
        try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buffer, buffer.count, 0)
            return String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self)
        }.value
    }

    @Test func servesJSONRPCOverLoopback() async throws {
        let server = FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace()))
        let port = UInt16.random(in: 40000...60000)
        let transport = MCPHTTPTransport(server: server, port: port)
        transport.start()
        defer { transport.stop() }
        // Up to 10 s: under a loaded parallel test run the listener has taken over 2 s to come up.
        for _ in 0..<500 where transport.state != .listening(port: port) { try await Task.sleep(for: .milliseconds(20)) }
        try #require(transport.state == .listening(port: port))

        let (status, data) = try await post(port, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(status == 200)
        #expect(try JSONValue(parsing: data)["result"]?["tools"]?.array?.isEmpty == false)

        let (notified, _) = try await post(port, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notified == 202)
        let (crossOrigin, _) = try await post(port, "{}", headers: ["Content-Type": "application/json", "Origin": "https://example.com"])
        #expect(crossOrigin == 403)
        let (wrongType, _) = try await post(port, "{}", headers: ["Content-Type": "text/plain"])
        #expect(wrongType == 415)
        // Malformed lengths are refused, not trusted (a negative one used to trap).
        let negative = try await raw(port, "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: -5\r\n\r\n{}")
        #expect(negative.hasPrefix("HTTP/1.1 400"))
        let hugeChunk = try await raw(port, "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n")
        #expect(hugeChunk.hasPrefix("HTTP/1.1 400"))
        let (stillUp, _) = try await post(port, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        #expect(stillUp == 200)
        let (localOrigin, _) = try await post(port, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
                                              headers: ["Content-Type": "application/json", "Origin": "http://localhost:3000"])
        #expect(localOrigin == 200)
    }

    /// A plain BSD listener on 127.0.0.1:`port` (SO_REUSEADDR, as most servers set), or nil.
    func occupy(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    func waitUntilSettled(_ t: MCPHTTPTransport) async throws {
        for _ in 0..<500 {
            switch t.state {
            case .listening, .failed: return
            default: try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test func movesOnWhenThePortIsTaken() async throws {
        let base = UInt16.random(in: 40000...60000)
        let taken = try #require(occupy(base))
        defer { close(taken) }
        let ports = [base + 1, base + 2]

        let first = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())),
                                     port: base, fallbackPorts: ports)
        first.start()
        defer { first.stop() }
        try await waitUntilSettled(first)
        #expect(first.state == .listening(port: base + 1))
        #expect(first.currentPort == base + 1)
        let (status, _) = try await post(base + 1, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(status == 200)

        // A second copy (another app instance) doesn't share the port: it takes the next one.
        let second = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())),
                                      port: base, fallbackPorts: ports)
        second.start()
        defer { second.stop() }
        try await waitUntilSettled(second)
        #expect(second.state == .listening(port: base + 2))

        // With every port taken it gives up and says so.
        let third = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())),
                                     port: base, fallbackPorts: ports)
        third.start()
        defer { third.stop() }
        try await waitUntilSettled(third)
        #expect(third.state == .failed("Ports \(base)–\(base + 2) are all in use"))

        // Without fallbacks a taken port fails as before.
        let fixed = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())), port: base)
        fixed.start()
        defer { fixed.stop() }
        try await waitUntilSettled(fixed)
        #expect(fixed.state == .failed("Port already in use"))

        // Turning the server off and on gets the same port back straight away.
        first.stop()
        first.start()
        try await waitUntilSettled(first)
        #expect(first.state == .listening(port: base + 1))
    }

    @Test func findsTheAppForTheBridge() async throws {
        let base = UInt16.random(in: 40000...60000)
        // Something else holds the first port (it accepts but never answers), the second is free.
        let other = try #require(occupy(base))
        defer { close(other) }
        let app = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())), port: base + 2)
        app.start()
        defer { app.stop() }
        try await waitUntilSettled(app)
        try #require(app.state == .listening(port: base + 2))

        let ports = [base, base + 1, base + 2]
        #expect(await MCPDiscovery.scanLoopback(ports: ports, timeout: .milliseconds(500)) == MCPDiscovery.endpoint(port: base + 2))
        #expect(await MCPDiscovery.isFillet(MCPDiscovery.endpoint(port: base), timeout: .milliseconds(300)) == false)

        // The endpoint file the Mac app writes, for a port outside the usual range.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fillet-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcp-endpoint")
        try Data("\(MCPDiscovery.endpoint(port: base + 2).absoluteString)\n".utf8).write(to: file)
        let found = await MCPDiscovery.discover(ports: [base + 1], endpointFiles: [file], bonjourTimeout: .zero)
        #expect(found.url == MCPDiscovery.endpoint(port: base + 2) && found.source == .file)
        // A stale file (the app has gone) is skipped, ending at the default.
        try Data("http://127.0.0.1:\(base + 1)/mcp\n".utf8).write(to: file)
        let none = await MCPDiscovery.discover(ports: [base + 1], endpointFiles: [file], bonjourTimeout: .zero)
        #expect(none.url == MCPDiscovery.defaultEndpoint && none.source == .fallback)
        // Without a live file, the loopback scan finds it.
        let scanned = await MCPDiscovery.discover(ports: ports, endpointFiles: [file], bonjourTimeout: .zero)
        #expect(scanned.url == MCPDiscovery.endpoint(port: base + 2) && scanned.source == .loopback)
        // The file wins over the scan: it names the Mac app, where the scan takes the lowest port
        // that answers (here a second server, standing in for an iPad simulator).
        let other2 = MCPHTTPTransport(server: FilletMCP.makeServer(host: HeadlessHost(workspace: HeadlessWorkspace())), port: base + 1)
        other2.start()
        defer { other2.stop() }
        try await waitUntilSettled(other2)
        try Data("\(MCPDiscovery.endpoint(port: base + 2).absoluteString)\n".utf8).write(to: file)
        let preferred = await MCPDiscovery.discover(ports: ports, endpointFiles: [file], bonjourTimeout: .zero)
        #expect(preferred.url == MCPDiscovery.endpoint(port: base + 2) && preferred.source == .file)
        #expect(MCPDiscovery.endpointFiles(home: URL(fileURLWithPath: "/Users/x")).first?.path
                == "/Users/x/Library/Containers/app.fillet.Fillet/Data/Library/Application Support/Fillet/mcp-endpoint")
    }

    @Test func dechunksBodies() throws {
        let raw = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(HTTPConnection.dechunk(raw, from: raw.startIndex, limit: 100) == .complete(Data("Wikipedia".utf8), raw.endIndex))
        #expect(HTTPConnection.dechunk(Data("4\r\nWi".utf8), from: 0, limit: 100) == .incomplete)
        #expect(HTTPConnection.dechunk(Data("-1\r\nx\r\n".utf8), from: 0, limit: 100) == .invalid)
        #expect(HTTPConnection.dechunk(Data("7fffffffffffffff\r\n".utf8), from: 0, limit: 100) == .invalid)
        #expect(HTTPConnection.dechunk(raw, from: raw.startIndex, limit: 5) == .tooLarge)
    }
}
