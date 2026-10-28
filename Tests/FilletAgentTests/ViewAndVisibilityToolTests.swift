import CoreGraphics
import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import ImageIO
import Testing

@testable import FilletAgent

/// Hiding bodies, checking and exporting some of them, and close-up / section renders.
@Suite("Views and visibility")
@MainActor
struct ViewAndVisibilityToolTests {
    /// A stand-like part with a slot and a "device" standing in it.
    private func standAndDevice(_ c: Client) async throws {
        try await c.ok("primitive", ["kind": "box", "dimensions": [60, 40, 20], "name": "Stand"])
        try await c.ok("primitive", ["kind": "box", "dimensions": [80, 8, 10], "at": [0, 0, 12], "operation": "cut", "targets": "Stand", "name": "Slot"])
        try await c.ok("primitive", ["kind": "box", "dimensions": [70, 6, 50], "at": [0, 0, 12], "name": "Device"])
    }

    /// Renders and returns the image with the tool's text.
    private func render(_ c: Client, _ args: JSONValue) async throws -> (CGImage, String) {
        let r = try await c.request("tools/call", ["name": "render_view", "arguments": args])
        let content = try #require(r["result"]?["content"]?.array)
        #expect(r["result"]?["isError"]?.bool != true, "\(content)")
        let png = try #require(Data(base64Encoded: content.first?["data"]?.string ?? ""))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), content.last?["text"]?.string ?? "")
    }

    /// Pixels in the section colour (strong red).
    private func sectionPixels(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 0, to: pixels.count, by: 4).filter { i in
            Int(pixels[i]) > Int(pixels[i + 1]) + 50 && Int(pixels[i]) > Int(pixels[i + 2]) + 50
        }.count
    }

    @Test func hidesBodiesFromChecksAndExports() async throws {
        let c = Client()
        try await standAndDevice(c)
        let all = try await c.ok("check_print")
        #expect(all["bodies"] == ["Stand", "Device"])
        let hidden = try await c.ok("set_body_visibility", ["bodies": "Device", "visible": false])
        #expect(hidden["hidden"] == ["Device"] && hidden["visible"] == ["Stand"])
        #expect(c.workspace.nextUndo()?.action == "New Device")  // not an undo step
        let design = try await c.ok("get_design")
        #expect(design["bodies"]?.array?.last?["hidden"] == true)
        let stand = try await c.ok("check_print")
        #expect(stand["bodies"] == ["Stand"] && stand["fits_on_bed"] == true)
        // `bodies` checks and exports just those, hidden or not.
        let device = try await c.ok("check_print", ["bodies": ["Device"]])
        #expect(device["bodies"] == ["Device"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = try await c.ok("export", ["format": "stl", "bodies": ["Stand", "Device"], "path": .string(url.path)])
        #expect(exported["bodies"]?.number == 2)
        let visibleOnly = try await c.ok("export", ["format": "stl", "path": .string(url.path)])
        #expect(visibleOnly["body_names"] == ["Stand"])
        let (_, text) = try await render(c, ["width": 120, "height": 90])
        #expect(text.hasPrefix("1 visible bodies"))
        // Undo takes back steps, not visibility; showing it again works.
        try await c.ok("set_parameter", ["name": "gap", "expression": 1])
        try await c.ok("undo")
        #expect(c.workspace.hiddenBodies.count == 1)
        try await c.ok("set_body_visibility", ["bodies": ["Device"], "visible": true])
        #expect(c.workspace.hiddenBodies.isEmpty)
    }

    @Test func savesVisibilityWithTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-\(UUID().uuidString).fillet")
        defer { try? FileManager.default.removeItem(at: url) }
        let ws = try HeadlessWorkspace(fileURL: url)
        let server = FilletMCP.makeServer(host: HeadlessHost(workspace: ws))
        func call(_ tool: String, _ args: JSONValue) async throws {
            let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": args]]
            let r = try JSONValue(parsing: try #require(await server.handle(Data(body.serialized().utf8))))
            #expect(r["result"]?["isError"]?.bool != true)
        }
        try await call("primitive", ["kind": "box", "dimensions": [10, 10, 10], "name": "Cube"])
        try await call("set_body_visibility", ["bodies": "Cube", "visible": false])
        let saved = try Document(data: Data(contentsOf: url))
        #expect(saved.hiddenBodies.count == 1)
    }

    @Test func sectionCutsShowTheInside() async throws {
        let c = Client()
        try await standAndDevice(c)
        let (plain, plainText) = try await render(c, ["width": 240, "height": 180, "view": "right"])
        #expect(sectionPixels(plain) == 0)
        #expect(!plainText.contains("section"))
        let (cut, text) = try await render(c, ["width": 240, "height": 180, "section": ["origin": [0, 0, 0], "normal": "+x"],
                                                "projection": "orthographic"])
        #expect(sectionPixels(cut) > 2000)
        #expect(text.contains("2 visible bodies") && text.contains("cutting away the +x side") && text.contains("orthographic"))
        // Hidden bodies stay hidden in a section; with nothing left to cut, nothing shows red.
        let (hidden, hiddenText) = try await render(c, ["width": 240, "height": 180, "section": ["normal": [1, 0, 0]],
                                                        "hide": ["Stand", "Device"]])
        #expect(sectionPixels(hidden) == 0 && hiddenText.hasPrefix("0 visible bodies"))
        let bad = try await c.call("render_view", ["section": ["normal": [0, 0, 0]]])
        #expect(bad.isError && bad.text.contains("section.normal"))
    }

    @Test func closeUpsCentreOnATarget() async throws {
        let c = Client()
        try await standAndDevice(c)
        let (_, text) = try await render(c, ["width": 200, "height": 100, "target": [0, 0, 12], "size": 30, "view": "front"])
        #expect(text.contains("centred on [0, 0, 12], about 30 mm across"))

        let ws = c.workspace
        let model = await ws.evaluated()
        let r = Resolver(document: ws.document, model: model)
        let scene = DesignRendering.scene(document: ws.document, model: model)
        let wide = try FilletTools.camera(Args(["target": [1, 2, 3], "size": 40, "projection": "orthographic"]), r,
                                          scene: scene, sketch: nil, aspect: 2)
        #expect(wide.target == Vec3(1, 2, 3) && wide.projection == .orthographic)
        #expect(abs(wide.halfHeight(atDepth: wide.distance) - 20) < 1e-9)
        // Portrait: the width spans `size`.
        let tall = try FilletTools.camera(Args(["size": 40]), r, scene: scene, sketch: nil, aspect: 0.5)
        #expect(abs(tall.halfHeight(atDepth: tall.distance) * 0.5 - 20) < 1e-9)
        // A section without angles looks straight at the cut.
        let facing = try FilletTools.camera(Args([:]), r, scene: scene, sketch: nil, aspect: 1, facing: Vec3(0, -1, 0))
        #expect(facing.back.distance(to: Vec3(0, -1, 0)) < 1e-9)
        #expect(try FilletTools.sectionNormal("-z") == Vec3(0, 0, -1))
        #expect(try FilletTools.sectionNormal([0, 3, 4]).distance(to: Vec3(0, 0.6, 0.8)) < 1e-12)
    }
}
