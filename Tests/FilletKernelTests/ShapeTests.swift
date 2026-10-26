import Foundation
import Testing
import simd
import Synchronization
@testable import FilletKernel

@Suite("Primitives")
struct PrimitiveTests {
    @Test func box() throws {
        let b = try Shape.box(corner: Vec3(1, 2, 3), size: Vec3(10, 20, 30))
        #expect(close(b.volume, 6000))
        #expect(close(b.surfaceArea, 2 * (200 + 300 + 600)))
        #expect(b.isValid)
        #expect(b.solidCount == 1)
        let bounds = try #require(b.bounds)
        #expect(bounds.min.distance(to: Vec3(1, 2, 3)) < 1e-6)
        #expect(bounds.max.distance(to: Vec3(11, 22, 33)) < 1e-6)
    }

    @Test func boxWithNegativeSizeExtendsBackwards() throws {
        let b = try Shape.box(corner: .zero, size: Vec3(-10, 5, 5))
        #expect(close(b.volume, 250))
        #expect(close(try #require(b.bounds).min.x, -10, abs: 1e-6))
    }

    @Test func cylinder() throws {
        let base = Plane(origin: Vec3(5, 0, 0), normal: .unitX, xDir: .unitY)
        let c = try Shape.cylinder(base: base, radius: 3, height: 10)
        #expect(close(c.volume, .pi * 9 * 10, rel: 1e-9))
        #expect(close(c.surfaceArea, 2 * .pi * 9 + 2 * .pi * 3 * 10, rel: 1e-9))
        let b = try #require(c.bounds)
        #expect(close(b.min.x, 5, abs: 1e-6) && close(b.max.x, 15, abs: 1e-6))
    }

    @Test func sphereConeTorus() throws {
        let s = try Shape.sphere(center: Vec3(1, 1, 1), radius: 4)
        #expect(close(s.volume, 4.0 / 3.0 * .pi * 64, rel: 1e-6))
        let cone = try Shape.cone(base: .xy, radius1: 5, radius2: 2, height: 6)
        #expect(close(cone.volume, .pi * 6 / 3 * (25 + 10 + 4), rel: 1e-6))
        let point = try Shape.cone(base: .xy, radius1: 5, radius2: 0, height: 6)
        #expect(close(point.volume, .pi * 25 * 6 / 3, rel: 1e-6))
        let t = try Shape.torus(base: .xy, majorRadius: 10, minorRadius: 2)
        #expect(close(t.volume, 2 * .pi * .pi * 10 * 4, rel: 1e-6))
        for shape in [s, cone, point, t] { #expect(shape.isValid) }
    }

    @Test func primitiveErrors() {
        expectKernelError("non-zero") { _ = try Shape.box(corner: .zero, size: Vec3(10, 10, 0)) }
        expectKernelError { _ = try Shape.box(corner: .zero, size: Vec3(.nan, 1, 1)) }
        expectKernelError("radius") { _ = try Shape.cylinder(base: .xy, radius: 0, height: 5) }
        expectKernelError("height") { _ = try Shape.cylinder(base: .xy, radius: 2, height: 0) }
        expectKernelError { _ = try Shape.cylinder(base: Plane(origin: .zero, normal: .zero, xDir: .unitX), radius: 2, height: 5) }
        expectKernelError { _ = try Shape.sphere(center: .zero, radius: -1) }
        expectKernelError { _ = try Shape.cone(base: .xy, radius1: 0, radius2: 0, height: 5) }
        expectKernelError { _ = try Shape.torus(base: .xy, majorRadius: 2, minorRadius: 3) }
    }

    @Test func compoundAndSolids() throws {
        let a = try cube(10)
        let b = try cube(5, at: Vec3(20, 0, 0))
        let c = try Shape.compound([a, b])
        #expect(c.solidCount == 2)
        #expect(close(c.volume, 1125))
        let solids = c.solids()
        #expect(solids.count == 2)
        #expect(Set(solids.map { $0.volume.rounded() }) == [1000, 125])
        #expect(try Shape.compound([]).solidCount == 0)
        #expect(close(try a.copy().volume, 1000))
    }
}

@Suite("Features")
struct FeatureTests {
    @Test func extrudeRectangleWithCircularHole() throws {
        let r = try SketchRegions(plane: .xy, segments: rect(0, 0, 40, 20) + [.circle(center: p(20, 10), radius: 5)])
        let outer = try #require(r.region(containing: p(2, 2)))
        let solid = try r.profile(indices: [outer]).extruded(along: .unitZ, distance: 5)
        #expect(close(solid.volume, (800 - .pi * 25) * 5, rel: 1e-6))
        #expect(solid.isValid)
        #expect(solid.faceCount == 7)  // 4 sides, top, bottom, hole
        #expect(faceIndex(solid) { $0.surface == .cylinder } != nil)
    }

    @Test func extrudeTwoSidedAndNegative() throws {
        let face = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10)).profile(indices: [0])
        let both = try face.extruded(along: .unitZ, distance: 5, back: 3)
        #expect(close(both.volume, 800))
        let b = try #require(both.bounds)
        #expect(close(b.min.z, -3, abs: 1e-6) && close(b.max.z, 5, abs: 1e-6))
        let down = try face.extruded(along: .unitZ, distance: -4)
        #expect(close(down.volume, 400))
        #expect(close(try #require(down.bounds).min.z, -4, abs: 1e-6))
        // Direction not along the normal: oblique prism keeps base area × height.
        let oblique = try face.extruded(along: Vec3(1, 0, 1), distance: 2.0.squareRoot() * 5)
        #expect(close(oblique.volume, 500, rel: 1e-6))
    }

    @Test func extrudeWithTaperNarrows() throws {
        let face = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10)).profile(indices: [0])
        let h = 5.0, t = 5.0 * .pi / 180
        let tapered = try face.extruded(along: .unitZ, distance: h, taper: t)
        let a1 = 100.0, side2 = 10 - 2 * h * tan(t), a2 = side2 * side2
        #expect(close(tapered.volume, h / 3 * (a1 + a2 + (a1 * a2).squareRoot()), rel: 1e-4))
        #expect(tapered.isValid)
        let b = try #require(tapered.bounds)
        #expect(close(b.max.z, h, abs: 1e-6))
        // Negative taper widens (convex corners get rounded by the evolved sweep, hence the tolerance).
        let widened = try face.extruded(along: .unitZ, distance: h, taper: -t)
        let side3 = 10 + 2 * h * tan(t), a3 = side3 * side3
        #expect(close(widened.volume, h / 3 * (a1 + a3 + (a1 * a3).squareRoot()), rel: 2e-3))
        #expect(close(try #require(widened.bounds).max.x, 10 + h * tan(t), abs: 1e-6))
        // Extruding against the face normal tapers the same way.
        let down = try face.extruded(along: -Vec3.unitZ, distance: h, taper: t)
        #expect(close(down.volume, tapered.volume, rel: 1e-6))
        #expect(close(try #require(down.bounds).min.z, -h, abs: 1e-6))
        // Two-sided: the sketch plane is the neutral plane (narrow on top, wide at the back).
        let twoSided = try face.extruded(along: .unitZ, distance: h, back: 2, taper: t)
        let tb = try #require(twoSided.bounds)
        #expect(close(tb.min.z, -2, abs: 1e-6) && close(tb.max.z, h, abs: 1e-6))
        #expect(close(tb.min.x, -2 * tan(t), abs: 1e-6))
        #expect(twoSided.isValid)
        // Offset start (range 2...5): the profile size is kept at the near end.
        let offset = try face.extruded(along: .unitZ, distance: h, back: -2, taper: t)
        let ob = try #require(offset.bounds)
        #expect(close(ob.min.z, 2, abs: 1e-6) && close(ob.max.z, h, abs: 1e-6))
        #expect(close(ob.min.x, 0, abs: 1e-6) && close(ob.max.x, 10, abs: 1e-6))
    }

    @Test func revolveRectangleIntoCylinderAndTube() throws {
        // Front plane: u = X, v = Z. Revolve around the Z axis.
        let cyl = try SketchRegions(plane: .xz, segments: rect(0, 0, 5, 10)).profile(indices: [0])
            .revolved(axisOrigin: .zero, axisDir: .unitZ)
        #expect(close(cyl.volume, .pi * 25 * 10, rel: 1e-6))
        #expect(cyl.isValid)
        let tubeProfile = try SketchRegions(plane: .xz, segments: rect(3, 0, 5, 10)).profile(indices: [0])
        let tube = try tubeProfile.revolved(axisOrigin: .zero, axisDir: .unitZ)
        #expect(close(tube.volume, .pi * (25 - 9) * 10, rel: 1e-6))
        let half = try tubeProfile.revolved(axisOrigin: .zero, axisDir: .unitZ, angle: .pi)
        #expect(close(half.volume, .pi * (25 - 9) * 10 / 2, rel: 1e-6))
        #expect(half.isValid)
    }

    @Test func revolveErrors() throws {
        let profile = try SketchRegions(plane: .xz, segments: rect(-2, 0, 5, 10)).profile(indices: [0])
        expectKernelError { _ = try profile.revolved(axisOrigin: .zero, axisDir: .unitZ) }
        expectKernelError { _ = try profile.revolved(axisOrigin: .zero, axisDir: .zero) }
        expectKernelError { _ = try profile.revolved(axisOrigin: Vec3(10, 0, 0), axisDir: .unitZ, angle: 0) }
    }

    @Test func booleans() throws {
        let a = try cube(10)
        let b = try cube(10, at: Vec3(5, 5, 5))
        #expect(close(try a.fused(with: b).volume, 2000 - 125, rel: 1e-9))
        #expect(close(try a.cut(by: b).volume, 1000 - 125, rel: 1e-9))
        #expect(close(try a.common(with: b).volume, 125, rel: 1e-9))
        let hole = try Shape.cylinder(base: Plane(origin: Vec3(5, 5, -1), normal: .unitZ, xDir: .unitX), radius: 2, height: 12)
        let drilled = try a.cut(by: hole)
        #expect(close(drilled.volume, 1000 - .pi * 4 * 10, rel: 1e-6))
        #expect(drilled.faceCount == 7)
        // Inputs are untouched.
        #expect(close(a.volume, 1000) && a.faceCount == 6)
    }

    @Test func booleansWithSeveralTools() throws {
        let a = try cube(10)
        let b = try cube(10, at: Vec3(5, 5, 5))
        let c = try cube(10, at: Vec3(-5, -5, -5))
        // b and c overlap a in opposite corners (125 each) and touch each other at a's centre.
        #expect(close(try a.boolean(.fuse, [b, c]).volume, 3000 - 250, rel: 1e-9))
        #expect(close(try a.boolean(.cut, [b, c]).volume, 1000 - 250, rel: 1e-9))
        let cut = try a.boolean(.cut, [b, c])
        let chained = try a.cut(by: b).cut(by: c)
        #expect(cut.faceCount == chained.faceCount && cut.edgeCount == chained.edgeCount)
        // Common keeps what is inside every tool, like chaining.
        let d = try cube(10, at: Vec3(2, 0, 0))
        #expect(close(try a.boolean(.common, [b, d]).volume, 125, rel: 1e-9))
        expectKernelError("overlap") { _ = try a.boolean(.common, [b, c]) }
        expectKernelError("nothing is left") { _ = try a.boolean(.cut, [b, try cube(30, at: Vec3(-10, -10, -10))]) }
    }

    @Test func cutInsideLeavesACavity() throws {
        // The cut's result has a hole shell, which OCCT tells from an outer one by classifying a
        // point at infinity (the face intersectors behind that are built in parallel).
        let block = try cube(20)
        let squash = Transform(matrix: [1.5, 0, 0, -5, 0, 1, 0, 10, 0, 0, 0.8, 2])  // B-spline faces
        let blob = try Shape.sphere(center: Vec3(10, 0, 10), radius: 4).transformed(squash)
        let hollow = try block.cut(by: blob)
        #expect(hollow.solidCount == 1 && hollow.isValid)
        #expect(close(hollow.volume, 8000 - blob.volume, rel: 1e-6), "\(hollow.volume) vs \(8000 - blob.volume)")
        #expect(close(blob.volume, 4.0 / 3.0 * .pi * 64 * 1.5 * 0.8, rel: 1e-3), "\(blob.volume)")
        #expect(close(hollow.surfaceArea, 2400 + blob.surfaceArea, rel: 1e-6))
        // Filling it again, from several threads at once, gives the block back each time.
        let filled = try (0..<8).map { _ in try hollow.copy() }
        let volumes = Mutex<[Double]>([])
        DispatchQueue.concurrentPerform(iterations: filled.count) { i in
            if let v = try? filled[i].fused(with: blob).volume { volumes.withLock { $0.append(v) } }
        }
        #expect(volumes.withLock { $0 }.count == filled.count)
        #expect(volumes.withLock { $0 }.allSatisfy { close($0, 8000, rel: 1e-6) })
    }

    @Test func insideOutSolidsAreTurnedRightWayOut() throws {
        // The last line of a BRep string is the root shape ("+<index> 0"); "-" reverses it.
        var lines = try cube(10).brepString().split(separator: "\n", omittingEmptySubsequences: false)
        let root = try #require(lines.lastIndex { $0.hasPrefix("+") })
        lines[root] = "-" + lines[root].dropFirst()
        let insideOut = try Shape.fromBRep(lines.joined(separator: "\n"))
        #expect(close(insideOut.volume, -1000))
        // Every modelling result goes through the kernel's clean-up, which reverses it.
        #expect(close(try insideOut.translated(by: Vec3(1, 0, 0)).volume, 1000))
        #expect(close(try insideOut.transformed(Transform(matrix: [2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])).volume, 2000))
    }

    @Test func fuseMergesCoplanarFaces() throws {
        let a = try cube(10)
        let b = try cube(10, at: Vec3(10, 0, 0))
        let u = try a.fused(with: b)
        #expect(close(u.volume, 2000))
        #expect(u.faceCount == 6)
        #expect(u.edgeCount == 12)
        #expect(u.solidCount == 1)
    }

    @Test func booleanErrors() throws {
        let a = try cube(10)
        let far = try cube(10, at: Vec3(100, 0, 0))
        expectKernelError("overlap") { _ = try a.common(with: far) }
        let big = try cube(30, at: Vec3(-10, -10, -10))
        expectKernelError("nothing is left") { _ = try a.cut(by: big) }
    }

    @Test func filletBoxEdge() throws {
        let box = try cube(10)
        let e = try #require(edgeIndex(box) { $0.curve == .line })
        let r = 2.0
        let f = try box.filleted(edges: [e], radius: r)
        #expect(close(f.volume, 1000 - (1 - .pi / 4) * r * r * 10, rel: 1e-6))
        #expect(f.isValid)
        #expect(f.faceCount == 7)
        #expect(faceIndex(f) { $0.surface == .cylinder } != nil)
    }

    @Test func filletAllEdges() throws {
        let box = try cube(10)
        let f = try box.filleted(edges: Array(0..<box.edgeCount), radius: 1)
        #expect(f.isValid)
        #expect(f.faceCount == 26)
        #expect(f.volume < 1000 && f.volume > 950)
    }

    @Test func chamferBoxEdge() throws {
        let box = try cube(10)
        let e = try #require(edgeIndex(box) { $0.curve == .line })
        let d = 2.0
        let c = try box.chamfered(edges: [e], distance: d)
        #expect(close(c.volume, 1000 - d * d / 2 * 10, rel: 1e-6))
        #expect(c.isValid)
        #expect(c.faceCount == 7)
    }

    @Test func filletErrors() throws {
        let box = try cube(10)
        let e = try #require(edgeIndex(box) { $0.curve == .line })
        expectKernelError("too large") { _ = try box.filleted(edges: [e], radius: 20) }
        expectKernelError("does not exist") { _ = try box.filleted(edges: [999], radius: 1) }
        expectKernelError("does not exist") { _ = try box.filleted(edges: [-1], radius: 1) }
        expectKernelError { _ = try box.filleted(edges: [], radius: 1) }
        expectKernelError("greater than zero") { _ = try box.filleted(edges: [e], radius: 0) }
        expectKernelError("too large") { _ = try box.chamfered(edges: [e], distance: 20) }
        let cyl = try Shape.cylinder(base: .xy, radius: 5, height: 10)
        let seam = try #require(edgeIndex(cyl) { $0.curve == .line })
        expectKernelError("seam") { _ = try cyl.filleted(edges: [seam], radius: 1) }
    }

    @Test func shellBoxWithTopRemoved() throws {
        let box = try cube(10)
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        let s = try box.shelled(removing: [top], thickness: 1)
        #expect(close(s.volume, 1000 - 8 * 8 * 9, rel: 1e-6))
        #expect(s.isValid)
        let b = try #require(s.bounds)
        #expect(close(b.max.x - b.min.x, 10, abs: 1e-6))
    }

    @Test func closedHollowShell() throws {
        let s = try cube(10).shelled(removing: [], thickness: 1)
        #expect(close(s.volume, 1000 - 512, rel: 1e-6))
        #expect(s.isValid)
    }

    @Test func shellErrors() throws {
        let box = try cube(10)
        expectKernelError { _ = try box.shelled(removing: [0], thickness: 0) }
        expectKernelError("does not exist") { _ = try box.shelled(removing: [42], thickness: 1) }
        expectKernelError { _ = try box.shelled(removing: [0], thickness: 6) }
    }

    @Test func mirror() throws {
        let box = try cube(10, at: Vec3(1, 0, 0))
        let m = try box.mirrored(across: .yz)
        #expect(close(m.volume, 1000))
        let b = try #require(m.bounds)
        #expect(close(b.min.x, -11, abs: 1e-6) && close(b.max.x, -1, abs: 1e-6))
        #expect(m.isValid)
        // Faces still point outwards.
        for i in 0..<m.faceCount {
            let info = m.faceInfo(i)
            #expect(info.normal.dot(info.centroid - Vec3(-6, 5, 5)) > 0)
        }
    }

    @Test func transform() throws {
        let box = try cube(10)
        let moved = try box.transformed(.rotation(axis: .unitZ, angle: .pi / 4).concatenating(.translation(Vec3(1, 2, 3))))
        #expect(close(moved.volume, 1000, rel: 1e-9))
        let t = try box.translated(by: Vec3(5, 0, 0))
        #expect(close(try #require(t.bounds).min.x, 5, abs: 1e-6))
        let scaled = try box.transformed(Transform(matrix: [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0]))
        #expect(close(scaled.volume, 8000, rel: 1e-9))
        let stretched = try box.transformed(Transform(matrix: [2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]))
        #expect(close(stretched.volume, 2000, rel: 1e-6))
        let flipped = try box.transformed(Transform(matrix: [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]))
        #expect(close(flipped.volume, 1000, rel: 1e-9))
        expectKernelError("degenerate") {
            _ = try box.transformed(Transform(matrix: [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]))
        }
    }

    @Test func extrudeErrors() throws {
        let empty = try Shape.compound([])
        expectKernelError("empty") { _ = try empty.extruded(along: .unitZ, distance: 5) }
        let face = try SketchRegions(plane: .xy, segments: rect(0, 0, 10, 10)).profile(indices: [0])
        expectKernelError("non-zero") { _ = try face.extruded(along: .unitZ, distance: 0) }
        expectKernelError { _ = try face.extruded(along: .zero, distance: 5) }
        expectKernelError { _ = try face.extruded(along: .unitZ, distance: .infinity) }
        expectKernelError("perpendicular") { _ = try face.extruded(along: Vec3(1, 0, 1), distance: 5, taper: 0.1) }
        let wire = try cube(10).edge(0)
        expectKernelError("empty") { _ = try wire.extruded(along: .unitZ, distance: 5) }
        expectKernelError("not a body") { _ = try cube(10).extruded(along: .unitZ, distance: 5) }
        expectKernelError("not a body") { _ = try cube(10).revolved(axisOrigin: Vec3(-5, 0, 0), axisDir: .unitY) }
        // A face of a body is a valid profile.
        let box = try cube(10)
        let top = try #require(faceIndex(box) { $0.normal.z > 0.99 })
        let raised = try box.face(top).extruded(along: .unitZ, distance: 2)
        #expect(close(raised.volume, 200))
    }
}
