import UIKit
import XCTest

/// Screenshots for the user docs, taken in the real iPad document window (not the automation
/// app), driven by a JSON shot spec. Run it through `scripts/docs-shot.sh spec.json [udid]`, which
/// sets up the simulator (light, 9:41 status bar, clean app install, fixture) and passes the
/// spec's path as `TEST_RUNNER_FILLET_DOCS_SPEC`. Without that variable the test skips, so the
/// rest of the FilletUITests scheme is unaffected. See scripts/docs-shot.md.
///
/// Spec (paths may be absolute or relative to the spec file; `//` comments are not allowed):
///
///     {
///       "start": "new",                     // "new" (default): New Design; "none": stay on the launch
///                                           //   screen; {"open": "Bracket.fillet"}: open that file from the
///                                           //   browser (the wrapper copies "fixture" into the app first)
///       "fixture": "fixtures/bracket.fillet", // optional, read by the wrapper
///       "appearance": "light",              // optional, read by the wrapper ("light" | "dark")
///       "port": 7901,                       // optional, read by the wrapper (default: per simulator)
///       "orientation": "landscape",         // after the document opens: landscape (= landscapeLeft),
///                                           //   landscapeRight, portrait. Default landscape
///       "outDir": "/abs/dir",               // optional base for relative screenshot paths
///       "launchArguments": ["-fingerDraws", "YES"],   // optional
///       "clientName": "claude-code",        // optional: the MCP client name the agent pill shows
///                                           //   ("Claude" for any name with "claude"). Default docs-shot
///       "steps": [
///         {"do": "mcp", "tool": "primitive", "arguments": {…}, "timeout": 60, "allowError": false},
///         {"do": "idle"},                   // agent pill gone, no "Updating", then 0.5 s
///         {"do": "tap", "label": "Browser"},                // also doubleTap. Target: "id" | "label" | "labelContains"
///         {"do": "tap", "x": 683, "y": 512},                //   or "x","y" in points of the current
///         {"do": "longPress", "label": "Step 2, Fillet", "duration": 1},   // orientation; with an element,
///         {"do": "drag", "from": {"x": 600, "y": 500}, "to": {"label": "…"}, //   "dx","dy" offset its centre;
///                  "press": 0.15, "velocity": 300, "hold": 0.3},           //   "type" (button, staticText,
///         {"do": "type", "text": "12", "into": {"label": "Radius"}, "clear": true}, // textField, cell, any)
///         {"do": "key", "key": "escape", "modifiers": ["command"]},         //   and "index" narrow it
///         {"do": "panel", "name": "browser", "show": false},  // browser | overhangs (tool strip toggles)
///         {"do": "rotate", "to": "portrait"},
///         {"do": "save"},                   // home and back: the document saves (for making fixtures)
///         {"do": "wait", "seconds": 1.5},
///         {"do": "waitFor", "label": "Fillet 1", "timeout": 10, "gone": false},
///         {"do": "screenshot", "path": "hero.png", "settle": true},
///         {"do": "screenshot", "path": "strip.png", "of": {"label": "Sketch", "padding": 8}},  // a crop
///         {"do": "dump", "path": "tree.txt"}  // the accessibility tree, to find labels
///       ]
///     }
///
/// A screenshot is the whole screen (status bar included) at the device's pixel size in the
/// current orientation: 2732×2048 for a 12.9" iPad in landscape. With "of" it is cropped to that
/// element's frame (plus "padding" points); an element that is off screen fails the step.
/// Before each screenshot the test waits for idle unless "settle" is false. Each written file is
/// printed as `DOCS-SHOT: <path> <width>x<height>`.
final class DocsScreenshotUITests: DocumentWindowUITestCase {
    private var spec: [String: Any] = [:]
    private var specDirectory: URL!
    private var rpcID = 1
    private var initialized = false
    private var lastMCPCall: Date?

    override func setUp() {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["FILLET_DOCS_SPEC"] else { return }
        let url = URL(fileURLWithPath: path)
        specDirectory = url.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Can't read the shot spec at \(path) (is it valid JSON?)")
            return
        }
        spec = object
        // The open flow taps launch-screen points that are measured in portrait.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment = ["FILLET_MCP": "1", "FILLET_MCP_PORT": port]
        app.launchArguments = spec["launchArguments"] as? [String] ?? []
        app.launch()
    }

    func testDocsShots() throws {
        guard ProcessInfo.processInfo.environment["FILLET_DOCS_SPEC"] != nil else {
            throw XCTSkip("No shot spec: run scripts/docs-shot.sh")
        }
        try start()
        if (spec["start"] as? String) != "none" {
            rotate(spec["orientation"] as? String ?? "landscape")
        }
        for (i, step) in (spec["steps"] as? [[String: Any]] ?? []).enumerated() {
            let action = step["do"] as? String ?? "?"
            print("DOCS-STEP \(i + 1): \(action)")
            try run(step, action: action, index: i + 1)
        }
    }

    // MARK: Opening

    private func start() throws {
        let start = spec["start"]
        if let open = start as? [String: Any] {
            guard let name = open["open"] as? String else { throw failure("`start` needs {\"open\": \"File.fillet\"}") }
            try openFile(name)
            return
        }
        switch start as? String ?? "new" {
        case "new":
            try openNew()
        case "none":
            XCTAssertTrue(app.buttons["New Design"].firstMatch.waitForExistence(timeout: 10), "launch screen")
            sleep(1)
        default:
            throw failure("`start` must be \"new\", \"none\" or {\"open\": \"File.fillet\"}")
        }
    }

    private var editorOpen: XCUIElement { app.buttons["Sketch"].firstMatch }

    /// New Design. In the simulator it often makes the file but can't open it (DocumentManager
    /// error 1): then dismiss the alert and open the new file from the browser underneath. On a
    /// freshly made simulator even that can fail until the app is relaunched, so it tries up to
    /// three launches.
    private func openNew() throws {
        for round in 1...3 {
            if round > 1 { relaunch(round) }
            XCTAssertTrue(app.buttons["New Design"].firstMatch.waitForExistence(timeout: 15), "launch screen")
            sleep(1)
            if round > 1, cell(prefix: "Untitled").exists, openFromBrowser(prefix: "Untitled", attempts: 1) { return }
            // The launch scene's accessibility frames don't match its drawing: tap where the button shows.
            point(516, 435).tap()
            let alert = app.alerts.firstMatch
            let deadline = Date().addingTimeInterval(20)
            while !editorOpen.exists, !alert.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            if editorOpen.exists { return }
            if alert.exists {
                print("DOCS-OPEN: New Design hit “\(alert.label)”; opening the file from the browser")
                alert.buttons.firstMatch.tap()
            }
            if openFromBrowser(prefix: "Untitled", attempts: 2) { return }
        }
        throw openFailure("a new design")
    }

    /// Opens a file from the launch screen's browser (the wrapper put fixtures in the app's Documents).
    private func openFile(_ name: String) throws {
        let file = name.hasSuffix(".fillet") ? name : name + ".fillet"
        for round in 1...3 {
            if round > 1 { relaunch(round) }
            XCTAssertTrue(app.buttons["New Design"].firstMatch.waitForExistence(timeout: 15), "launch screen")
            sleep(1)
            if !cell(prefix: file + ",").waitForExistence(timeout: 5) {
                // A fresh install shows Recents, which doesn't list files nobody opened yet.
                app.buttons["Browse"].firstMatch.tap()
                sleep(2)
            }
            if openFromBrowser(prefix: file + ",", attempts: 2) { return }
        }
        throw openFailure(file)
    }

    private func relaunch(_ round: Int) {
        print("DOCS-OPEN: relaunching the app (launch \(round))")
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        app.terminate()
        app.launch()
    }

    private func cell(prefix: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// Taps the browser's file until the document window opens: its icon (the top of the cell),
    /// then the cell itself.
    private func openFromBrowser(prefix: String, attempts: Int) -> Bool {
        let file = cell(prefix: prefix)
        for attempt in 1...attempts {
            guard file.waitForExistence(timeout: 10) else { return false }
            sleep(2)  // the browser animates in after the alert; a tap during that does nothing
            if attempt == 1 {
                let f = file.frame
                point(f.midX, f.minY + 45).tap()
            } else {
                file.tap()
            }
            if editorOpen.waitForExistence(timeout: 12) { return true }
            print("DOCS-OPEN: tap \(attempt) didn't open \(prefix)")
            if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        }
        return false
    }

    private func openFailure(_ what: String) -> Error {
        dumpTree(to: "/tmp/fillet-docs-open-failed.txt")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        return failure("Couldn't open \(what) after three launches (tree in /tmp/fillet-docs-open-failed.txt)")
    }

    // MARK: Steps

    private func run(_ step: [String: Any], action: String, index: Int) throws {
        switch action {
        case "mcp":
            guard let tool = step["tool"] as? String else { throw failure("step \(index): mcp needs \"tool\"") }
            let reply = try callTool(tool, step["arguments"] as? [String: Any] ?? [:],
                                     timeout: double(step["timeout"]) ?? 120)
            print("DOCS-MCP \(tool): \(reply.text.prefix(400))")
            if reply.isError, step["allowError"] as? Bool != true {
                throw failure("step \(index): \(tool) failed: \(reply.text)")
            }
        case "idle":
            waitForIdle()
        case "tap":
            let target = try coordinate(step, index)
            target.tap()
        case "doubleTap":
            try coordinate(step, index).doubleTap()
        case "longPress":
            try coordinate(step, index).press(forDuration: double(step["duration"]) ?? 1)
        case "drag":
            guard let from = step["from"] as? [String: Any], let to = step["to"] as? [String: Any] else {
                throw failure("step \(index): drag needs \"from\" and \"to\"")
            }
            try coordinate(from, index).press(
                forDuration: double(step["press"]) ?? 0.15, thenDragTo: try coordinate(to, index),
                withVelocity: XCUIGestureVelocity(rawValue: CGFloat(double(step["velocity"]) ?? 300)),
                thenHoldForDuration: double(step["hold"]) ?? 0.1)
        case "type":
            guard let text = step["text"] as? String else { throw failure("step \(index): type needs \"text\"") }
            if let into = step["into"] as? [String: Any] {
                let field = try element(into, index)
                field.tap()
                if step["clear"] as? Bool == true, let value = field.value as? String, !value.isEmpty {
                    // The tap puts the caret where it landed: go to the end, then delete back.
                    for _ in 0..<(value.count + 1) { field.typeKey(.rightArrow, modifierFlags: []) }
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 1))
                }
                field.typeText(text)
            } else {
                app.typeText(text)
            }
        case "key":
            guard let key = step["key"] as? String else { throw failure("step \(index): key needs \"key\"") }
            app.typeKey(keyName(key), modifierFlags: modifiers(step["modifiers"] as? [String] ?? []))
        case "panel", "toggle":
            let label: String
            if let name = step["name"] as? String {
                label = ["browser": "Browser", "overhangs": "Overhangs"][name.lowercased()] ?? name
            } else if let l = step["label"] as? String {
                label = l
            } else {
                throw failure("step \(index): panel needs \"name\" (browser, overhangs)")
            }
            let show = step["show"] as? Bool ?? step["on"] as? Bool ?? true
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard button.waitForExistence(timeout: 5) else { throw failure("step \(index): no “\(label)” button") }
            if button.isSelected != show {
                button.tap()
                sleep(1)  // its panel animates in or out
            }
        case "rotate":
            rotate(step["to"] as? String ?? "landscape")
        case "save":
            // Going to the background makes the document save (it autosaves only now and then),
            // so the file in the app's Documents can serve as a fixture.
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            XCTAssertTrue(editorOpen.waitForExistence(timeout: 10), "back in the document window")
            sleep(1)
        case "wait":
            Thread.sleep(forTimeInterval: double(step["seconds"]) ?? 1)
        case "waitFor":
            let e = query(step)
            let timeout = double(step["timeout"]) ?? 10
            if step["gone"] as? Bool == true {
                let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
                guard XCTWaiter().wait(for: [gone], timeout: timeout) == .completed else {
                    throw failure("step \(index): \(describe(step)) still shows after \(timeout) s")
                }
            } else if !e.waitForExistence(timeout: timeout) {
                throw failure("step \(index): \(describe(step)) didn't show in \(timeout) s")
            }
        case "screenshot":
            guard let path = step["path"] as? String else { throw failure("step \(index): screenshot needs \"path\"") }
            if step["settle"] as? Bool != false { waitForIdle() }
            var image = upright(XCUIScreen.main.screenshot().image)
            if let of = step["of"] as? [String: Any] {
                // A crop of the screen, so it matches the full shots pixel for pixel.
                let pad = CGFloat(double(of["padding"]) ?? 0)
                let frame = try element(of, index).frame.insetBy(dx: -pad, dy: -pad)
                let visible = frame.intersection(CGRect(origin: .zero, size: image.size))
                guard !visible.isNull, visible.width >= 4, visible.height >= 4 else {
                    throw failure("step \(index): \(describe(of)) is off screen (\(frame)); scroll or tap so it shows first")
                }
                let s = image.scale
                guard let cg = image.cgImage?.cropping(to: CGRect(x: visible.minX * s, y: visible.minY * s,
                                                                  width: visible.width * s, height: visible.height * s)) else {
                    throw failure("step \(index): couldn't crop to \(describe(of))")
                }
                image = UIImage(cgImage: cg, scale: s, orientation: .up)
            }
            guard let png = image.pngData() else { throw failure("step \(index): couldn't encode the screenshot") }
            let url = resolve(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            print("DOCS-SHOT: \(url.path) \(Int(pixels.width))x\(Int(pixels.height))")
            let attachment = XCTAttachment(image: image)
            attachment.name = url.lastPathComponent
            attachment.lifetime = .keepAlways
            add(attachment)
        case "dump":
            dumpTree(to: resolve(step["path"] as? String ?? "tree.txt").path)
        default:
            throw failure("step \(index): unknown action “\(action)”")
        }
    }

    // MARK: Waiting

    /// No agent pill (it stays 2.6 s after the last tool call), no "Updating", then a moment for
    /// the viewport to draw.
    private func waitForIdle() {
        if let last = lastMCPCall {
            let left = 2.9 - Date().timeIntervalSince(last)
            if left > 0 { Thread.sleep(forTimeInterval: left) }
        }
        let updating = app.staticTexts["Updating"].firstMatch
        let deadline = Date().addingTimeInterval(120)
        while updating.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: Targets

    private func query(_ t: [String: Any]) -> XCUIElement {
        let type: XCUIElement.ElementType = switch t["type"] as? String {
        case "button": .button
        case "staticText", "text": .staticText
        case "textField": .textField
        case "cell": .cell
        case "image": .image
        case "other": .other
        default: .any
        }
        let predicate: NSPredicate
        if let id = t["id"] as? String {
            predicate = NSPredicate(format: "identifier == %@", id)
        } else if let label = t["label"] as? String {
            predicate = NSPredicate(format: "label == %@", label)
        } else if let part = t["labelContains"] as? String {
            predicate = NSPredicate(format: "label CONTAINS %@", part)
        } else {
            predicate = NSPredicate(value: false)
        }
        let matches = app.descendants(matching: type).matching(predicate)
        if let i = t["index"] as? Int { return matches.element(boundBy: i) }
        return matches.firstMatch
    }

    private func element(_ t: [String: Any], _ index: Int) throws -> XCUIElement {
        let e = query(t)
        guard e.waitForExistence(timeout: double(t["timeout"]) ?? 10) else {
            throw failure("step \(index): no element \(describe(t))")
        }
        return e
    }

    /// A point target ("x", "y") or an element's centre, moved by "dx", "dy".
    private func coordinate(_ t: [String: Any], _ index: Int) throws -> XCUICoordinate {
        if let x = double(t["x"]), let y = double(t["y"]) { return point(CGFloat(x), CGFloat(y)) }
        let e = try element(t, index)
        return e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: double(t["dx"]) ?? 0, dy: double(t["dy"]) ?? 0))
    }

    private func describe(_ t: [String: Any]) -> String {
        ["id", "label", "labelContains", "type", "index"].compactMap { k in t[k].map { "\(k)=\($0)" } }.joined(separator: " ")
    }

    // MARK: MCP

    private func callTool(_ name: String, _ arguments: [String: Any], timeout: TimeInterval) throws -> (text: String, isError: Bool) {
        if !initialized {
            _ = try rpc("initialize", ["protocolVersion": "2025-03-26", "capabilities": [String: Any](),
                                       "clientInfo": ["name": spec["clientName"] as? String ?? "docs-shot", "version": "1"]], timeout: 30)
            initialized = true
        }
        defer { lastMCPCall = Date() }
        let body = try rpc("tools/call", ["name": name, "arguments": arguments], timeout: timeout)
        // A JSON body, or server-sent events whose data line holds it.
        let json = body.hasPrefix("{") ? body
            : body.split(separator: "\n").first { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? body
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return (body, true)
        }
        if let error = object["error"] as? [String: Any] { return ("\(error["message"] ?? error)", true) }
        let result = object["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }

    private func rpc(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> String {
        rpcID += 1
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": rpcID, "method": method, "params": params])
        let port = self.port
        let done = expectation(description: method)
        var body = ""
        var failed: String?
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { failed = "\(error.localizedDescription) (is the app's agent server on port \(port)?)" }
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: timeout + 5)
        if let failed { throw failure("\(method): \(failed)") }
        return body
    }

    // MARK: Helpers

    private func rotate(_ name: String) {
        let o: UIDeviceOrientation = switch name.lowercased() {
        case "portrait": .portrait
        case "portraitupsidedown": .portraitUpsideDown
        case "landscaperight": .landscapeRight
        default: .landscapeLeft
        }
        guard XCUIDevice.shared.orientation != o else { return }
        XCUIDevice.shared.orientation = o
        sleep(2)  // the rotation animation and the layout after it
    }

    /// Screenshots come back with an orientation flag; docs need the pixels upright.
    private func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        var base: URL = specDirectory
        if let out = spec["outDir"] as? String {
            base = out.hasPrefix("/") ? URL(fileURLWithPath: out) : specDirectory.appendingPathComponent(out)
        }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    private func dumpTree(to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        print("DOCS-DUMP: \(path)")
    }

    private func keyName(_ key: String) -> String {
        switch key.lowercased() {
        case "escape", "esc": XCUIKeyboardKey.escape.rawValue
        case "return", "enter": XCUIKeyboardKey.return.rawValue
        case "delete", "backspace": XCUIKeyboardKey.delete.rawValue
        case "tab": XCUIKeyboardKey.tab.rawValue
        case "space": XCUIKeyboardKey.space.rawValue
        case "up": XCUIKeyboardKey.upArrow.rawValue
        case "down": XCUIKeyboardKey.downArrow.rawValue
        case "left": XCUIKeyboardKey.leftArrow.rawValue
        case "right": XCUIKeyboardKey.rightArrow.rawValue
        default: key
        }
    }

    private func modifiers(_ names: [String]) -> XCUIElement.KeyModifierFlags {
        names.reduce(into: []) { flags, name in
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: break
            }
        }
    }

    private func double(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private func failure(_ message: String) -> Error {
        NSError(domain: "DocsShot", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
