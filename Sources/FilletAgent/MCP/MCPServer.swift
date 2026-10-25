import FilletCore
import Foundation

/// What a tool returns: text and images for the agent, `isError` when the call failed.
public struct ToolResult: Sendable {
    public enum Content: Sendable {
        case text(String)
        /// PNG image data.
        case image(Data)
    }

    public var content: [Content]
    public var isError: Bool

    public init(_ content: [Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ s: String) -> ToolResult { ToolResult([.text(s)]) }
    public static func json(_ v: JSONValue) -> ToolResult { ToolResult([.text(v.serialized())]) }
    public static func error(_ s: String) -> ToolResult { ToolResult([.text(s)], isError: true) }
}

/// A tool failure whose message is shown to the agent as is.
public struct ToolError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One MCP tool: its schema for the agent and the code that runs it.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// The tool only reads (no document change).
    public var readOnly: Bool
    public var handler: @MainActor @Sendable (JSONValue) async throws -> ToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = false,
        handler: @escaping @MainActor @Sendable (JSONValue) async throws -> ToolResult
    ) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.readOnly = readOnly; self.handler = handler
    }

    var listing: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": false,
                            "openWorldHint": false],
        ]
    }
}

/// A Model Context Protocol server (JSON-RPC 2.0), independent of the transport: feed it
/// message bodies with ``handle(_:)`` and send back what it returns.
///
/// Tool calls run one at a time, in arrival order, so two agents can't interleave the
/// steps of their edits.
@MainActor
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String
    public private(set) var tools: [MCPTool]
    /// Name of the last client that initialized (e.g. "claude-code").
    public private(set) var clientName: String?
    /// Called when a client initializes, with its name.
    public var onInitialize: ((String) -> Void)?
    /// Called around every tool call (`nil` when it finished), for activity indicators.
    public var onToolCall: ((MCPTool, JSONValue?) -> Void)?

    private let gate = SerialGate()

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// Handles one HTTP body or stdio line: a single message or a batch.
    /// Returns the response body, or nil when there is nothing to send (notifications only).
    public func handle(_ data: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONValue(parsing: data)
        } catch {
            return Self.encode(Self.errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else {
                return Self.encode(Self.errorResponse(id: .null, code: -32600, message: "Empty batch"))
            }
            var responses: [JSONValue] = []
            for m in batch {
                if let r = await handleMessage(m) { responses.append(r) }
            }
            return responses.isEmpty ? nil : Self.encode(.array(responses))
        }
        return await handleMessage(message).map(Self.encode)
    }

    /// Whether a body holds only notifications/responses (HTTP answers those with 202).
    public static func isNotificationOnly(_ data: Data) -> Bool {
        guard let m = try? JSONValue(parsing: data) else { return false }
        let all = m.array ?? [m]
        return all.allSatisfy { $0["method"] == nil || $0["id"] == nil }
    }

    private func handleMessage(_ m: JSONValue) async -> JSONValue? {
        guard case .object = m else {
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid request")
        }
        guard let method = m["method"]?.string else { return nil }  // a response to us: ignore
        let id = m["id"]
        let params = m["params"] ?? [:]
        guard let id else {
            return nil  // notification (initialized, cancelled, …)
        }
        do {
            let result = try await dispatch(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return Self.errorResponse(id: id, code: e.code, message: e.message)
        } catch {
            return Self.errorResponse(id: id, code: -32603, message: String(describing: error))
        }
    }

    private struct RPCError: Error {
        var code: Int
        var message: String
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            if let client = params["clientInfo"]?["name"]?.string {
                clientName = client
                onInitialize?(client)
            }
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "title": "Fillet", "version": .string(self.version)],
                "instructions": .string(instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(tools.map(\.listing))]
        case "tools/call":
            guard let name = params["name"]?.string else { throw RPCError(code: -32602, message: "Missing tool name") }
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] ?? [:]
            let result = await gate.run { await self.call(tool, args) }
            return Self.encode(result)
        case "resources/list":
            return ["resources": []]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ tool: MCPTool, _ args: JSONValue) async -> ToolResult {
        onToolCall?(tool, args)
        defer { onToolCall?(tool, nil) }
        do {
            return try await tool.handler(args)
        } catch let e as ToolError {
            return .error(e.message)
        } catch {
            return .error(String(describing: error))
        }
    }

    // MARK: Encoding

    static func encode(_ result: ToolResult) -> JSONValue {
        let content: [JSONValue] = result.content.map {
            switch $0 {
            case .text(let s): ["type": "text", "text": .string(s)]
            case .image(let png): ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"]
            }
        }
        return ["content": .array(content), "isError": .bool(result.isError)]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func encode(_ value: JSONValue) -> Data {
        Data(value.serialized().utf8)
    }
}

/// Runs async work one job at a time, in arrival order (a FIFO async mutex on the main actor).
@MainActor
final class SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ work: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()  // hand over without releasing
            }
        }
        return await work()
    }
}
