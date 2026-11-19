import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

private let size: CGFloat = 84
private let iso = Camera().viewing(.iso)
private let sides: [Camera.StandardView] = [.front, .back, .left, .right, .top, .bottom]

/// Angled cameras from above and below, each showing three faces.
private let angled: [Camera] = [iso, Camera(yaw: -2.2, pitch: -0.4), Camera(yaw: 0.3, pitch: 1.1)]

/// All 26 areas: 6 face centres, 12 edges, 8 corners.
private let allRegions: [Vec3] = {
    var out: [Vec3] = []
    for x in [-1.0, 0, 1] {
        for y in [-1.0, 0, 1] {
            for z in [-1.0, 0, 1] where x != 0 || y != 0 || z != 0 { out.append(Vec3(x, y, z)) }
        }
    }
    return out
}()

/// The canvas point at face coordinates (u, v) on `face`.
private func point(_ face: ViewCube.Face, _ u: Double, _ v: Double, _ camera: Camera) -> CGPoint {
    ViewCube.project(face.normal + face.axisU * u + face.axisV * v, camera: camera, size: size)
}

private func region(_ p: CGPoint, _ camera: Camera, arrows: Bool = true) -> Vec3? {
    ViewCube.region(at: p, camera: camera, size: size, showsArrows: arrows)
}

@MainActor
@Suite("View cube")
struct ViewCubeTests {
    @Test(arguments: sides)
    func centreOfSquareFacePicksIt(view: Camera.StandardView) throws {
        let camera = Camera().viewing(view)
        let face = try #require(ViewCube.faces.first { $0.view == view })
        #expect(ViewCube.squareFace(camera)?.view == view)
        #expect(region(CGPoint(x: size / 2, y: size / 2), camera) == face.normal)
    }

    @Test(arguments: angled)
    func angledCentresEdgesAndCorners(camera: Camera) throws {
        let visible = ViewCube.visibleFaces(camera)
        #expect(visible.count == 3)
        for face in visible {
            #expect(region(point(face, 0, 0, camera), camera) == face.normal)
            for s in [-1.0, 1.0] {
                #expect(region(point(face, 0.8 * s, 0, camera), camera) == face.normal + face.axisU * s)
                #expect(region(point(face, 0, 0.8 * s, camera), camera) == face.normal + face.axisV * s)
                for t in [-1.0, 1.0] {
                    let corner = try #require(region(point(face, 0.9 * s, 0.9 * t, camera), camera))
                    #expect(corner == face.normal + face.axisU * s + face.axisV * t)
                    #expect([corner.x, corner.y, corner.z].allSatisfy { abs($0) == 1 })
                }
            }
        }
        #expect(region(CGPoint(x: 1, y: 1), camera) == nil)
        #expect(region(CGPoint(x: -40, y: size + 40), camera) == nil)
    }

    @Test func edgeOnFaceHasNoArea() throws {
        let front = Camera().viewing(.front)
        let right = try #require(ViewCube.faces.first { $0.view == .right })
        let hit = ViewCube.faceCoordinates(of: CGPoint(x: size / 2, y: size / 2), on: right, camera: front, size: size) != nil
        #expect(!hit)
    }

    @Test(arguments: allRegions)
    func regionTouchesOneFacePerAxis(region d: Vec3) {
        let patches = ViewCube.faces.compactMap { ViewCube.patch(d, on: $0) }
        // A centre lies on one face, an edge on two, a corner on three.
        #expect(patches.count == [d.x, d.y, d.z].filter { $0 != 0 }.count)
        for patch in patches {
            #expect(patch.count == 4)
            if patches.count == 3 { #expect(patch.contains(d)) }
        }
    }

    @Test(arguments: angled)
    func everyVisiblePatchHitsItsRegion(camera: Camera) {
        for d in allRegions {
            for face in ViewCube.visibleFaces(camera) {
                guard let patch = ViewCube.patch(d, on: face) else { continue }
                let mid = patch.reduce(Vec3.zero, +) / 4
                #expect(region(ViewCube.project(mid, camera: camera, size: size), camera) == d)
            }
        }
    }

    @Test func frontArrowsTurnToTheNeighbouringSides() {
        let front = Camera().viewing(.front)
        func arrow(_ v: Vec3) -> CGPoint { ViewCube.project(v * 1.25, camera: front, size: size) }
        #expect(region(arrow(front.right), front) == Vec3.unitX)
        #expect(region(arrow(-front.right), front) == -Vec3.unitX)
        #expect(region(arrow(front.up), front) == Vec3.unitZ)
        #expect(region(arrow(-front.up), front) == -Vec3.unitZ)
        for v in [front.right, -front.right, front.up, -front.up] {
            #expect(region(arrow(v), front, arrows: false) == nil)
        }
    }

    @Test(arguments: sides)
    func arrowsSitBesideTheSquare(view: Camera.StandardView) {
        let camera = Camera().viewing(view)
        for side in [size, 110] {
            let arrows = ViewCube.arrows(camera: camera, size: side)
            #expect(arrows.count == 4)
            for (arrow, screen) in zip(arrows, [-camera.right, camera.right, camera.up, -camera.up]) {
                #expect(arrow.direction.dot(screen) > 0.99)
                for p in arrow.triangle {
                    // Inside the frame, outside the square (0.3 × size from the centre).
                    #expect(p.x >= 0 && p.x <= side && p.y >= 0 && p.y <= side)
                    #expect(max(abs(p.x - side / 2), abs(p.y - side / 2)) > side * 0.3)
                }
                let mid = ViewCube.project(screen * 1.25, camera: camera, size: side)
                #expect(arrow.hitArea.contains(mid))
                #expect(ViewCube.region(at: mid, camera: camera, size: side, showsArrows: true) == arrow.direction)
            }
        }
    }

    @Test(arguments: angled)
    func noArrowsWhenAngled(camera: Camera) {
        #expect(ViewCube.arrows(camera: camera, size: size).isEmpty)
    }
}
