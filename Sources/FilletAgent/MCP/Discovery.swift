import Foundation
import Network
import Synchronization

/// Finds the running Fillet app for `fillet-mcp --connect` without a URL.
///
/// In order:
/// 1. **Loopback**: 127.0.0.1 on the app's ports (7878, then the fallbacks 7879…7888 it moves to
///    when a port is taken), checking that the answer to `GET /` is Fillet's. Needs no file access
///    or permission, so it comes first.
/// 2. **Endpoint file**: the Mac app writes its endpoint to `Application Support/Fillet/mcp-endpoint`,
///    which for the sandboxed app is inside its container (covers a port set with `FILLET_MCP_PORT`).
/// 3. **Bonjour**: a Fillet advertising `_fillet-mcp._tcp` on the network (the iPad app).
/// 4. **Default**: http://127.0.0.1:7878/mcp, so the error names the usual address.
public enum MCPDiscovery {
    /// The ports the app listens on: 7878 first, then the ones it falls back to when a port is taken.
    public static let appPorts: [UInt16] = Array(7878...7888)
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:7878/mcp")!
    /// Relative to Application Support.
    public static let endpointFilePath = "Fillet/mcp-endpoint"
    public static let bonjourType = "_fillet-mcp._tcp"
    /// How `GET /` on Fillet's server starts.
    static let banner = "Fillet MCP server"

    public enum Source: String, Sendable {
        case loopback, file, bonjour, fallback
    }

    /// Where the Mac app's endpoint file is, as an unsandboxed process sees it: in the app's
    /// sandbox container, and in the plain Application Support for unsandboxed (development) builds.
    public static func endpointFiles(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        [
            home.appendingPathComponent("Library/Containers/app.fillet.Fillet/Data/Library/Application Support")
                .appendingPathComponent(endpointFilePath),
            home.appendingPathComponent("Library/Application Support").appendingPathComponent(endpointFilePath),
        ]
    }

    /// The app's endpoint, and how it was found.
    public static func discover(ports: [UInt16] = appPorts, endpointFiles files: [URL] = endpointFiles(),
                                bonjourTimeout: Duration = .seconds(2)) async -> (url: URL, source: Source) {
        if let url = await scanLoopback(ports: ports) { return (url, .loopback) }
        if let url = await fromEndpointFiles(files) { return (url, .file) }
        if bonjourTimeout > .zero, let url = await browseBonjour(timeout: bonjourTimeout) { return (url, .bonjour) }
        return (defaultEndpoint, .fallback)
    }

    /// The first of `ports` (in order) where Fillet answers on 127.0.0.1. All are tried at once.
    public static func scanLoopback(ports: [UInt16], timeout: Duration = .milliseconds(800)) async -> URL? {
        let found = await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, port) in ports.enumerated() {
                group.addTask { (i, await isFillet(endpoint(port: port), timeout: timeout)) }
            }
            var hits: [Int] = []
            for await (i, ok) in group where ok { hits.append(i) }
            return hits.min()
        }
        return found.map { endpoint(port: ports[$0]) }
    }

    public static func endpoint(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    /// Whether Fillet's MCP server answers at this endpoint (`GET /` on the same host and port).
    public static func isFillet(_ endpoint: URL, timeout: Duration = .milliseconds(800)) async -> Bool {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        parts.path = "/"
        parts.query = nil
        guard let root = parts.url else { return false }
        let config = URLSessionConfiguration.ephemeral
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        config.timeoutIntervalForRequest = seconds
        config.timeoutIntervalForResource = seconds
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: root),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix(banner)
    }

    /// The endpoint in the newest endpoint file that still answers as Fillet.
    static func fromEndpointFiles(_ files: [URL]) async -> URL? {
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return (url, attrs[.modificationDate] as? Date ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }) {
            guard let url = readEndpointFile(file) else { continue }
            if await isFillet(url) { return url }
        }
        return nil
    }

    /// The URL on the file's first line.
    static func readEndpointFile(_ file: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              let url = URL(string: line.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// The first Fillet advertising on the local network, resolved to an IPv4 address.
    static func browseBonjour(timeout: Duration) async -> URL? {
        let queue = DispatchQueue(label: "fillet-mcp.bonjour")
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            let once = Once(c)
            let browser = NWBrowser(for: .bonjour(type: bonjourType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                guard let result = results.first else { return }
                browser.cancel()
                resolve(result.endpoint, on: queue) { once.resume($0) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { once.resume(nil) }
            }
            browser.start(queue: queue)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()
                once.resume(nil)
            }
        }
    }

    /// Connects to a Bonjour service just long enough to learn its address and port.
    private static func resolve(_ service: NWEndpoint, on queue: DispatchQueue, _ done: @escaping @Sendable (URL?) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: service, using: params)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var url: URL?
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    let address: String
                    switch host {
                    case .ipv4(let a): address = "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
                    case .name(let n, _): address = n
                    default: address = ""
                    }
                    if !address.isEmpty { url = URL(string: "http://\(address):\(port.rawValue)/mcp") }
                }
                connection.cancel()
                done(url)
            case .failed, .cancelled:
                done(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

/// Resumes a continuation once, whichever callback gets there first.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ c: CheckedContinuation<T, Never>) { continuation = Mutex(c) }

    func resume(_ value: T) {
        continuation.withLock { c in
            c?.resume(returning: value)
            c = nil
        }
    }
}
