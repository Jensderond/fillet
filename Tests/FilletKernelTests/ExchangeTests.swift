import Foundation
import Testing
@testable import FilletKernel

@Suite("STEP exchange")
struct ExchangeTests {
    @Test func exportImportRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("parts.step")

        let bracket = try cube(10).filleted(edges: [0], radius: 2)
        let peg = try Shape.cylinder(base: Plane(origin: Vec3(30, 0, 0), normal: .unitZ, xDir: .unitX), radius: 3, height: 15)
        try Shape.exportSTEP([(bracket, "Wall Bracket"), (peg, "Peg")], url: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("ISO-10303-21"))
        #expect(text.contains("AUTOMOTIVE_DESIGN"))  // AP214
        #expect(text.contains("'Wall Bracket'"))
        #expect(text.contains("'Peg'"))
        #expect(text.contains(".MILLI."))

        let imported = try Shape.importSTEP(url: url)
        #expect(imported.solidCount == 2)
        #expect(close(imported.volume, bracket.volume + peg.volume, rel: 1e-6))
        #expect(imported.isValid)
        let b = try #require(imported.bounds)
        #expect(close(b.max.x, 33, abs: 1e-3))
    }

    @Test func importErrors() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        expectKernelError("does not exist") { _ = try Shape.importSTEP(url: dir.appendingPathComponent("missing.step")) }
        let junk = dir.appendingPathComponent("junk.step")
        try "hello".write(to: junk, atomically: true, encoding: .utf8)
        expectKernelError { _ = try Shape.importSTEP(url: junk) }
    }

    @Test func exportErrors() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        expectKernelError("nothing") { try Shape.exportSTEP([], url: dir.appendingPathComponent("a.step")) }
        expectKernelError { try Shape.exportSTEP([(try cube(1), "x")], url: dir.appendingPathComponent("no/such/dir/a.step")) }
    }
}
