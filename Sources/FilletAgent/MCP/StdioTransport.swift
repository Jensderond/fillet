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
        await bridge(token: token) { _ in url }
    }

    /// Forwards stdio to the Fillet app over HTTP, asking `find` for its endpoint at the first
    /// request and again (`again` true) whenever it can't be reached: the app may have started
    /// since, or be listening on another port.
    public static func bridge(token: String?, find: @escaping @Sendable (_ again: Bool) async -> URL) async {
        var url: URL?
        for await line in stdinLines() {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            var target: URL
            if let url { target = url } else { target = await find(false) }
            var outcome = await forward(line, to: target, token: token)
            if case .unreachable = outcome {
                // Nothing reached the server, so sending again is safe.
                target = await find(true)
                outcome = await forward(line, to: target, token: token)
            }
            url = target
            switch outcome {
            case .answer(let data): write(data)
            case .accepted: break
            case .http(let status, let data):
                replyWithError(to: line, "Fillet answered HTTP \(status): \(String(decoding: data, as: UTF8.self))")
            case .unreachable(let error), .failed(let error):
                replyWithError(to: line, "Can't reach Fillet at \(target.absoluteString) (\(error.localizedDescription)). "
                    + "Open Fillet and turn on Design ▸ Allow Agent Connections.")
            }
        }
    }

    private enum Outcome {
        case answer(Data)
        case accepted
        case http(Int, Data)
        /// No connection was made: the request never got there.
        case unreachable(Error)
        case failed(Error)
    }

    private static func forward(_ line: String, to url: URL, token: String?) async -> Outcome {
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
            if status == 202 || (status == 200 && data.isEmpty) { return .accepted }
            return status == 200 ? .answer(data) : .http(status, data)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            return .unreachable(error)
        } catch {
            return .failed(error)
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
