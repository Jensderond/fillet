import XCTest

/// An agent names the design it works on (`rename_design` over MCP) and the document window
/// follows: its title, and the file in the document browser. Runs in the real document window
/// (the agent server on `FILLET_MCP_PORT`, 7895 by default), not the automation app.
final class AgentNamingUITests: XCTestCase {
    var app: XCUIApplication!
    let port = ProcessInfo.processInfo.environment["FILLET_UITEST_MCP_PORT"] ?? "7895"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["FILLET_MCP": "1", "FILLET_MCP_PORT": port]
        app.launch()
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// A new design in its document window (see `SnappingUITests.openSketch`).
    func openNewDesign() {
        XCTAssertTrue(app.buttons["New Design"].firstMatch.waitForExistence(timeout: 10), "launch screen")
        sleep(1)
        point(516, 435).tap()
        if !app.buttons["Sketch"].firstMatch.waitForExistence(timeout: 15) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "New Design didn't open"
            shot.lifetime = .keepAlways
            add(shot)
            // The simulator often makes the file but can't open it (DocumentManager error 1): dismiss
            // the alert and open the file from the browser underneath, where it shows first.
            if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
            sleep(1)
            let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Untitled ' AND label ENDSWITH '.fillet'")).firstMatch
            if label.exists, label.frame.minY > 600 {
                point(label.frame.midX, label.frame.minY - 50).tap()  // its icon
            } else {
                point(100, 815).tap()
            }
        }
        XCTAssertTrue(app.buttons["Sketch"].firstMatch.waitForExistence(timeout: 15), "editor toolbar")
    }

    /// One JSON-RPC call to the app's MCP endpoint; the result's text.
    func mcp(_ method: String, _ params: [String: Any], id: Int) throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let done = expectation(description: method)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, error in
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? "\(error.map(String.init(describing:)) ?? "no data")"
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return body
    }

    func testRenameDesignNamesTheWindowAndItsFile() throws {
        openNewDesign()
        _ = try mcp("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                   "clientInfo": ["name": "ui-test", "version": "1"]], id: 1)
        let name = "Naming test \(Int.random(in: 1000...9999))"
        let reply = try mcp("tools/call", ["name": "rename_design", "arguments": ["name": name]], id: 2)
        print("rename_design: \(reply)")
        XCTAssertTrue(reply.contains("The file is now"), "the file was renamed: \(reply)")
        // The title is the navigation bar's title menu, not plain text.
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the window title shows the name")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
