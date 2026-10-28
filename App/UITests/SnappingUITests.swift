import XCTest

/// Snapping with real finger drags in the document window (not the automation app): a line,
/// then lines whose ends land a few points off its vertex and midpoint. The inspector shows the
/// drawn line's coordinates, so the test reads back that the ends snapped exactly. Each drag
/// holds at its end for a moment, for screenshots of the guides from outside
/// (`FILLET_UITEST_HOLD` seconds, default 0.3).
final class SnappingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fingerDraws", "YES"]
        app.launch()
    }

    var hold: TimeInterval {
        ProcessInfo.processInfo.environment["FILLET_UITEST_HOLD"].flatMap(Double.init) ?? 0.3
    }

    /// A point in the app's window, in points.
    func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    func drag(_ from: CGPoint, _ to: CGPoint) {
        point(from.x, from.y).press(forDuration: 0.15, thenDragTo: point(to.x, to.y), withVelocity: 300, thenHoldForDuration: hold)
    }

    /// Start X, Start Y, End X, End Y of the selected line, from the inspector's fields.
    func selectedLine(_ file: StaticString = #filePath, _ line: UInt = #line) -> [Double] {
        let fields = app.textFields.allElementsBoundByIndex.compactMap { ($0.value as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) } }
        XCTAssertGreaterThanOrEqual(fields.count, 4, "the inspector shows the line's coordinates: \(fields)", file: file, line: line)
        return Array(fields.prefix(4))
    }

    func openSketch() {
        XCTAssertTrue(app.buttons["New Design"].firstMatch.waitForExistence(timeout: 10), "launch screen")
        sleep(1)
        // The launch scene's accessibility frames don't match its drawing: tap the button where it shows.
        point(516, 435).tap()
        // In the simulator the new file is often made but not opened (DocumentManager error 1):
        // open the newest file from Recents instead.
        if !app.buttons["Sketch"].firstMatch.waitForExistence(timeout: 5) {
            if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
            app.buttons["Recents"].firstMatch.tap()
            sleep(2)
            let newest = app.cells.firstMatch
            if newest.exists { newest.tap() } else { point(100, 815).tap() }
        }
        let sketch = app.buttons["Sketch"].firstMatch
        XCTAssertTrue(sketch.waitForExistence(timeout: 10), "editor toolbar")
        sketch.tap()
        let xy = app.buttons["XY plane"].firstMatch
        XCTAssertTrue(xy.waitForExistence(timeout: 5), "the plane bar")
        xy.tap()
        XCTAssertTrue(app.buttons["Draw with finger"].waitForExistence(timeout: 5), "sketch mode")
        sleep(1)
    }

    func testLinesSnapToVertexAndMidpointWithAFinger() throws {
        openSketch()
        let done = app.buttons["Done"]

        // L1: a slanted line.
        drag(CGPoint(x: 200, y: 900), CGPoint(x: 450, y: 600))
        done.tap()
        let l1 = selectedLine()
        print("L1 \(l1)")

        // L2: from the right, ending 7 pt below and left of L1's top end, short of reaching it:
        // level with it (a horizontal guide), not on it.
        drag(CGPoint(x: 650, y: 1000), CGPoint(x: 290, y: 607))
        done.tap()
        let l2 = selectedLine()
        print("L2 \(l2)")
        XCTAssertEqual(l2[3], l1[3], "L2 ends level with L1's top end")
        XCTAssertNotEqual(l2[2], l1[2], "…beside it, not on it")

        // L3: ending 6 pt off L1's midpoint lands exactly on it.
        drag(CGPoint(x: 650, y: 1150), CGPoint(x: 331, y: 744))
        done.tap()
        let l3 = selectedLine()
        print("L3 \(l3)")
        XCTAssertEqual(l3[2], (l1[0] + l1[2]) / 2, accuracy: 1e-6, "L3 ends on L1's midpoint (x)")
        XCTAssertEqual(l3[3], (l1[1] + l1[3]) / 2, accuracy: 1e-6, "L3 ends on L1's midpoint (y)")

        // L4: straight down from 5 pt beside L1's bottom end: a vertical guide.
        drag(CGPoint(x: 205, y: 1000), CGPoint(x: 205, y: 1150))
        done.tap()
        let l4 = selectedLine()
        print("L4 \(l4)")
        XCTAssertEqual(l4[0], l1[0], "L4 starts under L1's bottom end")
        XCTAssertEqual(l4[2], l1[0], "…and stays vertical with it")
    }
}
