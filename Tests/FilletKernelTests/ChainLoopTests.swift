import Foundation
import Testing
@testable import FilletKernel

/// Tangent chains and face loops: what selecting "the tangent chain" or "the loop" of an edge picks.
@Suite("Tangent chains and loops")
struct ChainLoopTests {
    /// 40 × 20 × 10 box with its four vertical edges rounded (r = 3): its top outline is four
    /// lines and four arcs, all tangent to each other.
    private func roundedPlate() throws -> Shape {
        let box = try Shape.box(corner: .zero, size: Vec3(40, 20, 10))
        let vertical = (0..<box.edgeCount).filter { abs(box.edgeInfo($0).tangentAtMid.z) > 0.99 }
        #expect(vertical.count == 4)
        return try box.filleted(edges: vertical, radius: 3)
    }

    private func isTopEdge(_ e: EdgeInfo) -> Bool {
        abs(e.start.z - 10) < 1e-6 && abs(e.end.z - 10) < 1e-6 && abs(e.mid.z - 10) < 1e-6
    }

    @Test func topOutlineOfARoundedPlateIsOneChain() throws {
        let plate = try roundedPlate()
        let top = (0..<plate.edgeCount).filter { isTopEdge(plate.edgeInfo($0)) }
        #expect(top.count == 8)
        let line = try #require(top.first { plate.edgeInfo($0).curve == .line })
        #expect(plate.tangentChain(from: line) == top)
        let arc = try #require(top.first { plate.edgeInfo($0).curve == .circle })
        #expect(plate.tangentChain(from: arc) == top)
    }

    @Test func chainStopsAtCorners() throws {
        // A plain box: every edge meets the others at 90°, so each is its own chain.
        let box = try Shape.box(corner: .zero, size: Vec3(10, 10, 10))
        for i in 0..<box.edgeCount { #expect(box.tangentChain(from: i) == [i]) }
        // On the rounded plate, the straight edges where a rounding meets a side run up and down,
        // across the outlines: nothing carries on from them.
        let plate = try roundedPlate()
        let side = try #require((0..<plate.edgeCount).first { abs(plate.edgeInfo($0).tangentAtMid.z) > 0.99 })
        #expect(plate.tangentChain(from: side) == [side])
    }

    @Test func chainToleranceIsAnAngle() throws {
        // Two lines meeting at 3° (a very shallow V-shaped plate) chain only with a looser tolerance.
        let bend = 3 * Double.pi / 180
        let segments: [Segment2D] = [
            .line(p(0, 0), p(20, 0)), .line(p(20, 0), p(40, 20 * tan(bend))),
            .line(p(40, 20 * tan(bend)), p(40, 10)), .line(p(40, 10), p(0, 10)), .line(p(0, 10), p(0, 0)),
        ]
        let regions = try SketchRegions(plane: .xy, segments: segments)
        let solid = try regions.profile(indices: [0]).extruded(along: .unitZ, distance: 5)
        let a = try #require(edgeIndex(solid) { $0.curve == .line && abs($0.mid.x - 10) < 1e-6 && abs($0.mid.y) < 1e-6 && abs($0.mid.z) < 1e-6 })
        #expect(solid.tangentChain(from: a).count == 1)
        #expect(solid.tangentChain(from: a, angleTolerance: 5 * .pi / 180).count == 2)
    }

    @Test func faceLoopsOuterThenHoles() throws {
        let plate = try Shape.box(corner: .zero, size: Vec3(30, 30, 5))
            .cut(by: Shape.cylinder(base: Plane(origin: Vec3(15, 15, -1), normal: .unitZ, xDir: .unitX), radius: 4, height: 10))
        let top = try #require(faceIndex(plate) { $0.surface == .plane && abs($0.centroid.z - 5) < 1e-6 })
        let loops = plate.faceLoops(top)
        #expect(loops.count == 2)
        #expect(loops[0].count == 4)
        #expect(loops[0].allSatisfy { plate.edgeInfo($0).curve == .line })
        #expect(!loops[1].isEmpty && loops[1].allSatisfy { plate.edgeInfo($0).curve == .circle })
        // The loop through one outer edge is the whole outer boundary.
        #expect(plate.loop(of: top, through: loops[0][2]) == loops[0])
        #expect(plate.loop(of: top, through: loops[1][0]) == loops[1])
        // An edge of the bottom face isn't on the top face.
        let bottomEdge = try #require(edgeIndex(plate) { $0.curve == .line && abs($0.mid.z) < 1e-6 })
        #expect(plate.loop(of: top, through: bottomEdge) == nil)
    }

    @Test func roundedPlateTopLoopIsItsChain() throws {
        let plate = try roundedPlate()
        let top = try #require(faceIndex(plate) { $0.surface == .plane && abs($0.centroid.z - 10) < 1e-6 })
        let loops = plate.faceLoops(top)
        #expect(loops.count == 1)
        #expect(loops[0] == plate.tangentChain(from: loops[0][0]))
    }

    @Test func edgeFacesAreTheTwoSides() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(10, 10, 10))
        for i in 0..<box.edgeCount {
            let faces = box.edgeFaces(i)
            #expect(faces.count == 2)
            for f in faces { #expect(box.faceLoops(f)[0].contains(i)) }
        }
        #expect(box.edgeFaces(99).isEmpty)
        #expect(box.faceLoops(99).isEmpty)
        #expect(box.tangentChain(from: -1).isEmpty)
    }
}
