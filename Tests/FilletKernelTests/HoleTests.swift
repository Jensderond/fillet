import Foundation
import Testing
@testable import FilletKernel

@Suite("Holes")
struct HoleTests {
    /// 40 × 40 × 20 block; holes go into its top face (z = 20) at (10, 10).
    let block = { try! Shape.box(corner: .zero, size: Vec3(40, 40, 20)) }()
    let top = Vec3(10, 10, 20)
    let down = -Vec3.unitZ
    static let deg = Double.pi / 180

    private func removed(_ spec: HoleSpec, at centers: [Vec3]? = nil) throws -> Double {
        let r = try block.drilled(at: centers ?? [top], direction: down, spec)
        #expect(r.isValid)
        #expect(r.solidCount == 1)
        return block.volume - r.volume
    }

    @Test func flatBottomedHole() throws {
        let v = try removed(HoleSpec(diameter: 6, depth: 10, tipAngle: 0))
        #expect(close(v, .pi * 9 * 10, rel: 1e-6))
    }

    @Test func drillPointAddsACone() throws {
        let v = try removed(HoleSpec(diameter: 6, depth: 10, tipAngle: 118 * Self.deg))
        let tip: Double = 3 / tan(59 * Self.deg)
        let expected: Double = Double.pi * 9 * (10 + tip / 3)
        #expect(close(v, expected, rel: 1e-6))
    }

    @Test func throughAllIgnoresTheTip() throws {
        let r = try block.drilled(at: [top], direction: down, HoleSpec(diameter: 6, depth: nil))
        #expect(close(block.volume - r.volume, .pi * 9 * 20, rel: 1e-6))
        // The hole wall is one cylinder, from the top face to the bottom one.
        let walls = (0..<r.faceCount).filter { r.faceInfo($0).surface == .cylinder }
        #expect(walls.count == 1)
        #expect(close(r.faceInfo(walls[0]).area, .pi * 6 * 20, rel: 1e-6))
    }

    @Test func counterbore() throws {
        let v = try removed(HoleSpec(diameter: 6, depth: 15, tipAngle: 0, head: .counterbore(diameter: 10, depth: 4)))
        let expected: Double = Double.pi * (25 * 4 + 9 * 11)
        #expect(close(v, expected, rel: 1e-6))
    }

    @Test func countersink() throws {
        let v = try removed(HoleSpec(diameter: 6, depth: 10, tipAngle: 0, head: .countersink(diameter: 12, angle: 90 * Self.deg)))
        // A 3 mm deep frustum from r = 6 to r = 3, then 7 mm of r = 3.
        let expected: Double = Double.pi * (63 + 63)
        #expect(close(v, expected, rel: 1e-6))
    }

    @Test func severalHolesInOneCut() throws {
        let centers = [Vec3(10, 10, 20), Vec3(30, 10, 20), Vec3(20, 30, 20)]
        let v = try removed(HoleSpec(diameter: 4, depth: nil), at: centers)
        #expect(close(v, 3 * .pi * 4 * 20, rel: 1e-6))
    }

    @Test func drillsAlongAnyDirection() throws {
        // Into the +X side face, at (40, 20, 10), going -X.
        let r = try block.drilled(at: [Vec3(40, 20, 10)], direction: -Vec3.unitX, HoleSpec(diameter: 8, depth: 12, tipAngle: 0))
        #expect(close(block.volume - r.volume, .pi * 16 * 12, rel: 1e-6))
        let b = try #require(r.bounds)
        #expect(close(b.max.x, 40, abs: 1e-6))
    }

    @Test func errors() throws {
        expectKernelError("diameter") { _ = try block.drilled(at: [top], direction: down, HoleSpec(diameter: 0, depth: 5)) }
        expectKernelError("at least one") { _ = try block.drilled(at: [], direction: down, HoleSpec(diameter: 5, depth: 5)) }
        expectKernelError("Counterbore depth") {
            _ = try block.drilled(at: [top], direction: down, HoleSpec(diameter: 5, depth: 5, head: .counterbore(diameter: 9, depth: 6)))
        }
        expectKernelError("Counterbore diameter") {
            _ = try block.drilled(at: [top], direction: down, HoleSpec(diameter: 5, depth: 5, head: .counterbore(diameter: 4, depth: 2)))
        }
        expectKernelError("countersink is deeper") {
            _ = try block.drilled(at: [top], direction: down,
                                  HoleSpec(diameter: 5, depth: 2, head: .countersink(diameter: 15, angle: 90 * Self.deg)))
        }
        expectKernelError("miss") { _ = try block.drilled(at: [Vec3(100, 100, 20)], direction: down, HoleSpec(diameter: 5, depth: 5)) }
    }
}
