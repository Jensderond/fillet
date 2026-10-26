import FilletCore
import FilletKernel
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
        let undone = try await c.ok("undo")
        #expect(undone["undone"] == "Edit Peg")
        bounds = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(bounds.max.z - 10) < 1e-6)
        try await c.ok("redo")
        bounds = try #require(await c.workspace.evaluated().bodies.first?.shape.bounds)
        #expect(abs(bounds.max.z - 30) < 1e-6)
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
        for _ in 0..<100 where transport.state != .listening(port: port) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transport.state == .listening(port: port))

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

    @Test func dechunksBodies() throws {
        let raw = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(HTTPConnection.dechunk(raw, from: raw.startIndex, limit: 100) == .complete(Data("Wikipedia".utf8), raw.endIndex))
        #expect(HTTPConnection.dechunk(Data("4\r\nWi".utf8), from: 0, limit: 100) == .incomplete)
        #expect(HTTPConnection.dechunk(Data("-1\r\nx\r\n".utf8), from: 0, limit: 100) == .invalid)
        #expect(HTTPConnection.dechunk(Data("7fffffffffffffff\r\n".utf8), from: 0, limit: 100) == .invalid)
        #expect(HTTPConnection.dechunk(raw, from: raw.startIndex, limit: 5) == .tooLarge)
    }
}
