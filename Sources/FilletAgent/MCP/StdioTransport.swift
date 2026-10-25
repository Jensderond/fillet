import FilletCore
import Foundation

/// Serves an ``MCPServer`` over stdio: one JSON-RPC message per line on stdin, responses one
/// per line on stdout. Logs belong on stderr.
@MainActor
public enum MCPStdioTransport {
    /// Reads stdin until it closes.
    public static func run(_ server: MCPServer) async {
        for await line in stdinLines() {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            if let response = await server.handle(Data(line.utf8)) {
                write(response)
            }
        }
    }

    /// Forwards stdio to a remote MCP server over HTTP (a bridge for stdio-only clients).
    public static func bridge(to url: URL, token: String?) async {
        for await line in stdinLines() {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = Data(line.utf8)
            request.timeoutInterval = 600
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 202 || data.isEmpty { continue }
                if status == 200 {
                    write(data)
                } else {
                    replyWithError(to: line, "Fillet answered HTTP \(status): \(String(decoding: data, as: UTF8.self))")
                }
            } catch {
                replyWithError(to: line, "Can't reach Fillet at \(url.absoluteString) (\(error.localizedDescription)). "
                    + "Open Fillet and turn on Design ▸ Allow Agent Connections.")
            }
        }
    }

    /// Answers a request the bridge couldn't forward (notifications need no answer).
    private static func replyWithError(to line: String, _ message: String) {
        guard let id = (try? JSONValue(parsing: Data(line.utf8)))?["id"] else { return }
        write(MCPServer.encode(MCPServer.errorResponse(id: id, code: -32000, message: message)))
    }

    private static func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }

    /// Lines from stdin, read on a background thread.
    private static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.start()
        }
    }
}
