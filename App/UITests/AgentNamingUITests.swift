import XCTest

/// An agent names the design it works on (`rename_design` over MCP) and the document window
/// follows: its title, and the file in the document browser. Runs in the real document window
/// (the agent server on `FILLET_MCP_PORT`, 7895 by default), not the automation app.
final class AgentNamingUITests: DocumentWindowUITestCase {
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
