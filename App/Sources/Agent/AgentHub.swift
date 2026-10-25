import FilletAgent
import FilletCore
import FilletViewport
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Lets AI agents design in the open windows over MCP (Streamable HTTP on port 7878), while
/// the user watches: every agent step lands in the window's document as one undoable change.
///
/// Off until the user allows it (Design ▸ Allow Agent Connections, or the toolbar's agent
/// button); `FILLET_MCP=1` turns it on at launch and `FILLET_MCP_PORT` picks another port.
/// On the Mac the server only listens on 127.0.0.1. On iPad it listens on the network so an
/// agent on a Mac can reach it, and clients from other devices must send the bearer token.
@MainActor @Observable
final class AgentHub: WorkspaceHost {
    static let shared = AgentHub()

    static let enabledKey = "agentConnectionsEnabled"
    private static let tokenKey = "agentConnectionToken"

    /// Whether agents may connect (remembered across launches).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    private(set) var state: MCPHTTPTransport.State = .stopped
    /// The agent client that connected last ("claude-code").
    private(set) var clientName: String?
    /// What the agent is doing right now (nil between calls).
    private(set) var activity: String?
    /// When the agent last did something, to keep its indicator up between calls.
    private(set) var lastActivity: Date?

    let port: UInt16
    #if os(iOS)
    /// Required from agents on other devices.
    let token: String
    #endif

    @ObservationIgnored private var transport: MCPHTTPTransport?
    @ObservationIgnored private var live: [LiveWorkspace] = []
    @ObservationIgnored private var currentID: UUID?
    /// Waiting for the window `openNewDesign` asked for.
    @ObservationIgnored private var newWindowWaiter: (id: UUID, continuation: CheckedContinuation<LiveWorkspace?, Never>)?

    private init() {
        let env = ProcessInfo.processInfo.environment
        port = env["FILLET_MCP_PORT"].flatMap(UInt16.init) ?? 7878
        #if os(iOS)
        if let saved = UserDefaults.standard.string(forKey: Self.tokenKey) {
            token = saved
        } else {
            token = Self.makeToken()
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
        }
        #endif
        isEnabled = env["FILLET_MCP"] == "1" || UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    // MARK: Server

    private func start() {
        guard transport == nil else { return }
        let server = FilletMCP.makeServer(host: self)
        server.onInitialize = { [weak self] name in self?.clientName = name }
        #if os(iOS)
        let transport = MCPHTTPTransport(server: server, port: port, binding: .network, token: token)
        #else
        let transport = MCPHTTPTransport(server: server, port: port, binding: .loopback)
        #endif
        transport.onStateChange = { [weak self] s in self?.state = s }
        self.transport = transport
        transport.start()
    }

    private func stop() {
        transport?.stop()
        transport = nil
        state = .stopped
        activity = nil
    }

    /// The endpoint agents connect to.
    var endpoint: String {
        #if os(iOS)
        "http://\(Self.localIPAddress() ?? "<ipad-address>"):\(port)/mcp"
        #else
        "http://127.0.0.1:\(port)/mcp"
        #endif
    }

    /// One command that connects Claude Code to this app.
    var claudeCodeCommand: String {
        #if os(iOS)
        "claude mcp add --transport http fillet \(endpoint) --header \"Authorization: Bearer \(token)\""
        #else
        "claude mcp add --transport http fillet \(endpoint)"
        #endif
    }

    /// The agent's friendly name for the indicator.
    var agentName: String {
        guard let c = clientName?.lowercased() else { return "Agent" }
        if c.contains("claude") { return "Claude" }
        if c.contains("codex") { return "Codex" }
        if c.contains("cursor") { return "Cursor" }
        return clientName ?? "Agent"
    }

    // MARK: WorkspaceHost

    var hostDescription: String {
        #if os(iOS)
        "Fillet on iPad (live: the user sees each step)"
        #else
        "Fillet on the Mac (live: the user sees each step)"
        #endif
    }

    var workspaces: [any DesignWorkspace] {
        live.removeAll { $0.session == nil }
        return live
    }

    var current: (any DesignWorkspace)? {
        let open = workspaces
        return open.first { $0.id == currentID } ?? open.last
    }

    func select(_ id: UUID) -> Bool {
        guard workspaces.contains(where: { $0.id == id }) else { return false }
        currentID = id
        return true
    }

    func openNewDesign() async throws -> (any DesignWorkspace)? {
        #if os(macOS)
        let id = UUID()
        let window: LiveWorkspace? = await withCheckedContinuation { c in
            resumeNewWindowWaiter(nil)  // an earlier request still waiting gives up
            newWindowWaiter = (id, c)
            NSDocumentController.shared.newDocument(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if self.newWindowWaiter?.id == id { self.resumeNewWindowWaiter(nil) }
            }
        }
        guard let window else { throw ToolError("Fillet didn't open a new window") }
        return window
        #else
        return nil  // iPad windows come from the document browser; the design is replaced instead
        #endif
    }

    func agentActivity(_ text: String?) {
        activity = text
        lastActivity = .now
    }

    /// Whether the agent indicator shows on this window: the agent is working on it, or did in the last moments.
    func isWorking(on session: DesignSession, now: Date = .now) -> Bool {
        guard transport != nil, (current as? LiveWorkspace)?.session === session else { return false }
        if activity != nil { return true }
        return lastActivity.map { now.timeIntervalSince($0) < 2.5 } ?? false
    }

    // MARK: Windows

    /// A document window opened: agents can work on it (and do, when it's the newest).
    func register(_ session: DesignSession) {
        guard !live.contains(where: { $0.session === session }) else { return }
        let ws = LiveWorkspace(session: session)
        live.append(ws)
        currentID = ws.id
        resumeNewWindowWaiter(ws)
    }

    private func resumeNewWindowWaiter(_ ws: LiveWorkspace?) {
        guard let waiter = newWindowWaiter else { return }
        newWindowWaiter = nil
        waiter.continuation.resume(returning: ws)
    }

    func unregister(_ session: DesignSession) {
        live.removeAll { $0.session === session || $0.session == nil }
    }

    /// The user brought this window to the front: agents follow it.
    func activated(_ session: DesignSession) {
        if let ws = live.first(where: { $0.session === session }) { currentID = ws.id }
    }

    // MARK: Helpers

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    /// The Wi-Fi (or first non-loopback) IPv4 address.
    static func localIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
