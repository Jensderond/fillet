import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Face anchors")
struct FaceAnchorTests {
    let sketchID = UUID(), extrudeID = UUID(), faceSketchID = UUID(), pocketID = UUID(), holeID = UUID()

    func close(_ a: Vec3, _ b: Vec3) -> Bool { a.distance(to: b) < 1e-9 }

    @Test func worldFramesMatchTheOriginPlanes() {
        // A face's plane as the kernel gives it: origin at its centroid, x along some edge.
        func frame(_ normal: Vec3, at origin: Vec3) -> Plane {
            FaceAnchor.world.frame(Plane(origin: origin, normal: normal, xDir: Vec3(0.3, 0.5, 0.7)))
        }
        let top = frame(.unitZ, at: Vec3(7, 3, 10))
        #expect(close(top.origin, Vec3(0, 0, 10)) && close(top.xDir, Plane.xy.xDir) && close(top.yDir, Plane.xy.yDir))
        let front = frame(-Vec3.unitY, at: Vec3(7, -5, 3))
        #expect(close(front.origin, Vec3(0, -5, 0)) && close(front.xDir, Plane.xz.xDir) && close(front.yDir, Plane.xz.yDir))
        let right = frame(.unitX, at: Vec3(20, 4, 4))
        #expect(close(right.xDir, Plane.yz.xDir) && close(right.yDir, Plane.yz.yDir))
        // The back and left faces read upright from outside too, and the bottom keeps u = +X.
        let back = frame(.unitY, at: Vec3(1, 20, 2))
        #expect(close(back.xDir, -Vec3.unitX) && close(back.yDir, .unitZ))
        let left = frame(-Vec3.unitX, at: Vec3(0, 1, 2))
        #expect(close(left.xDir, -Vec3.unitY) && close(left.yDir, .unitZ))
        let bottom = frame(-Vec3.unitZ, at: Vec3(3, 3, 0))
        #expect(close(bottom.xDir, .unitX) && close(bottom.yDir, -Vec3.unitY))
        // A slope facing front-up: v runs up the slope, u stays +X.
        let slope = frame(Vec3(0, -1, 1).normalized, at: Vec3(5, 0, 10))
        #expect(close(slope.xDir, .unitX) && close(slope.yDir, Vec3(0, 1, 1).normalized))
        // The centroid frame is the kernel's plane unchanged.
        let kernel = Plane(origin: Vec3(1, 2, 3), normal: .unitZ, xDir: .unitY)
        #expect(FaceAnchor.centroid.frame(kernel) == kernel)
    }

    /// A `width` × 20 × 10 block (corner at the origin), with a Ø6 pocket sketched on its top face at
    /// (`u`, `v`) and a Ø4 hole drilled at (`hu`, `hv`), both laid out by `anchor`.
    func document(anchor: FaceAnchor, top: FaceRef, fallback: Plane, pocket: SIMD2<Double>, hole: SIMD2<Double>) -> Document {
        var doc = blockDocument()
        doc.features += [
            Feature(id: faceSketchID, name: "Sketch 2", .sketch(Sketch(
                plane: .face(top, fallback: fallback, anchor: anchor),
                shapes: [SketchShape(.circle(center: Point2Expr(pocket), diameter: 6))]))),
            Feature(id: pocketID, name: "Pocket", .extrude(Extrude(
                sketch: faceSketchID, regions: [RegionRef(pocket)], distance: -4, operation: .cut))),
            Feature(id: holeID, name: "Hole", .hole(Hole(
                face: top, centers: [Point2Expr(hole)], diameter: 4, depth: 5, tipAngle: 0, anchor: anchor))),
        ]
        return doc
    }

    func blockDocument() -> Document {
        var doc = Document()
        doc.parameters = [Parameter(name: "width", expression: "40")]
        doc.features = [
            Feature(id: sketchID, name: "Sketch 1", .sketch(Sketch(plane: .xy, shapes: [
                SketchShape(.rectangle(anchor: .corner, position: .origin, width: "width", height: 20, angle: 0)),
            ]))),
            Feature(id: extrudeID, name: "Extrude 1", .extrude(Extrude(
                sketch: sketchID, regions: [RegionRef(x: 1, y: 1)], distance: 10))),
        ]
        return doc
    }

    func topFace(_ ev: ModelEvaluator) async throws -> (FaceRef, Plane) {
        let model = await ev.evaluate(blockDocument())
        let body = try #require(model.bodies.first)
        let top = try #require(body.shape.faceInfos.firstIndex { $0.normal.z > 0.99 })
        return (try #require(model.faceRef(body: body.ref, face: top)), try #require(body.shape.facePlane(top)))
    }

    /// Centre of the pocket (Ø6) and the hole (Ø4) walls, in world XY.
    func centres(_ model: EvaluatedModel) throws -> (pocket: SIMD2<Double>, hole: SIMD2<Double>) {
        let walls = try #require(model.bodies.first).shape.faceInfos.filter { $0.surface == .cylinder }
        func centre(diameter: Double) throws -> SIMD2<Double> {
            // Told apart by size (bounding boxes are a little loose); a full wall's centroid is on its axis.
            let w = try #require(walls.first { abs(($0.boundsMax.x - $0.boundsMin.x) - diameter) < 0.5 })
            return SIMD2(w.centroid.x, w.centroid.y)
        }
        return (try centre(diameter: 6), try centre(diameter: 4))
    }

    /// X of the centroid of the `width` × 20 top face with the Ø6 pocket at `pocketX` cut out of it.
    func centroidX(width: Double, pocketX: Double) -> Double {
        let face = width * 20, pocket = Double.pi * 9
        return (face * width / 2 - pocket * pocketX) / (face - pocket)
    }

    func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    @Test func legacyDocumentsEvaluateAsBefore() async throws {
        let ev = ModelEvaluator()
        let (top, fallback) = try await topFace(ev)
        // Written before anchors existed: coordinates from the face centroid (20, 10), u along the long edge.
        let data = try document(anchor: .centroid, top: top, fallback: fallback, pocket: SIMD2(10, 0), hole: SIMD2(-10, 0)).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains(#""anchor" : "centroid""#))
        let legacy = try Document(data: data)
        guard case .sketch(let s) = legacy.feature(faceSketchID)?.kind, case .face(_, _, let anchor) = s.plane,
              case .hole(let h) = legacy.feature(holeID)?.kind
        else { Issue.record("sketch or hole missing"); return }
        #expect(anchor == .centroid && h.anchor == .centroid)

        let model = await ev.evaluate(legacy)
        #expect([faceSketchID, pocketID, holeID].allSatisfy { model.status[$0] == .ok })
        #expect(model.sketches[faceSketchID]?.plane == fallback)
        // The hole measures from the centroid of the top face with the pocket in it, a little left
        // of (20, 10): exactly the drift the world anchor fixes.
        let c = try centres(model)
        #expect(near(c.pocket, SIMD2(30, 10)) && near(c.hole, SIMD2(centroidX(width: 40, pocketX: 30) - 10, 10)))
        // Saving again writes the same file.
        #expect(try legacy.encoded() == data)

        // And they still move with the face's centre, as they always did.
        var wider = legacy
        wider.parameters[0].expression = "60"
        let moved = try centres(await ev.evaluate(wider))
        #expect(near(moved.pocket, SIMD2(40, 10)) && near(moved.hole, SIMD2(centroidX(width: 60, pocketX: 40) - 10, 10)))
    }

    @Test func worldAnchorStaysPutWhenTheFaceWidens() async throws {
        let ev = ModelEvaluator()
        let (top, kernelPlane) = try await topFace(ev)
        let fallback = FaceAnchor.world.frame(kernelPlane)
        let doc = document(anchor: .world, top: top, fallback: fallback, pocket: SIMD2(30, 10), hole: SIMD2(10, 10))
        let data = try doc.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains(#""anchor" : "world""#))
        #expect(try Document(data: data) == doc)

        let model = await ev.evaluate(doc)
        #expect([faceSketchID, pocketID, holeID].allSatisfy { model.status[$0] == .ok })
        let plane = try #require(model.sketches[faceSketchID]?.plane)
        #expect(close(plane.origin, Vec3(0, 0, 10)) && close(plane.xDir, .unitX) && close(plane.yDir, .unitY))
        // The pocket cut into the face doesn't shift the hole either.
        let c = try centres(model)
        #expect(near(c.pocket, SIMD2(30, 10)) && near(c.hole, SIMD2(10, 10)))

        // Wider (and taller): the face's centre moves, the pocket and hole stay over the same spot.
        var wider = doc
        wider.parameters[0].expression = "60"
        if case .extrude(var e) = wider.features[1].kind {
            e.distance = 15
            wider.features[1].kind = .extrude(e)
        }
        let after = await ev.evaluate(wider)
        #expect([faceSketchID, pocketID, holeID].allSatisfy { after.status[$0] == .ok })
        #expect(after.sketches[faceSketchID].map { close($0.plane.origin, Vec3(0, 0, 15)) } == true)
        let moved = try centres(after)
        #expect(near(moved.pocket, SIMD2(30, 10)) && near(moved.hole, SIMD2(10, 10)))
    }
}
