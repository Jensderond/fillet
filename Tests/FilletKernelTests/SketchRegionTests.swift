import Foundation
import Testing
import simd
@testable import FilletKernel

@Suite("Sketch regions")
struct SketchRegionTests {
    @Test func rectangleIsOneRegion() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10))
        #expect(r.count == 1)
        #expect(close(r.area(0), 200))
    }

    @Test func circleInsideRectangleGivesRectWithHoleAndDisk() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 40, 20) + [.circle(center: p(20, 10), radius: 5)])
        #expect(r.count == 2)
        let areas = sortedAreas(r)
        #expect(close(areas[0], .pi * 25, rel: 1e-5))
        #expect(close(areas[1], 800 - .pi * 25, rel: 1e-5))
        // The disk centre lies in the disk, a point near the corner in the outer region.
        let disk = try #require(r.region(containing: p(20, 10)))
        let outer = try #require(r.region(containing: p(2, 2)))
        #expect(disk != outer)
        #expect(close(r.area(disk), .pi * 25, rel: 1e-5))
        #expect(r.region(containing: p(100, 100)) == nil)
    }

    @Test func concentricCirclesGiveRingAndDisk() throws {
        let r = try SketchRegions(
            plane: .xy, segments: [.circle(center: p(0, 0), radius: 10), .circle(center: p(0, 0), radius: 5)])
        #expect(r.count == 2)
        let areas = sortedAreas(r)
        #expect(close(areas[0], .pi * 25, rel: 1e-5))
        #expect(close(areas[1], .pi * 75, rel: 1e-5))
        // The ring is one face with a hole: its interior point is in the ring, not in the disk.
        let ring = try #require(r.region(containing: p(7.5, 0)))
        let disk = try #require(r.region(containing: p(0, 0)))
        #expect(ring != disk)
        let ip = r.interiorPoint(ring)
        #expect(r.region(containing: ip) == ring)
        #expect(simd_length(ip) > 5 && simd_length(ip) < 10)
        #expect(try r.face(ring).faceCount == 1)
    }

    @Test func overlappingCirclesGiveThreeRegions() throws {
        let rad = 10.0, d = 10.0
        let r = try SketchRegions(
            plane: .xy, segments: [.circle(center: p(0, 0), radius: rad), .circle(center: p(d, 0), radius: rad)])
        #expect(r.count == 3)
        let lens = 2 * rad * rad * acos(d / (2 * rad)) - d / 2 * (4 * rad * rad - d * d).squareRoot()
        let areas = sortedAreas(r)
        #expect(close(areas[0], lens, rel: 1e-5))
        #expect(close(areas[1], .pi * rad * rad - lens, rel: 1e-5))
        #expect(close(areas[2], .pi * rad * rad - lens, rel: 1e-5))
        #expect(close(areas.reduce(0, +), 2 * .pi * rad * rad - lens, rel: 1e-5))
    }

    @Test func lineAcrossRectangleSplitsIt() throws {
        // The line overshoots on both sides; the overhangs are dangling and ignored.
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10) + [.line(p(5, -5), p(5, 15))])
        #expect(r.count == 2)
        let areas = sortedAreas(r)
        #expect(close(areas[0], 50))
        #expect(close(areas[1], 150))
    }

    @Test func openPolylineHasNoRegions() throws {
        let r = try SketchRegions(
            plane: .xy, segments: [.line(p(0, 0), p(10, 0)), .line(p(10, 0), p(10, 10)), .line(p(10, 10), p(0, 10))])
        #expect(r.count == 0)
        #expect(r.region(containing: p(5, 5)) == nil)
    }

    @Test func emptySketchHasNoRegions() throws {
        #expect(try SketchRegions(plane: .xy, segments: []).count == 0)
    }

    @Test func slotIsOneRegion() throws {
        let segments: [Segment2D] = [
            .line(p(0, -5), p(20, -5)),
            .arc(start: p(20, -5), through: p(25, 0), end: p(20, 5)),
            .line(p(20, 5), p(0, 5)),
            .arc(start: p(0, 5), through: p(-5, 0), end: p(0, -5)),
        ]
        let r = try SketchRegions(plane: .xy, segments: segments)
        #expect(r.count == 1)
        #expect(close(r.area(0), 200 + .pi * 25, rel: 1e-6))
    }

    @Test func closedBSplineIsOneRegion() throws {
        var pts = (0..<12).map { i -> SIMD2<Double> in
            let a = Double(i) / 12 * 2 * .pi
            return p(10 * cos(a), 10 * sin(a))
        }
        pts.append(pts[0])
        let r = try SketchRegions(plane: .xy, segments: [.bspline(pts)])
        #expect(r.count == 1)
        #expect(close(r.area(0), .pi * 100, rel: 0.02))
    }

    @Test func openBSplineClosedByLine() throws {
        let r = try SketchRegions(
            plane: .xy, segments: [.bspline([p(0, 0), p(5, 5), p(10, 0)]), .line(p(10, 0), p(0, 0))])
        #expect(r.count == 1)
        #expect(r.area(0) > 10)
    }

    @Test func tangentCirclesTouchingExternally() throws {
        let r = try SketchRegions(
            plane: .xy, segments: [.circle(center: p(0, 0), radius: 5), .circle(center: p(10, 0), radius: 5)])
        #expect(r.count == 2)
        for a in sortedAreas(r) { #expect(close(a, .pi * 25, rel: 1e-5)) }
    }

    @Test func circleTangentToRectangleSides() throws {
        // Circle touches the top and bottom edges: rect minus disk falls apart into two pieces.
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10) + [.circle(center: p(10, 5), radius: 5)])
        #expect(r.count == 3)
        let areas = sortedAreas(r)
        #expect(close(areas.reduce(0, +), 200, rel: 1e-5))
        #expect(close(areas[2], .pi * 25, rel: 1e-5))
        #expect(close(areas[0], (200 - .pi * 25) / 2, rel: 1e-5))
    }

    @Test func rectanglesSharingAnEdge() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10) + rect(10, 0, 20, 10))
        #expect(r.count == 2)
        for a in sortedAreas(r) { #expect(close(a, 100)) }
    }

    @Test func tJunctionAndDanglingLine() throws {
        // A line from the top edge down to the bottom edge (T-junctions at both ends) splits;
        let split = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10) + [.line(p(8, 10), p(8, 0))])
        #expect(split.count == 2)
        #expect(sortedAreas(split).map { $0.rounded() } == [80, 120])
        // a line ending in the middle of the rectangle doesn't.
        let dangling = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10) + [.line(p(8, 10), p(8, 5))])
        #expect(dangling.count == 1)
        #expect(close(dangling.area(0), 200))
    }

    @Test func crossingRectanglesGiveFiveRegions() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 10, 30, 20) + rect(10, 0, 20, 30))
        #expect(r.count == 5)
        for a in sortedAreas(r) { #expect(close(a, 100)) }
    }

    @Test func separateShapesAndNesting() throws {
        // Two disjoint rectangles, one with a nested rectangle with a nested circle.
        let segs = rect(0, 0, 10, 10) + rect(20, 0, 60, 40) + rect(30, 10, 50, 30)
            + [.circle(center: p(40, 20), radius: 5)]
        let r = try SketchRegions(plane: .xy, segments: segs)
        #expect(r.count == 4)
        let areas = sortedAreas(r)
        #expect(close(areas[0], .pi * 25, rel: 1e-5))
        #expect(close(areas[1], 100))
        #expect(close(areas[2], 400 - .pi * 25, rel: 1e-5))
        #expect(close(areas[3], 1600 - 400))
    }

    @Test func regionsOnTiltedPlane() throws {
        let plane = Plane(origin: Vec3(5, 5, 5), normal: Vec3(1, 1, 1), xDir: Vec3(1, -1, 0))
        let r = try SketchRegions(plane: plane, segments: rect(0, 0, 20, 10) + [.circle(center: p(10, 5), radius: 2)])
        #expect(r.count == 2)
        let disk = try #require(r.region(containing: p(10, 5)))
        let face = try r.face(disk)
        let info = face.faceInfo(0)
        #expect(close(info.normal.dot(plane.normal), 1, rel: 1e-9))
        #expect(info.centroid.distance(to: plane.point(u: 10, v: 5)) < 1e-6)
        let ip = r.interiorPoint(disk)
        #expect(simd_distance(ip, p(10, 5)) < 2)
    }

    @Test func interiorPointsAreInsideTheirRegions() throws {
        let segs = rect(0, 0, 40, 20) + [.circle(center: p(20, 10), radius: 5), .line(p(0, 0), p(40, 20))]
        let r = try SketchRegions(plane: .xz, segments: segs)
        #expect(r.count == 4)
        for i in 0..<r.count {
            #expect(r.region(containing: r.interiorPoint(i)) == i)
        }
    }

    @Test func profileFromAdjacentRegionsFusesIntoOneFace() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 20, 10) + [.line(p(5, 0), p(5, 10))])
        #expect(r.count == 2)
        let profile = try r.profile(indices: [0, 1])
        #expect(profile.faceCount == 1)
        #expect(close(profile.surfaceArea, 200))
        #expect(profile.edgeCount == 4)
        let solid = try profile.extruded(along: .unitZ, distance: 5)
        #expect(close(solid.volume, 1000))
        #expect(solid.faceCount == 6)
    }

    @Test func profileFromRingAndDiskIsFullDisk() throws {
        let r = try SketchRegions(
            plane: .xy, segments: [.circle(center: p(0, 0), radius: 10), .circle(center: p(0, 0), radius: 5)])
        let profile = try r.profile(indices: [0, 1])
        #expect(profile.faceCount == 1)
        #expect(close(profile.surfaceArea, .pi * 100, rel: 1e-6))
    }

    @Test func profileFromDisjointRegionsKeepsBoth() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10) + rect(20, 0, 30, 10))
        let profile = try r.profile(indices: [0, 1])
        #expect(profile.faceCount == 2)
        let solid = try profile.extruded(along: .unitZ, distance: 2)
        #expect(solid.solidCount == 2)
        #expect(close(solid.volume, 400))
    }

    @Test func profileErrors() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10))
        expectKernelError("does not exist") { _ = try r.profile(indices: [3]) }
        expectKernelError { _ = try r.profile(indices: []) }
        expectKernelError { _ = try r.face(-1) }
        #expect(r.area(7) == 0)
    }

    @Test func fillTrianglesCoverTheRegion() throws {
        let r = try SketchRegions(plane: .xz, segments: rect(0, 0, 40, 20) + [.circle(center: p(20, 10), radius: 5)])
        for i in 0..<r.count {
            let tris = try r.fillTriangles(i)
            #expect(tris.count % 3 == 0 && !tris.isEmpty)
            var area = 0.0
            for t in stride(from: 0, to: tris.count, by: 3) {
                let a = tris[t], b = tris[t + 1], c = tris[t + 2]
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                #expect(cross >= 0)  // counter-clockwise in sketch coordinates
                area += cross / 2
            }
            #expect(close(area, r.area(i), rel: 0.01))
            #expect(!r.boundary(i).isEmpty)
            #expect(r.outline(i).count == tris.count)
        }
    }

    @Test func degenerateSegmentsAreIgnored() throws {
        let segs: [Segment2D] = rect(0, 0, 10, 10) + [
            .line(p(3, 3), p(3, 3)), .circle(center: p(5, 5), radius: 0), .circle(center: p(5, 5), radius: -2),
            .arc(start: p(1, 1), through: p(2, 2), end: p(1, 1)), .bspline([]), .bspline([p(1, 1)]),
            .line(p(.nan, 0), p(1, 1)),
        ]
        let r = try SketchRegions(plane: .xy, segments: segs)
        #expect(r.count == 1)
        #expect(close(r.area(0), 100))
    }
}
