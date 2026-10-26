import Foundation
import Testing
@testable import FilletKernel

@Suite("Press Pull")
struct PressPullTests {
    private func top(_ s: Shape) throws -> Int { try #require(faceIndex(s) { $0.normal.z > 0.99 && $0.surface == .plane }) }

    @Test func pullsAndPushesATopFace() throws {
        let box = try cube(10)
        let up = try box.offsettingFaces([try top(box)], by: 5)
        #expect(close(up.volume, 1500, rel: 1e-6))
        #expect(close(try #require(up.bounds).max.z, 15, abs: 1e-6))
        #expect(up.isValid && up.solidCount == 1)
        #expect(up.faceCount == 6)
        let down = try box.offsettingFaces([try top(box)], by: -3)
        #expect(close(down.volume, 700, rel: 1e-6))
        #expect(close(try #require(down.bounds).max.z, 7, abs: 1e-6))
    }

    /// Two neighbouring faces pulled together meet: the corner between them is filled
    /// (a box 12 × 10 × 12), not left as a notch.
    @Test func neighbouringFacesMeet() throws {
        let box = try cube(10)
        let side = try #require(faceIndex(box) { $0.normal.x > 0.99 })
        let s = try box.offsettingFaces([try top(box), side], by: 2)
        #expect(close(s.volume, 12 * 10 * 12, rel: 1e-6))
        #expect(s.isValid && s.solidCount == 1)
    }

    /// A sloped neighbour (a chamfer) stretches along with the pulled face, like Fusion's
    /// offset face, rather than the face being extruded straight up.
    @Test func slopedNeighbourFollows() throws {
        let box = try cube(10)
        let edge = try #require(edgeIndex(box) { close($0.start.z, 10) && close($0.end.z, 10) && close($0.mid.y, 10) })
        let chamfered = try box.chamfered(edges: [edge], distance: 2)
        #expect(close(chamfered.volume, 980, rel: 1e-6))
        let s = try chamfered.offsettingFaces([try top(chamfered)], by: 3)
        // Cross-section (y, z): the chamfer plane y + z = 18 cuts a 5 × 5 corner off the 10 × 13 block.
        #expect(close(s.volume, (130 - 12.5) * 10, rel: 1e-6))
        #expect(s.isValid)
    }

    @Test func cylindricalFaces() throws {
        let cyl = try Shape.cylinder(base: .xy, radius: 5, height: 10)
        let side = try #require(faceIndex(cyl) { $0.surface == .cylinder })
        let fat = try cyl.offsettingFaces([side], by: 1)
        #expect(close(fat.volume, .pi * 36 * 10, rel: 1e-6))
        // A hole: its outward normal points into the hole, so pulling it narrows the hole.
        let block = try Shape.box(corner: Vec3(-10, -10, 0), size: Vec3(20, 20, 10))
        let holed = try block.cut(by: Shape.cylinder(base: .xy, radius: 4, height: 10))
        let hole = try #require(faceIndex(holed) { $0.surface == .cylinder })
        let narrower = try holed.offsettingFaces([hole], by: 1)
        #expect(close(narrower.volume, 4000 - .pi * 9 * 10, rel: 1e-6))
        let wider = try holed.offsettingFaces([hole], by: -1)
        #expect(close(wider.volume, 4000 - .pi * 25 * 10, rel: 1e-6))
    }

    /// A pocket's floor moves within the body; an L's step face rises past the other top face.
    @Test func innerFaces() throws {
        let block = try cube(10)
        let pocketed = try block.cut(by: Shape.box(corner: Vec3(3, 3, 5), size: Vec3(4, 4, 5)))
        let floor = try #require(faceIndex(pocketed) { $0.normal.z > 0.99 && close($0.centroid.z, 5) })
        #expect(close(try pocketed.offsettingFaces([floor], by: 2).volume, 1000 - 16 * 3, rel: 1e-6))
        #expect(close(try pocketed.offsettingFaces([floor], by: -2).volume, 1000 - 16 * 7, rel: 1e-6))
        let flush = try pocketed.offsettingFaces([floor], by: 5)
        #expect(close(flush.volume, 1000, rel: 1e-6))
        let l = try block.cut(by: Shape.box(corner: Vec3(5, 0, 5), size: Vec3(5, 10, 5)))
        let step = try #require(faceIndex(l) { $0.normal.z > 0.99 && close($0.centroid.z, 5) })
        let raised = try l.offsettingFaces([step], by: 8)
        #expect(close(raised.volume, 500 + 5 * 10 * 13, rel: 1e-6))
        #expect(raised.isValid && raised.solidCount == 1)
    }

    @Test func errors() throws {
        let box = try cube(10)
        let t = try top(box)
        expectKernelError("non-zero") { _ = try box.offsettingFaces([t], by: 0) }
        expectKernelError("at least one face") { _ = try box.offsettingFaces([], by: 1) }
        expectKernelError("does not exist") { _ = try box.offsettingFaces([42], by: 1) }
        expectKernelError("every face") { _ = try box.offsettingFaces(Array(0..<6), by: 1) }
        expectKernelError("pushed this far") { _ = try box.offsettingFaces([t], by: -10) }
        expectKernelError("pushed this far") { _ = try box.offsettingFaces([t], by: -12) }
        let two = try Shape.compound([box, cube(5, at: Vec3(20, 0, 0))])
        expectKernelError("exactly one solid") { _ = try two.offsettingFaces([0], by: 1) }
    }
}
