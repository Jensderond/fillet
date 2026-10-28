import XCTest

/// The rollback marker on a long timeline: the playback buttons keep it in view, and dragging it
/// from a step in the middle moves it rather than scrolling the ruler or picking a step. Runs in
/// the real document window, with the steps made over MCP.
final class TimelineMarkerUITests: DocumentWindowUITestCase {
    let steps = 20

    var marker: XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Rollback marker")).firstMatch }

    /// The marker's value, read through its accessibility element.
    var markerValue: String { (marker.value as? String) ?? "" }

    func station(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Step \(number), ")).firstMatch
    }

    /// A new design with `steps` boxes side by side, the ruler scrolled to its end.
    func openLongDesign() throws {
        openNewDesign()
        _ = try mcp("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                   "clientInfo": ["name": "ui-test", "version": "1"]], id: 1)
        for i in 0..<steps {
            let reply = try mcp("tools/call", ["name": "primitive", "arguments": [
                "kind": "box", "dimensions": ["width": 8, "depth": 8, "height": 8], "at": [i * 12, 0, 0],
                "operation": "new_body",
            ]], id: 10 + i)
            XCTAssertFalse(reply.contains("\"isError\":true"), "box \(i): \(reply)")
        }
        XCTAssertTrue(station(steps).waitForExistence(timeout: 10), "the last step is on the ruler")
        sleep(1)
    }

    func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The marker's x on screen is between the playback buttons and the window's edge.
    func assertMarkerInView(_ context: String) {
        let x = marker.frame.midX
        let rulerStart = app.buttons["Play to end"].firstMatch.frame.maxX
        XCTAssertTrue(x > rulerStart && x < app.windows.firstMatch.frame.maxX, "\(context): marker at \(x), ruler from \(rulerStart)")
    }

    func testPlaybackKeepsTheMarkerInView() throws {
        try openLongDesign()
        assertMarkerInView("at the end")
        app.buttons["Roll back to start"].firstMatch.tap()
        sleep(1)
        attachScreenshot("rolled back to start")
        XCTAssertEqual(markerValue, "after step 0 of \(steps)")
        assertMarkerInView("rolled back to start")
        app.buttons["Play to end"].firstMatch.tap()
        sleep(1)
        assertMarkerInView("played to end")
        for _ in 0..<12 { app.buttons["Step back"].firstMatch.tap() }
        sleep(1)
        XCTAssertEqual(markerValue, "after step \(steps - 12) of \(steps)")
        assertMarkerInView("stepped back")
    }

    func testDraggingTheMarkerFromAMiddleStep() throws {
        try openLongDesign()
        for _ in 0..<4 { app.buttons["Step back"].firstMatch.tap() }
        sleep(1)
        XCTAssertEqual(markerValue, "after step \(steps - 4) of \(steps)")
        let before = station(steps - 4).frame
        let pitch = station(steps - 4).frame.minX - station(steps - 5).frame.minX
        // Press on the caliper where it crosses the step chips (they used to take the touch) and
        // drag three steps back, resting there before letting go.
        let y = marker.frame.midY
        point(marker.frame.midX + 6, y).press(forDuration: 0.05, thenDragTo: point(marker.frame.midX + 6 - 3 * pitch, y),
                                               withVelocity: 300, thenHoldForDuration: 0.5)
        sleep(1)
        attachScreenshot("dragged back three steps")
        XCTAssertEqual(markerValue, "after step \(steps - 7) of \(steps)", "the marker moved three steps")
        XCTAssertEqual(station(steps - 4).frame.minX, before.minX, accuracy: 1, "the ruler didn't scroll")
        for n in (steps - 7)...(steps - 3) { XCTAssertFalse(station(n).isSelected, "step \(n) didn't open") }
    }
}
