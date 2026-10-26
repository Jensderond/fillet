import Foundation
import Network

/// Serves an ``MCPServer`` over MCP's Streamable HTTP transport: `POST /mcp` with a JSON-RPC
/// body, answered with a plain JSON body (no SSE streams; this server never sends requests or
/// notifications of its own).
///
/// Security: requests carrying an `Origin` that isn't localhost are refused (a web page can't
/// drive the app through DNS rebinding), and when ``token`` is set every connection that isn't
/// from this machine must send `Authorization: Bearer <token>`.
@MainActor
public final class MCPHTTPTransport {
    public enum Binding: Sendable, Equatable {
        /// 127.0.0.1 only: agents on this machine.
        case loopback
        /// Every interface, so agents on another machine on the network can connect (iPad).
        case network
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public let server: MCPServer
    /// The ports to listen on, in order of preference: when one is taken, the next is tried.
    public let ports: [UInt16]
    /// The preferred port (the first of ``ports``).
    public var port: UInt16 { ports[0] }
    /// The port it listens on now, or is trying.
    public private(set) var currentPort: UInt16
    public let binding: Binding
    /// Required from non-loopback clients when set.
    public let token: String?
    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((State) -> Void)?

    private var listener: NWListener?
    private var attempt = 0
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// - Parameter fallbackPorts: tried in order when `port` (and each earlier fallback) is taken.
    public init(server: MCPServer, port: UInt16, fallbackPorts: [UInt16] = [], binding: Binding = .loopback, token: String? = nil) {
        self.server = server
        var ports = [port]
        for p in fallbackPorts where !ports.contains(p) { ports.append(p) }
        self.ports = ports
        self.currentPort = port
        self.binding = binding
        self.token = token
    }

    public func start() {
        guard listener == nil else { return }
        state = .starting
        attempt = 0
        listen(on: ports[0])
    }

    private func listen(on port: UInt16) {
        currentPort = port
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true  // a port another listener holds still fails (tested)
            if binding == .loopback {
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            }
            let listener = binding == .loopback
                ? try NWListener(using: params)
                : try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            if binding == .network {
                listener.service = NWListener.Service(name: nil, type: "_fillet-mcp._tcp")
            }
            let id = ObjectIdentifier(listener)
            listener.stateUpdateHandler = { [weak self] s in
                Task { @MainActor in self?.listenerChanged(s, id) }
            }
            listener.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.accept(c) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            listener = nil
            failOrTryNext(error.localizedDescription, inUse: false)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.connection.cancel() }
        connections = [:]
        state = .stopped
    }

    private func listenerChanged(_ s: NWListener.State, _ id: ObjectIdentifier) {
        guard let listener, ObjectIdentifier(listener) == id else { return }  // an earlier attempt's
        switch s {
        case .ready: state = .listening(port: listener.port?.rawValue ?? currentPort)
        case .failed(let e), .waiting(let e):
            // A taken port usually fails at once, but can also leave the listener waiting.
            if case .waiting = s, !Self.isAddressInUse(e) { return }
            listener.cancel()
            self.listener = nil
            failOrTryNext(Self.describe(e), inUse: Self.isAddressInUse(e))
        case .cancelled: if case .failed = state {} else { state = .stopped }
        default: break
        }
    }

    /// Moves on to the next port when this one is taken, or reports the failure.
    private func failOrTryNext(_ reason: String, inUse: Bool) {
        if inUse, attempt + 1 < ports.count {
            attempt += 1
            listen(on: ports[attempt])
        } else {
            state = .failed(inUse && ports.count > 1 ? "Ports \(ports.min()!)–\(ports.max()!) are all in use" : reason)
        }
    }

    private static func isAddressInUse(_ e: NWError) -> Bool {
        if case .posix(let code) = e, code == .EADDRINUSE { return true }
        return false
    }

    private static func describe(_ e: NWError) -> String {
        isAddressInUse(e) ? "Port already in use" : e.debugDescription
    }

    private func accept(_ connection: NWConnection) {
        let c = HTTPConnection(connection: connection) { [weak self] request in
            await self?.respond(to: request) ?? HTTPResponse(status: 503, body: Data())
        }
        let key = ObjectIdentifier(c)
        connections[key] = c
        c.onClose = { [weak self] in self?.connections[key] = nil }
        c.start()
    }

    // MARK: Requests

    private func respond(to r: HTTPRequest) async -> HTTPResponse {
        if let origin = r.headers["origin"], !Self.isLocalOrigin(origin) {
            return HTTPResponse(status: 403, text: "Cross-origin requests are not allowed")
        }
        if let token, !r.fromLoopback, r.headers["authorization"] != "Bearer \(token)" {
            return HTTPResponse(status: 401, text: "Missing or wrong token", headers: ["WWW-Authenticate": "Bearer"])
        }
        let path = r.path.split(separator: "?").first.map(String.init) ?? r.path
        switch (r.method, path) {
        case ("POST", "/mcp"), ("POST", "/"):
            guard r.headers["content-type"]?.lowercased().hasPrefix("application/json") ?? false else {
                return HTTPResponse(status: 415, text: "Send application/json")
            }
            if MCPServer.isNotificationOnly(r.body) {
                _ = await server.handle(r.body)
                return HTTPResponse(status: 202, body: Data())
            }
            guard let body = await server.handle(r.body) else { return HTTPResponse(status: 202, body: Data()) }
            return HTTPResponse(status: 200, body: body, headers: ["Content-Type": "application/json"])
        case ("GET", "/mcp"):
            // No server-initiated stream.
            return HTTPResponse(status: 405, text: "Method not allowed", headers: ["Allow": "POST"])
        case ("DELETE", "/mcp"):
            return HTTPResponse(status: 200, body: Data())
        case ("GET", "/"):
            return HTTPResponse(status: 200, text: "Fillet MCP server. Connect an MCP client to /mcp.")
        default:
            return HTTPResponse(status: 404, text: "Not found")
        }
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

// MARK: - HTTP/1.1

struct HTTPRequest {
    var method: String
    var path: String
    /// Lower-cased names.
    var headers: [String: String]
    var body: Data
    var fromLoopback: Bool
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]

    init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
    }

    init(status: Int, text: String, headers: [String: String] = [:]) {
        self.init(status: status, body: Data((text + "\n").utf8), headers: headers.merging(["Content-Type": "text/plain; charset=utf-8"]) { a, _ in a })
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = keepAlive ? "keep-alive" : "close"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        default: "Status"
        }
    }
}

/// One TCP connection: parses requests (keep-alive, Content-Length or chunked bodies) and
/// writes the responses in order.
@MainActor
final class HTTPConnection {
    let connection: NWConnection
    var onClose: (() -> Void)?
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    private var closed = false
    private static let maxBody = 64 << 20

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    var fromLoopback: Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: Task { @MainActor in self?.close() }
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                await self.processBuffer()
                if done || error != nil { self.close() } else if !self.closed { self.receive() }
            }
        }
    }

    private func processBuffer() async {
        while !closed {
            guard let (request, consumed, keepAlive) = parse() else { return }
            buffer.removeSubrange(..<consumed)
            let response = await handler(request)
            send(response.serialized(keepAlive: keepAlive))
            if !keepAlive {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
        }
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// One complete request from the buffer, or nil when more bytes are needed.
    private func parse() -> (HTTPRequest, Int, Bool)? {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 << 10 { fail(400) }
            return nil
        }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { fail(400); return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerEnd.upperBound
        var body = Data()
        var end = bodyStart
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            // Both framings at once is ambiguous (request smuggling): refuse.
            guard headers["content-length"] == nil else { fail(400); return nil }
            guard buffer.endIndex - bodyStart <= Self.maxBody + 64 << 10 else { fail(413); return nil }
            switch Self.dechunk(buffer, from: bodyStart, limit: Self.maxBody) {
            case .incomplete: return nil
            case .invalid: fail(400); return nil
            case .tooLarge: fail(413); return nil
            case .complete(let decoded, let consumedTo):
                body = decoded
                end = consumedTo
            }
        } else {
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { fail(400); return nil }
            guard length <= Self.maxBody else { fail(413); return nil }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = buffer[bodyStart..<bodyStart + length]
            end = bodyStart + length
        }
        let version = requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.1"
        let connectionHeader = headers["connection"]?.lowercased()
        let keepAlive = version == "HTTP/1.0" ? connectionHeader == "keep-alive" : connectionHeader != "close"
        let request = HTTPRequest(method: String(requestLine[0]).uppercased(), path: String(requestLine[1]),
                                  headers: headers, body: Data(body), fromLoopback: fromLoopback)
        return (request, end - buffer.startIndex, keepAlive)
    }

    /// Answers with an error and hangs up once the answer is out (cancelling at once would drop it).
    private func fail(_ status: Int) {
        guard !closed else { return }
        closed = true
        let response = HTTPResponse(status: status, text: HTTPResponse.reason(status)).serialized(keepAlive: false)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connection.cancel()
                self?.onClose?()
            }
        })
    }

    enum Dechunked: Equatable {
        case incomplete
        case invalid
        case tooLarge
        case complete(Data, Data.Index)
    }

    /// Decodes a chunked body starting at `start`, refusing chunk sizes that are malformed or
    /// would take the body past `limit`.
    static func dechunk(_ data: Data, from start: Data.Index, limit: Int) -> Dechunked {
        var out = Data()
        var i = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[i...].firstRange(of: crlf) else { return .incomplete }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            let digits = sizeText.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isHexDigit), let size = Int(digits, radix: 16) else {
                return .invalid
            }
            guard out.count + size <= limit else { return .tooLarge }
            i = lineEnd.upperBound
            if size == 0 {
                // Skip trailers up to the blank line.
                guard let trailerEnd = data[i...].firstRange(of: crlf) else { return .incomplete }
                if trailerEnd.lowerBound == i { return .complete(out, trailerEnd.upperBound) }
                guard let end = data[i...].firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
                return .complete(out, end.upperBound)
            }
            guard data.endIndex - i >= size + 2 else { return .incomplete }
            out.append(data[i..<i + size])
            i += size + 2
        }
    }
}
