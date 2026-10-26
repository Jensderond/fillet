import FilletAgent
import FilletCore
import Foundation

/// `fillet-mcp`: Fillet's MCP server for agents, over stdio.
///
///     fillet-mcp [design.fillet]           headless: model in this process, saving to the file after every step
///     fillet-mcp --connect [url] [--token t]  bridge to the running app, so the user watches (found when no url)
@main
struct FilletMCPCommand {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.contains("-h") || args.contains("--help") {
            print(usage)
            return
        }
        if let i = args.firstIndex(of: "--connect") {
            args.remove(at: i)
            var url: URL?
            if i < args.count, !args[i].hasPrefix("--"), let u = URL(string: args[i]), u.scheme != nil {
                url = u
                args.remove(at: i)
            }
            var token = ProcessInfo.processInfo.environment["FILLET_MCP_TOKEN"]
            if let t = args.firstIndex(of: "--token"), t + 1 < args.count { token = args[t + 1] }
            if let url {
                log("bridging stdio to \(url.absoluteString)")
                await MCPStdioTransport.bridge(to: url, token: token)
            } else {
                log("bridging stdio to the running Fillet app (found at the first request)")
                await MCPStdioTransport.bridge(token: token) { again in
                    let (url, source) = await MCPDiscovery.discover()
                    switch source {
                    case .fallback: log("no running Fillet found\(again ? " again" : ""); trying \(url.absoluteString)")
                    default: log("found Fillet at \(url.absoluteString) (\(source.rawValue))")
                    }
                    return url
                }
            }
            return
        }

        let workspace: HeadlessWorkspace
        if let path = args.first(where: { !$0.hasPrefix("-") }) {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                workspace = try HeadlessWorkspace(fileURL: url)
            } catch {
                log("can't open \(url.path): \(error)")
                exit(1)
            }
            log("headless, saving to \(url.path)")
        } else {
            workspace = HeadlessWorkspace()
            log("headless, in memory (use save_design to write a file)")
        }
        let host = HeadlessHost(workspace: workspace)
        let server = FilletMCP.makeServer(host: host, extraTools: FileTools.tools(workspace))
        await MCPStdioTransport.run(server)
    }

    static let usage = """
        fillet-mcp — Fillet's MCP server for AI agents (stdio)

          fillet-mcp [design.fillet]
              Headless: designs in this process, no window. With a file, the design is loaded from it
              (or created) and saved after every step, so it opens in Fillet afterwards.

          fillet-mcp --connect [URL] [--token TOKEN]
              Bridges to the running Fillet app (Design ▸ Allow Agent Connections), so the user sees
              the agent work in their window. Without a URL it finds the app: the endpoint the Mac
              app writes, then 127.0.0.1 ports 7878-7888, then Bonjour (an iPad), and finally
              http://127.0.0.1:7878/mcp. TOKEN (or $FILLET_MCP_TOKEN) is needed for an iPad.
        """

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("fillet-mcp: \(s)\n".utf8))
    }
}

/// Opening and saving files, only in the headless command.
@MainActor
enum FileTools {
    static func tools(_ ws: HeadlessWorkspace) -> [MCPTool] {
        [
            MCPTool(
                name: "open_design", title: "Open design",
                description: "Opens a .fillet file (created when missing); later changes are saved to it.",
                inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Path of the .fillet file"]],
                              "required": ["path"]]
            ) { args in
                guard let path = args["path"]?.string else { throw ToolError("`path` is required") }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let doc = FileManager.default.fileExists(atPath: url.path)
                    ? try Document(data: Data(contentsOf: url))
                    : Document(name: url.deletingPathExtension().lastPathComponent)
                ws.load(doc, fileURL: url)
                return .text("Opened \(url.path): \(doc.features.count) steps")
            },
            MCPTool(
                name: "save_design", title: "Save design",
                description: "Saves the design as a .fillet file (open it in Fillet on Mac or iPad); later changes are saved there too.",
                inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Path to write (default: the open file)"]]]
            ) { args in
                let path = args["path"]?.string
                guard let url = path.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? ws.fileURL else {
                    throw ToolError("No file yet: give `path`")
                }
                try ws.document.encoded().write(to: url, options: .atomic)
                ws.fileURL = url
                return .text("Saved \(url.path)")
            },
        ]
    }
}
