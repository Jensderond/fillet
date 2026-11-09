import FilletKernel
import Foundation
import Testing
import simd

@testable import FilletCore

/// Coarser than export so the debug-build tests stay quick; same algorithm.
private let testQuality = TextureQuality(edgeScale: 2.5, maxTriangles: 150_000)

@Suite("Texture feature coding")
struct TextureCodingTests {
    @Test func encodesPatternIdAndValueDictionary() throws {
        let b = BodyRef(UUID())
        let texture = Texture(body: b, faces: [], pattern: .dots, values: ["diameter": "d", "raised": 0])
        var doc = Document()
        doc.features = [Feature(name: "Dots", .texture(texture))]
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        #expect(json.contains(#""type" : "texture""#))
        #expect(json.contains(#""pattern" : "dots""#))
        #expect(json.contains(#""diameter" : "d""#))
        let back = try Document(data: try doc.encoded())
        #expect(back.features[0].kind == .texture(texture))
    }

    @Test func missingFieldsTakeDefaults() throws {
        let b = UUID()
        let json = #"{"id": "\#(UUID().uuidString)", "kind": {"type": "texture", "body": "\#(b.uuidString)", "pattern": "knit"}}"#
        let f = try JSONDecoder().decode(Feature.self, from: Data(json.utf8))
        guard case .texture(let t) = f.kind else { Issue.record("expected a texture"); return }
        #expect(t.faces.isEmpty && t.values.isEmpty && t.pattern == .knit)
        #expect(t.value("depth") == Expr(KnitPattern.parameters.first { $0.id == "depth" }!.defaultValue))
        #expect(f.name == "texture")
    }

    /// A pattern from a newer version is kept as written, with its values.
    @Test func unknownPatternRoundTripsAndFailsCleanly() async throws {
        var doc = Document()
        let box = UUID(), tex = UUID()
        doc.features = [
            Feature(id: box, name: "Box", .primitive(Primitive(kind: .box, dimensions: [10, 10, 10]))),
            Feature(id: tex, name: "Future", .texture(Texture(body: BodyRef(box), pattern: "voronoi", values: ["cells": 12]))),
        ]
        let back = try Document(data: try doc.encoded())
        #expect(back == doc)
        let model = await ModelEvaluator().evaluate(back)
        #expect(model.error(for: tex)?.contains("newer version") == true)
        #expect(model.bodies.first?.textures.isEmpty == true)
    }

    @Test func outOfRangeValueIsReported() async throws {
        var doc = Document()
        let box = UUID(), tex = UUID()
        doc.features = [
            Feature(id: box, name: "Box", .primitive(Primitive(kind: .box, dimensions: [10, 10, 10]))),
            Feature(id: tex, name: "Dots", .texture(Texture(body: BodyRef(box), pattern: .dots, values: ["height": 99]))),
        ]
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.error(for: tex)?.contains("Height must be between") == true)
    }
}

@Suite("Texture catalogue")
struct TextureCatalogTests {
    @Test func patternsDeclareConsistentParameters() {
        var ids = Set<TexturePatternID>()
        for p in TextureCatalog.patterns {
            #expect(ids.insert(p.id).inserted, "duplicate pattern id \(p.id)")
            #expect(!p.displayName.isEmpty && !p.summary.isEmpty && !p.symbol.isEmpty)
            let params = TextureCatalog.parameters(for: p.id)
            #expect(Set(params.map(\.id)).count == params.count, "\(p.id) repeats a parameter id")
            for q in params { #expect(q.range.contains(q.defaultValue), "\(p.id).\(q.id) default outside its range") }
            let pattern = TextureCatalog.make(p.id, TextureValues())!
            #expect(pattern.cell.x > 0 && pattern.cell.y > 0 && pattern.detail > 0 && pattern.amplitude > 0)
            // Heights stay within the declared amplitude and repeat every cell.
            for i in 0..<200 {
                let uv = SIMD2(Double(i) * 0.37, Double(i) * 0.53)
                let h = pattern.height(at: uv)
                #expect(abs(h) <= pattern.amplitude + 1e-9)
                #expect(abs(h - pattern.height(at: uv + pattern.cell)) < 1e-6, "\(p.id) is not periodic over its cell")
            }
            #expect(TextureCatalog.swatch(p.id, size: 8).count == 64)
        }
        #expect(TextureCatalog.pattern(.knit) != nil && TextureCatalog.pattern(.dots) != nil)
    }
}

@Suite("Texture engine")
struct TextureEngineTests {
    func evaluate(_ o: TextureSamples.Options) async throws -> (Document, EvaluatedModel, EvaluatedBody) {
        let doc = try await TextureSamples.document(o)
        let model = await ModelEvaluator().evaluate(doc)
        for f in doc.features { #expect(model.status[f.id] == .ok, "\(f.name): \(model.error(for: f.id) ?? "")") }
        return (doc, model, try #require(model.bodies.first))
    }

    @Test(arguments: [TexturePatternID.knit, .dots, .flagstone])
    func texturedCylinderIsWatertight(_ pattern: TexturePatternID) async throws {
        var o = TextureSamples.Options()
        o.diameter = 30; o.height = 24; o.pattern = pattern
        let (_, _, body) = try await evaluate(o)
        #expect(body.textures.count == 1)
        let plain = try body.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)
        let mesh = try body.printMesh(quality: testQuality)
        let check = MeshCheck.check(mesh)
        #expect(check.passes, "\(check)")
        #expect(mesh.triangleCount > plain.triangleCount * 4)
        // The side moved by about the pattern's amplitude; the bed stayed flat at z = 0.
        let amplitude = TextureCatalog.make(pattern, body.textures[0].values)!.amplitude
        let radii = mesh.positions.map { Double(($0.x * $0.x + $0.y * $0.y).squareRoot()) }
        let maxR = radii.max()!, minR = radii.filter { $0 > 14 }.min()!
        #expect(maxR - minR > amplitude * 0.5)
        #expect(maxR < 15 + amplitude + 1e-3 && minR > 15 - amplitude - 1e-3)
        #expect(abs(Double(mesh.bounds!.min.z)) < 1e-6)
        let bottom = mesh.positions.filter { $0.z < 1e-4 }
        #expect(bottom.allSatisfy { ($0.x * $0.x + $0.y * $0.y).squareRoot() <= 15 + 1e-3 })
    }

    @Test func texturedBoxWithEveryFaceButTheBedIsWatertight() async throws {
        var o = TextureSamples.Options()
        o.base = .box; o.diameter = 20; o.height = 12; o.faces = .all; o.pattern = .dots
        o.values = ["diameter": 4, "spacing": 7, "height": 0.8]
        let (_, _, body) = try await evaluate(o)
        #expect(body.textures.first?.faces == nil)
        let mesh = try body.printMesh(quality: testQuality)
        let check = MeshCheck.check(mesh)
        #expect(check.passes, "\(check)")
        // The bed face is untouched: still flat at z = 0 with the box's footprint.
        let z = mesh.positions.map(\.z)
        #expect(z.min()! == 0)
        #expect(Double(z.max()!) > 12.2)  // dots on top
        let bed = try #require(TextureEngine.bedFaces(of: body.shape).first)
        let bedTriangles = (0..<mesh.triangleCount).filter { mesh.triangleFaces[$0] == Int32(bed) }
        for t in bedTriangles {
            for k in 0..<3 { #expect(mesh.positions[Int(mesh.indices[3 * t + k])].z == 0) }
        }
    }

    /// A box rounded with two fillet sizes has free-form corner blends where the fillets meet.
    /// They get their own (u, v) rather than a triplanar blend, and dots stay clear of the
    /// curved edges where the fillets meet them (whole dots any edge, others the seams between
    /// the smoothly joined faces), so the export is clean.
    @Test(arguments: [true, false])
    func dotsOnFreeFormCornerBlendsAreClean(_ whole: Bool) throws {
        var shape = try Shape.box(corner: Vec3(-20, -20, 0), size: Vec3(40, 40, 30))
        let vertical = shape.edgeInfos.indices.filter { abs(shape.edgeInfo($0).tangentAtMid.normalized.z) > 0.99 }
        shape = try shape.filleted(edges: vertical, radius: 6)
        let top = shape.edgeInfos.indices.filter { shape.edgeInfo($0).mid.z > 30 - 1e-6 }
        shape = try shape.filleted(edges: top, radius: 12)
        let blends = shape.faceInfos.indices.filter {
            if case .parametric = FaceSurface(face: $0, of: shape) { true } else { false }
        }
        #expect(blends.count == 4)

        let values = TextureValues(["diameter": 6, "spacing": 9, "rowSpacing": 8, "whole": whole ? 1 : 0])
        let texture = BodyTexture(feature: UUID(), pattern: .dots, values: values, faces: nil)
        let d = TextureEngine.exportDeflection
        let mesh = try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)
        let check = MeshCheck.check(TextureEngine.apply([texture], to: mesh, of: shape, quality: testQuality))
        #expect(check.passes, "\(check)")
    }

    /// A free-form face's (u, v) are millimetres along the surface, with v up and u to the right
    /// seen from outside, whichever way round the face's own parameters run.
    @Test(arguments: [false, true])
    func parametricChartMeasuresAlongTheSurface(_ zFirst: Bool) {
        // A quarter of a cylinder of radius 10 around z, 20 high, sampled as a free-form face.
        let n = 41, r = 10.0
        var points: [Vec3] = []
        for j in 0..<n {
            for i in 0..<n {
                let s = Double(zFirst ? j : i) / Double(n - 1), z = Double(zFirst ? i : j) / Double(n - 1) * 20
                points.append(Vec3(r * cos(s * .pi / 2), r * sin(s * .pi / 2), z))
            }
        }
        // dS/du × dS/dv points inwards when u runs up the wall: the face is reversed then.
        let grid = FaceGrid(nu: n, nv: n, points: points, uRange: 0...1, vRange: 0...1,
                            uClosed: false, vClosed: false, reversed: zFirst)
        let chart = ParametricChart(grid: grid)
        #expect(abs(chart.extent.x - r * .pi / 2) < 0.01 && abs(chart.extent.y - 20) < 1e-6)
        let a = chart.uv(SIMD3(r * cos(.pi / 8), r * sin(.pi / 8), 5))
        let b = chart.uv(SIMD3(r * cos(3 * .pi / 8), r * sin(3 * .pi / 8), 15))
        #expect(abs(a.y - 5) < 0.01 && abs(b.y - 15) < 0.01)
        // Seen from outside, angle increasing runs to the right.
        #expect(abs(a.x - r * .pi / 8) < 0.02 && abs(b.x - 3 * r * .pi / 8) < 0.02)
    }

    /// Joints cut in deeper than the fade is wide: next to a box's sharp corners a cut stays
    /// shallower than its distance from the edge, so the cuts of the two faces never cross.
    @Test(arguments: [0.0, 1.0])
    func deepCutsStayClearOfSharpCorners(_ fade: Double) async throws {
        var o = TextureSamples.Options()
        o.base = .box; o.diameter = 30; o.height = 20; o.faces = .all; o.pattern = .flagstone
        o.values = ["size": 8, "depth": 2, "fade": Expr(fade)]
        let (_, _, body) = try await evaluate(o)
        let check = MeshCheck.check(try body.printMesh(quality: testQuality))
        #expect(check.passes, "\(check)")
    }

    @Test func vaseWithRevolvedProfileIsWatertight() async throws {
        var o = TextureSamples.Options()
        o.base = .vase; o.diameter = 30; o.height = 30; o.pattern = .knit
        let (_, _, body) = try await evaluate(o)
        let check = MeshCheck.check(try body.printMesh(quality: testQuality))
        #expect(check.passes, "\(check)")
    }

    @Test func facesSurviveAnUpstreamEdit() async throws {
        var o = TextureSamples.Options()
        o.diameter = 20; o.height = 15
        var doc = try await TextureSamples.document(o)
        guard case .primitive(var p) = doc.features[0].kind else { Issue.record("expected a primitive"); return }
        p.dimensions = [24, 18]
        doc.features[0].kind = .primitive(p)
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[doc.features[1].id] == .ok)
        let body = try #require(model.bodies.first)
        #expect(TextureEngine.faces(of: body.textures[0], on: body.shape).count == 1)
        // The viewport shows the texture too.
        let shown = try #require(model.meshes[body.ref])
        let plain = try body.shape.tessellate(linearDeflection: 0.05, angularDeflection: 0.3)
        #expect(shown.triangleCount > plain.triangleCount * 2)
        #expect(MeshCheck.check(shown, selfIntersections: false).isWatertight)
    }

    @Test func smoothRingOfWallsSharesOneMapping() async throws {
        // A stadium (two flat sides, two half-round ends) extruded straight up: knit runs around
        // it as one band, with a whole number of stitches and no seam where the faces meet.
        var doc = Document(name: "Stadium")
        let sketchID = UUID(), bodyID = UUID()
        let p = { (x: Double, y: Double) in Point2Expr(Expr(x), Expr(y)) }
        doc.features.append(Feature(id: sketchID, name: "Outline", .sketch(Sketch(plane: .standard(.xy, offset: 0), shapes: [
            SketchShape(.slot(a: p(-10, 0), b: p(10, 0), width: 12)),
        ]))))
        doc.features.append(Feature(id: bodyID, name: "Stadium", .extrude(Extrude(
            sketch: sketchID, regions: [RegionRef(x: 0, y: 0)], distance: 15))))
        var model = await ModelEvaluator().evaluate(doc)
        var body = try #require(model.bodies.first)
        let sides = body.shape.faceInfos.indices.filter { abs(body.shape.faceInfo($0).normal.normalized.z) < 0.5 }
        #expect(sides.count >= 4)
        doc.features.append(Feature(name: "Knit", .texture(Texture(
            body: body.ref, faces: sides.compactMap { model.faceRef(body: body.ref, face: $0) }, pattern: .knit,
            values: ["stitchWidth": 3, "stitchHeight": 3, "depth": 0.6]))))
        model = await ModelEvaluator().evaluate(doc)
        body = try #require(model.bodies.first)

        let pattern = try #require(TextureCatalog.make(.knit, body.textures[0].values))
        var specs: [Int32: TextureEngine.FaceTexture] = [:]
        for f in sides { specs[Int32(f)] = .init(surface: FaceSurface(face: f, of: body.shape), pattern: pattern, fade: 0) }
        let plain = try body.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)
        let bands = WorkMesh(welding: plain).wallBands(specs)
        #expect(bands.count == sides.count)
        let mapping = try #require(bands[Int32(sides[0])])
        #expect(mapping.wraps)
        let extent = try #require(mapping.extent)
        let perimeter = 2 * 20 + Double.pi * 12
        let repeats = extent.x / 3
        #expect(abs(repeats - repeats.rounded()) < 1e-6)
        #expect(abs(extent.x - perimeter) < 1.6)
        #expect(abs(extent.y - 15) < 1e-3)
        // u runs on across the edge between a flat side and a round end.
        let joint = SIMD3<Double>(10, 6, 7.5)
        let a = mapping.uv(joint + SIMD3(-0.01, 0, 0)), b = mapping.uv(SIMD3(10 + 6 * sin(0.002), 6 * cos(0.002), 7.5))
        #expect(abs(a.x - b.x) < 0.1)
        #expect(abs(a.y - 7.5) < 1e-3)

        let check = MeshCheck.check(try body.printMesh(quality: testQuality))
        #expect(check.passes, "\(check)")
    }

    /// A crevice or recessed dot deeper than a thin wall stops short of the inside, leaving
    /// wall behind it, instead of coming out the other side (a self-intersecting print mesh).
    @Test(arguments: [TexturePatternID.knit, .dots])
    func deepTextureOnAThinWallKeepsAWall(_ pattern: TexturePatternID) async throws {
        var o = TextureSamples.Options()
        o.diameter = 40; o.height = 30; o.shell = 1.2; o.pattern = pattern
        o.values = pattern == .knit ? ["depth": 3] : ["diameter": 8, "spacing": 12, "rowSpacing": 12, "height": 2.5, "raised": 0]
        let (_, _, body) = try await evaluate(o)
        let mesh = try body.printMesh(quality: testQuality)
        let check = MeshCheck.check(mesh)
        #expect(check.passes, "\(check)")
        // Between the floor and the rim, nothing lies inside the wall's inner 0.5 mm: the inside
        // stays at r = 18.8 and the deepest relief stops at least 0.5 mm short of it.
        let radii = mesh.positions.filter { $0.z > 3 && $0.z < 27 }.map { Double(($0.x * $0.x + $0.y * $0.y).squareRoot()) }
        #expect(!radii.contains { $0 > 18.8 + 1e-3 && $0 < 19.3 })
        #expect(radii.min()! > 18.8 - 1e-3)
        // The relief is still there, only shallower.
        #expect(radii.filter { $0 > 18.9 }.min()! < 20 - 0.4)
    }

    /// The same design always exports the same mesh (crease flips once followed the order of a
    /// dictionary, which changes from run to run).
    @Test func printMeshIsReproducible() async throws {
        var o = TextureSamples.Options()
        o.diameter = 20; o.height = 12; o.pattern = .knit
        let (_, _, body) = try await evaluate(o)
        let a = try body.printMesh(quality: testQuality), b = try body.printMesh(quality: testQuality)
        #expect(a.positions == b.positions && a.indices == b.indices)
    }

    /// Points move along the surface's own normal, carried from the kernel through subdivision,
    /// not the faceted triangles': on a cylinder every point of the wall, also on its bottom edge
    /// next to the flat base and inside the long strips it tessellates into, gets the radial
    /// direction. (Normals off by a degree from one facet to the next folded the thin strips of a
    /// disc's rim, which then came out notched.)
    @Test func surfaceNormalsStayTrueThroughSubdivision() throws {
        let shape = try Shape.cylinder(base: .xy, radius: 8, height: 20)
        let wall = try #require(shape.faceInfos.indices.first { shape.faceInfos[$0].surface == .cylinder })
        let d = TextureEngine.exportDeflection
        var m = WorkMesh(welding: try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular))
        #expect(m.surfaceNormals.count == m.points.count)
        m.subdivide(maxEdge: 0.5, where: { $0 == Int32(wall) }, maxTriangles: 400_000)
        #expect(m.surfaceNormals.count == m.points.count)
        var checked = 0, worst = 0.0
        for (t, f) in m.faces.enumerated() where f == Int32(wall) {
            for v in [m.triangles[t].x, m.triangles[t].y, m.triangles[t].z] {
                let p = m.points[Int(v)]
                let radial = simd_normalize(SIMD3(p.x, p.y, 0))
                let n = m.surfaceNormal(v, face: f)
                worst = max(worst, acos(min(1, simd_dot(n, radial))) * 180 / .pi)
                checked += 1
            }
        }
        #expect(checked > 1000)
        #expect(worst < 0.5, "normal off the radial direction by \(worst)°")
    }

    /// Without whole dots, dots still never straddle a seam where two textured faces meet
    /// smoothly (each face lays its dots out on its own, so such a dot would be cut in two with a
    /// step), but run off the face's other edges.
    @Test func dotsWithoutWholeOnesSkipSeamsButRunOffOuterEdges() throws {
        let values = TextureValues(["diameter": 6, "spacing": 10, "rowSpacing": 10, "height": 1, "profile": 2,
                                    "edge": 0.3, "raised": 1, "stagger": 0, "whole": 0])
        let pattern = try #require(TextureCatalog.make(.dots, values))
        // Dots sit on a 10 mm grid from (5, 5). The face's outline: a seam along u = 2 on the
        // left, an outer edge along v = 2 at the bottom, both 3 mm from the nearest dot centres.
        let face = TextureFace(extent: SIMD2(40, 40), wraps: false, border: [
            .init(SIMD2(2, 2), SIMD2(2, 40), seam: true), .init(SIMD2(2, 2), SIMD2(40, 2)),
            .init(SIMD2(40, 2), SIMD2(40, 40)), .init(SIMD2(2, 40), SIMD2(40, 40)),
        ])
        let fitted = pattern.fitted(to: face)
        // The column at u = 5 would reach across the seam.
        for v in stride(from: 5.0, through: 35, by: 10) {
            #expect(fitted.height(at: SIMD2(5, v)) == 0)
            #expect(fitted.height(at: SIMD2(15, v)) > 0.9)
        }
        // The row at v = 5 runs right up to the bottom edge, unlike with whole dots.
        #expect(fitted.height(at: SIMD2(15, 2.5)) > 0.9)
        // Unfitted, the column at u = 5 is there.
        #expect(pattern.height(at: SIMD2(5, 15)) > 0.9)
    }

    /// A rounded box: flat faces, fillets and the corner blends where they meet, all meeting
    /// smoothly. Flagstones are laid out once over all of them in space, not face by face (two
    /// layouts butting together left straight seams slicing stones, with torn ledges along every
    /// fillet), so the height runs on unbroken from the top onto a fillet, and the export is clean.
    @Test func flagstonesRunOnAcrossFilletsAndCornerBlends() throws {
        var shape = try Shape.box(corner: Vec3(-20, -20, 0), size: Vec3(40, 40, 30))
        let vertical = shape.edgeInfos.indices.filter { abs(shape.edgeInfo($0).tangentAtMid.normalized.z) > 0.99 }
        shape = try shape.filleted(edges: vertical, radius: 6)
        let top = shape.edgeInfos.indices.filter { shape.edgeInfo($0).mid.z > 30 - 1e-6 }
        shape = try shape.filleted(edges: top, radius: 12)
        let values = TextureValues(["size": 10])
        let texture = BodyTexture(feature: UUID(), pattern: .flagstone, values: values, faces: nil)
        let d = TextureEngine.exportDeflection
        let mesh = try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)

        // One layout for every textured face.
        let pattern = try #require(TextureCatalog.make(.flagstone, values))
        var specs: [Int32: TextureEngine.FaceTexture] = [:]
        for f in TextureEngine.faces(of: texture, on: shape) {
            specs[Int32(f)] = .init(surface: FaceSurface(face: f, of: shape), pattern: pattern, fade: 1)
        }
        let solids = WorkMesh(welding: mesh).solidTextures(specs, detailScale: 1)
        #expect(solids.count == specs.count)
        let solid = try #require(solids.values.first)
        // Across the top (z = 30, up to x = 8) and on round the fillet (centre x = 8, z = 18):
        // no step anywhere along the way, though it crosses joints.
        var heights: [Double] = []
        for i in 0...400 {
            let s = Double(i) * 0.05
            let p: SIMD3<Double>, n: SIMD3<Double>
            if s <= 8 {
                p = SIMD3(s, 1, 30); n = SIMD3(0, 0, 1)
            } else {
                let a = (s - 8) / 12
                p = SIMD3(8 + 12 * sin(a), 1, 18 + 12 * cos(a)); n = SIMD3(sin(a), 0, cos(a))
            }
            heights.append(solid.height(at: p, normal: n))
        }
        #expect(heights.min()! < -0.8 && heights.max()! > -0.3)
        let steepest = zip(heights, heights.dropFirst()).map { abs($0 - $1) }.max()!
        #expect(steepest < 0.15, "height jumps by \(steepest) mm in 0.05 mm")

        let check = MeshCheck.check(TextureEngine.apply([texture], to: mesh, of: shape, quality: testQuality))
        #expect(check.passes, "\(check)")
    }

    /// Seeds land inside triangles, never on their edges. Put at each lattice point's nearest spot
    /// of the tessellation instead, every point outside a convex fold (a fillet's facets, the
    /// surface's border along the bed) was clamped onto the fold, and a quarter of the stones on a
    /// filleted box grew from seeds lined up along those lines, cutting the stones there along
    /// straight seams and into slivers.
    @Test func flagstoneSeedsStayOffTheTessellationsFolds() throws {
        var shape = try Shape.box(corner: Vec3(-30, -30, 0), size: Vec3(60, 60, 45))
        let vertical = shape.edgeInfos.indices.filter { abs(shape.edgeInfo($0).tangentAtMid.normalized.z) > 0.99 }
        shape = try shape.filleted(edges: vertical, radius: 8)
        let top = shape.edgeInfos.indices.filter { shape.edgeInfo($0).mid.z > 45 - 1e-6 }
        shape = try shape.filleted(edges: top, radius: 3)
        let d = TextureEngine.exportDeflection
        let m = WorkMesh(welding: try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular))
        let bed = TextureEngine.bedFaces(of: shape)
        let tris = m.triangles.indices.filter { !bed.contains(Int(m.faces[$0])) }.map { m.triangles[$0] }
        let surface = TextureSurface(points: m.points, triangles: tris)
        let seeds = surface.scatter(spacing: 0.83 * 15, jitter: 0.86, seed: 1)
        #expect(seeds.count > 40)
        var onFold = 0
        for s in seeds {
            var nearest = Double.infinity
            for t in tris {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    let p = m.points[Int(a)], q = m.points[Int(b)]
                    let k = max(0, min(1, simd_dot(s.point - p, q - p) / simd_length_squared(q - p)))
                    nearest = min(nearest, simd_distance(p + k * (q - p), s.point))
                }
            }
            if nearest < 1e-6 { onFold += 1 }
        }
        #expect(onFold == 0, "\(onFold) of \(seeds.count) seeds on a triangle edge")
    }

    /// A seed round a tight convex curve (a heart's tip turns the normal by about 100°) is
    /// measured at its plain distance; only one facing away by more than 120° (the far side of a
    /// thin wall) counts as farther. Penalised from 90° on, the stones at the tip were squeezed
    /// into strips by a penalty that changed with every degree the normal turned.
    @Test func flagstoneSeedsRoundATightCurveCountAtTheirDistance() throws {
        let pattern = FlagstonePattern(TextureValues(["size": 15]))
        let surface = TextureSurface(points: [SIMD3(-20, -20, 0), SIMD3(20, -20, 0), SIMD3(0, 20, 0)], triangles: [SIMD3(0, 1, 2)])
        func owner(seedTurnedBy degrees: Double) -> Int {
            let a = degrees * .pi / 180
            let seeds = [TextureSurface.Seed(point: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), id: 1),
                         TextureSurface.Seed(point: SIMD3(3, 0, 0), normal: SIMD3(sin(a), 0, cos(a)), id: 2)]
            let solid = SolidFlagstones(pattern: pattern, seeds: seeds, surface: surface)
            // Nearer the second seed.
            return solid.stone(at: SIMD3(1.6, 0, 0), normal: SIMD3(0, 0, 1)).seed
        }
        #expect(owner(seedTurnedBy: 0) == 1)
        #expect(owner(seedTurnedBy: 100) == 1)
        #expect(owner(seedTurnedBy: 160) == 0)
    }

    /// Unfolded into the tangent plane, a point round a cylinder lands as far away as the way
    /// along the surface to it, in the direction the way leaves in: exactly what unrolling the
    /// cylinder gives.
    @Test func unfoldingRoundACylinderIsExact() {
        let r = 5.0
        func point(_ a: Double, _ z: Double) -> (p: SIMD3<Double>, n: SIMD3<Double>) {
            (SIMD3(r * cos(a), r * sin(a), z), SIMD3(cos(a), sin(a), 0))
        }
        let base = point(0.3, 2)
        let along = SIMD3(-sin(0.3), cos(0.3), 0.0), up = SIMD3(0.0, 0, 1)
        for (da, dz) in [(1.2, 0.0), (-0.9, 3.0), (1.7, -6.0), (0.05, 4.0), (-1.5, 0.5)] {
            let q = point(0.3 + da, 2 + dz)
            let u = TextureSurface.unfold(q.p - base.p, from: base.n, to: q.n)
            #expect(abs(simd_dot(u, base.n)) < 1e-9)
            #expect(simd_distance(u, r * da * along + dz * up) < 1e-9, "\(da), \(dz): \(u)")
            let way = TextureSurface.surfaceDistanceSquared(q.p - base.p, base.n, q.n)
            #expect(abs(way - (r * da * r * da + dz * dz)) < 1e-9)
        }
    }

    /// Round a tight rounded corner the distance to a joint is the way along the surface, the same
    /// on both sides of the joint: the stone's edge round is as wide on either side. Measured in
    /// the tangent plane to the bisector of the seeds in space, it came out 40% short on one side
    /// of a joint crossing a 5 mm round and long on the other, so one side's round was squeezed
    /// into a crease and narrow stones along the corner stood as ridges.
    @Test func flagstoneEdgeDistanceRoundATightCornerIsTheWayAlongIt() {
        let pattern = FlagstonePattern(TextureValues(["size": 15, "irregularity": 0]))
        let r = 5.0
        func point(_ a: Double, _ z: Double) -> (p: SIMD3<Double>, n: SIMD3<Double>) {
            (SIMD3(r * cos(a), r * sin(a), z), SIMD3(cos(a), sin(a), 0))
        }
        // Two seeds round the corner, at different heights; unrolled, (s, z) = (r·a, z).
        let a = (angle: -1.1, z: 0.0), b = (angle: 0.9, z: 4.0)
        let seeds = [a, b].enumerated().map { i, s in
            let q = point(s.angle, s.z)
            return TextureSurface.Seed(point: q.p, normal: q.n, id: UInt64(i + 1))
        }
        let surface = TextureSurface(points: [SIMD3(-9, -9, -9), SIMD3(9, -9, -9), SIMD3(0, 9, 9)], triangles: [SIMD3(0, 1, 2)])
        let solid = SolidFlagstones(pattern: pattern, seeds: seeds, surface: surface)
        let sa = SIMD2(r * a.angle, a.z), sb = SIMD2(r * b.angle, b.z)
        var worst = 0.0
        for i in -40...40 {
            for z in [-3.0, 2.0, 7.0] {
                let angle = Double(i) * 0.02
                let q = point(angle, z)
                let flat = SIMD2(r * angle, z)
                // The plain Voronoi distance on the unrolled surface.
                let expected = abs(simd_length_squared(flat - sb) - simd_length_squared(flat - sa)) / (2 * simd_distance(sa, sb))
                guard expected < 4 else { continue }
                let got = solid.stone(at: q.p, normal: q.n).edgeDistance
                worst = max(worst, abs(got - expected))
            }
        }
        #expect(worst < 1e-6, "edge distance off by up to \(worst) mm")
    }

    /// Seeds go to tight convex bends first, so stones wrap round a rounded corner like a mason's
    /// quoins and the joints cross it. Left to chance, a joint often ran down a heart's 5 mm tip
    /// and the corner read as a straight seam between two columns of stones. And no two seeds are
    /// nearer than the spacing along the surface.
    @Test func flagstoneSeedsWrapTightCorners() {
        // An L-shaped wall 100 mm long: a flat face, a 4 mm round turning it by 90°, a flat face.
        let r = 4.0
        var profile: [(p: SIMD2<Double>, n: SIMD2<Double>)] = []
        for i in 0..<30 { profile.append((SIMD2(-30 + Double(i), 0), SIMD2(0, -1))) }
        for i in 0...16 {
            let a = -Double.pi / 2 + Double(i) / 16 * Double.pi / 2
            profile.append((SIMD2(r * cos(a), r + r * sin(a)), SIMD2(cos(a), sin(a))))
        }
        for i in 1...30 { profile.append((SIMD2(r, r + Double(i)), SIMD2(1, 0))) }
        var points: [SIMD3<Double>] = [], triangles: [SIMD3<Int32>] = []
        let rows = 101
        for z in 0..<rows { for q in profile { points.append(SIMD3(q.p.x, q.p.y, Double(z))) } }
        let w = Int32(profile.count)
        for z in 0..<Int32(rows - 1) {
            for i in 0..<(w - 1) {
                let a = z * w + i
                triangles.append(SIMD3(a, a + 1, a + w))
                triangles.append(SIMD3(a + 1, a + w + 1, a + w))
            }
        }
        let surface = TextureSurface(points: points, triangles: triangles)
        let spacing = 0.83 * 15
        var onBend = 0
        for seed in [1, 2, 3, 4] as [UInt64] {
            let seeds = surface.scatter(spacing: spacing, jitter: 0.86, seed: seed)
            let bend = seeds.filter { $0.normal.x > 1e-9 && $0.normal.y < -1e-9 }.map(\.point.z).sorted()
            onBend += bend.count
            // Seeds all along the corner: no long stretch of it where a joint runs down it. (Without
            // the priority the four layouts put 6 seeds on the round between them.)
            let gaps = zip([0.0] + bend, bend + [100.0]).map { $1 - $0 }
            #expect(gaps.max()! < 2.2 * spacing, "seed \(seed): corner seeds at \(bend)")
            for (i, s) in seeds.enumerated() {
                for t in seeds[(i + 1)...] {
                    #expect(TextureSurface.surfaceDistanceSquared(t.point - s.point, s.normal, t.normal) >= spacing * spacing - 1e-9)
                }
            }
        }
        #expect(onBend >= 22)
    }

    /// The deepest cut allowed near a sharp or untextured edge stays within `cutSlope` of it,
    /// leaves the edge level, rises without a bend and runs level into the full depth before the
    /// limit ends: a straight ramp met the joint floor in a bend finer than the floor's
    /// triangles, and joints ran into the bed and the rim in a saw-toothed line.
    @Test func cutLimitRisesSmoothlyWithinTheSlope() {
        let amplitude = 1.0
        let range = TextureEngine.cutLimitRange(amplitude: amplitude)
        let h = range / 2000
        var previous = 0.0, previousSlope = 0.0
        for i in 1..<2000 {
            let d = Double(i) * h
            let limit = TextureEngine.cutLimit(at: d, amplitude: amplitude)
            #expect(limit <= TextureEngine.cutSlope * d + 1e-12)
            #expect(limit >= previous)
            let slope = (limit - previous) / h
            #expect(abs(slope - previousSlope) < 0.01, "bend at \(d) mm")
            previous = limit; previousSlope = slope
        }
        // Level at both ends, deeper than the deepest cut (and its rounding) before it ends.
        #expect(TextureEngine.cutLimit(at: h, amplitude: amplitude) < 1e-6)
        #expect(previousSlope < 0.01)
        #expect(previous > 1.29 * amplitude)
        #expect(TextureEngine.cutLimit(at: range, amplitude: amplitude) == .infinity)
    }

    /// Each grid cell lists every seed that can matter to its points: the stone found through
    /// the list is the one found among all seeds (a seed missing from one cell's list but not
    /// its neighbour's would cut a straight seam through the stones along the cell's side).
    @Test func flagstoneSeedListsAreComplete() throws {
        let shape = try Shape.cylinder(base: .xy, radius: 15, height: 30)
        let d = TextureEngine.exportDeflection
        var m = WorkMesh(welding: try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular))
        let wall = try #require(shape.faceInfos.indices.first { shape.faceInfos[$0].surface == .cylinder })
        let pattern = FlagstonePattern(TextureValues(["size": 8, "joint": 1.2, "edge": 1, "depth": 1, "irregularity": 0.8,
                                                      "relief": 0.4, "roughness": 0.3, "seed": 3]))
        let surface = TextureSurface(points: m.points, triangles: m.triangles.indices.filter { m.faces[$0] == Int32(wall) }.map { m.triangles[$0] })
        let solid = try #require(pattern.solid(over: surface) as? SolidFlagstones)
        var everything = solid
        everything.index = [:]
        m.subdivide(maxEdge: 0.7, where: { $0 == Int32(wall) }, maxTriangles: 400_000)
        var checked = 0
        for (t, f) in m.faces.enumerated() where f == Int32(wall) && t % 7 == 0 {
            let p = m.points[Int(m.triangles[t].x)]
            let n = simd_normalize(SIMD3(p.x, p.y, 0))
            let a = solid.stone(at: p, normal: n), b = everything.stone(at: p, normal: n)
            #expect(a.seed == b.seed)
            // Equal up to the far seeds' vanishing share of the smooth minimum.
            #expect(abs(a.edgeDistance - b.edgeDistance) < 1e-6, "\(a.edgeDistance) vs \(b.edgeDistance)")
            checked += 1
        }
        #expect(checked > 1000)
        // About one stone per size × size of surface.
        let area = 2 * Double.pi * 15 * 30
        #expect(abs(Double(solid.seeds.count) - area / 64) < area / 64 * 0.35, "\(solid.seeds.count) stones")
    }

    /// Over the triangle budget, subdivision splits the edges furthest over their wanted length
    /// until the budget is used up, rather than dropping that whole pass (which left a part that
    /// asked for finer triangles than fit coarser than one that asked for fewer).
    /// Short of triangles (the viewport's budget), a layout in space still gets them where it
    /// asks for them: every wanted length grows by the same factor, so the stones' edges stay
    /// several times finer than their tops. Capping every triangle at the length a uniform mesh
    /// would need made edges and tops alike, and the stone edges frayed. And no needle triangles:
    /// the crease flips, which chained into fans of them along the edges, leave stones alone.
    @Test func budgetGoesToTheStoneEdges() throws {
        let shape = try Shape.box(corner: Vec3(-20, -20, 0), size: Vec3(40, 40, 30))
        let values = TextureValues(["size": 20])
        let texture = BodyTexture(feature: UUID(), pattern: .flagstone, values: values, faces: nil)
        let d = TextureEngine.exportDeflection
        let mesh = try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)
        let quality = TextureQuality(edgeScale: 1.4, maxTriangles: 60_000)
        let out = TextureEngine.apply([texture], to: mesh, of: shape, quality: quality)
        let count = out.indices.count / 3
        #expect(count <= 60_000 && count > 45_000, "\(count) triangles")

        // The layout as the engine lays it out, to tell edges from tops on the front wall.
        let pattern = try #require(TextureCatalog.make(.flagstone, values))
        var specs: [Int32: TextureEngine.FaceTexture] = [:]
        for f in TextureEngine.faces(of: texture, on: shape) {
            specs[Int32(f)] = .init(surface: FaceSurface(face: f, of: shape), pattern: pattern, fade: 0)
        }
        let solids = WorkMesh(welding: mesh).solidTextures(specs, detailScale: quality.edgeScale * quality.edgeScale)
        let front = try #require(specs.keys.first { shape.faceInfos[Int($0)].normal.normalized.y < -0.99 })
        let solid = try #require(solids[front] as? SolidFlagstones)
        let round = solid.pattern.edgeRound
        var rim: [Double] = [], top: [Double] = [], needles = 0, frontCount = 0
        for t in 0..<count {
            let p = (0..<3).map { SIMD3<Double>(out.positions[Int(out.indices[3 * t + $0])]) }
            let c = (p[0] + p[1] + p[2]) / 3
            guard c.y < -18.5, abs(c.x) < 16, c.z > 4, c.z < 26 else { continue }
            frontCount += 1
            let lengths = [simd_distance(p[0], p[1]), simd_distance(p[1], p[2]), simd_distance(p[2], p[0])]
            let area = simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
            // Smallest angle under about 4°: twice the area over the longest edge squared.
            if 2 * area < 0.07 * pow(lengths.max()!, 2) { needles += 1 }
            guard let e = solid.contour(at: SIMD3(c.x, -20, c.z), normal: SIMD3(0, -1, 0)) else { continue }
            let mean = lengths.reduce(0, +) / 3
            if e > round.start, e < round.start + round.width { rim.append(mean) }
            if e > round.start + round.width + 1.5 { top.append(mean) }
        }
        #expect(rim.count > 1000 && top.count > 100)
        let rimMean = rim.reduce(0, +) / Double(rim.count), topMean = top.reduce(0, +) / Double(top.count)
        #expect(topMean > 2.3 * rimMean, "tops \(topMean) mm, edges \(rimMean) mm")
        #expect(Double(needles) <= 0.001 * Double(frontCount), "\(needles) of \(frontCount) triangles are needles")
    }

    @Test func subdivisionFillsTheBudget() {
        var m = WorkMesh(points: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0), SIMD3(0, 10, 0)],
                         triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], faces: [0, 0])
        m.subdivide(maxEdge: 0.05, where: { $0 == 0 }, maxTriangles: 5000)
        #expect(m.triangles.count > 4500 && m.triangles.count <= 5000, "\(m.triangles.count) triangles")
    }

    /// A sliver (one corner almost on the opposite edge) that a difference in height would flip
    /// over keeps its displacement: the corner moves with the edge, instead of the displacement
    /// being halved until nothing folds (which left torn notches along the joints).
    @Test func relaxMovesASliverWithItsEdge() {
        let m = WorkMesh(points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.5, 0.001, 0), SIMD3(0.5, -1, 0)],
                         triangles: [SIMD3(0, 1, 2), SIMD3(1, 0, 3)], faces: [0, 0])
        var offsets: [SIMD3<Double>] = [.zero, SIMD3(0, 0, 0.5), .zero, SIMD3(0, 0, 0.2)]
        m.relax(&offsets, floor: -10)
        #expect(offsets[1] == SIMD3(0, 0, 0.5))
        #expect(abs(offsets[2].z - 0.25) < 1e-9)
    }

    /// Splitting a cylinder's flat strips puts the new points on the cylinder (along the curve
    /// through both ends, square to their normals), not on the chord between them: points left
    /// on the strips kept the tessellation's facets, a few degrees apart, which showed as straight
    /// streaks along a textured wall.
    @Test func subdivisionSplitsAlongTheCurvedSurface() throws {
        let shape = try Shape.cylinder(base: .xy, radius: 8, height: 20)
        let wall = try #require(shape.faceInfos.indices.first { shape.faceInfos[$0].surface == .cylinder })
        let d = TextureEngine.exportDeflection
        var m = WorkMesh(welding: try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular))
        // How far the kernel's own points come inside the cylinder between its strips' edges.
        let chordSag = m.points.map { abs(simd_length(SIMD2($0.x, $0.y)) - 8) }.max()!
        m.subdivide(maxEdge: 0.3, where: { $0 == Int32(wall) }, maxTriangles: 400_000)
        var worst = 0.0, checked = 0
        for (t, f) in m.faces.enumerated() where f == Int32(wall) {
            for v in [m.triangles[t].x, m.triangles[t].y, m.triangles[t].z] {
                worst = max(worst, abs(simd_length(SIMD2(m.points[Int(v)].x, m.points[Int(v)].y)) - 8))
                checked += 1
            }
        }
        #expect(checked > 1000)
        // A strip's chord comes up to 0.01 mm inside (the export deflection); split points don't.
        #expect(worst < 1e-3, "a point \(worst) mm off the cylinder (kernel points: \(chordSag))")
    }

    /// Displacement directions are averaged in space, so two points a few microns apart (either
    /// side of a kernel blend's sliver triangle) end up cutting the same way. Averaged along the
    /// mesh's edges they stayed a degree apart, enough to fold the sliver over, after which the
    /// cut there was dropped and stood as a stub in the joint.
    @Test func directionsAreSmoothedInSpace() {
        // A fan round two hub points 5 µm apart, half its spokes joined to each (no edge between
        // the hubs: along the mesh they only meet through the spokes).
        var points: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0.005, 0, 0)]
        var triangles: [SIMD3<Int32>] = []
        for k in 0..<12 {
            let a = Double(k) * .pi / 6
            points.append(SIMD3(cos(a), sin(a), 0) * 0.3)
            let i = Int32(points.count - 1)
            if k < 11 { triangles.append(SIMD3(k < 6 ? 0 : 1, i, i + 1)) }
        }
        let m = WorkMesh(points: points, triangles: triangles, faces: triangles.map { _ in 0 })
        var directions = points.indices.map { i -> SIMD3<Double> in
            // The two hubs and their fans lean a degree apart.
            let lean = i == 0 || (2...7).contains(i) ? 0.01 : -0.01
            return simd_normalize(SIMD3(lean, 0, 1))
        }
        m.smoothDirections(&directions, where: [Bool](repeating: true, count: points.count), radius: 1)
        let apart = acos(min(1, simd_dot(directions[0], directions[1]))) * 180 / .pi
        #expect(apart < 0.01, "hub directions \(apart)° apart")
    }

    /// A flat strip running tangentially into a quarter cylinder (radius 8 mm, as a box's rounded
    /// corner), finely meshed: face 0 the flat part, face 1 the curve.
    private func flatIntoFillet() -> (mesh: WorkMesh, normals: [SIMD3<Double>]) {
        var points: [SIMD3<Double>] = [], normals: [SIMD3<Double>] = []
        // Along s (mm of surface): -10…0 flat (x = s, z = 0), 0…12 round the cylinder.
        let r = 8.0, step = 0.1, columns = 220, rows = 60
        for j in 0...rows {
            for i in 0...columns {
                let s = -10 + Double(i) * step, y = Double(j) * step
                if s <= 0 {
                    points.append(SIMD3(s, y, 0)); normals.append(SIMD3(0, 0, 1))
                } else {
                    let a = s / r
                    points.append(SIMD3(r * sin(a), y, r * cos(a) - r)); normals.append(SIMD3(sin(a), 0, cos(a)))
                }
            }
        }
        var triangles: [SIMD3<Int32>] = [], faces: [Int32] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let a = Int32(j * (columns + 1) + i), b = a + 1, c = a + Int32(columns + 1), d = c + 1
                let face: Int32 = i < 100 ? 0 : 1
                triangles += [SIMD3(a, b, d), SIMD3(a, d, c)]
                faces += [face, face]
            }
        }
        return (WorkMesh(points: points, triangles: triangles, faces: faces), normals)
    }

    /// Smoothing the cut directions keeps true normals true where a flat face runs into a
    /// fillet: each face is fitted on its own (a plane through its normals). A plain average
    /// over both leaned the flat side's directions up to 0.8° towards the fillet over about a
    /// millimetre, and the joints cut along them creased every stone along the line where the
    /// fillet starts.
    @Test func smoothedDirectionsStayTrueWhereAFaceMeetsAFillet() {
        let (m, normals) = flatIntoFillet()
        var directions = normals
        m.smoothDirections(&directions, where: [Bool](repeating: true, count: normals.count), radius: 1)
        var worst = 0.0
        for v in normals.indices where m.points[v].y > 1.05 && m.points[v].y < 4.95 {
            worst = max(worst, acos(min(1, simd_dot(directions[v], normals[v]))) * 180 / .pi)
        }
        #expect(worst < 0.05, "a direction leans \(worst)° off the surface's normal")
    }

    /// The fairing under a layout in space evens out the jump in curvature where a flat face
    /// meets a fillet: nothing moves on the flat away from it, the fillet sinks evenly by about
    /// radius² / (20 r) away from it, and in between the change is gradual.
    @Test func fairingEvensOutAJumpInCurvature() {
        let (m, normals) = flatIntoFillet()
        let radius = 2.5
        let fair = m.fairing(along: normals, where: [Bool](repeating: true, count: normals.count), radius: radius)
        // Along the middle row, by distance s along the surface.
        var row: [(s: Double, f: Double)] = []
        for v in normals.indices where abs(m.points[v].y - 3) < 1e-9 {
            let p = m.points[v]
            let s = p.x <= 0 && p.z == 0 ? p.x : 8 * atan2(p.x, p.z + 8)
            row.append((s, fair[v]))
        }
        row.sort { $0.s < $1.s }
        for (s, f) in row where s < -radius - 0.1 { #expect(abs(f) < 1e-9, "the flat moves \(f) mm at \(s)") }
        let expected = -radius * radius / (20 * 8)
        for (s, f) in row where s > radius + 0.1 && s < 12 - radius - 0.1 {
            #expect(abs(f - expected) < 0.15 * abs(expected), "the fillet sinks \(f) mm at \(s), not \(expected)")
        }
        // Gradual: no step between neighbouring points 0.1 mm apart bigger than a tenth of the
        // whole sink.
        for k in 1..<row.count { #expect(abs(row[k].f - row[k - 1].f) < 0.1 * abs(expected)) }
    }

    /// Stone corners are rounded by opening the outline with a disc: a sharp corner ends in a round
    /// of that radius (the joint fills the tip) rather than a long low wedge between two edge
    /// rounds, a blunt one barely changes, and along a side away from the corners nothing does.
    @Test func stoneCornersAreRoundedByADisc() {
        // A wedge of 30° at the origin, opening along +x: sides y = ±x·tan 15°, `up` pointing in.
        let half = 15.0 * .pi / 180
        let upper = SIMD3(sin(half), -cos(half), 0), lower = SIMD3(sin(half), cos(half), 0)
        func sides(_ p: SIMD2<Double>) -> [(d: Double, up: SIMD3<Double>)] {
            let q = SIMD3(p.x, p.y, 0)
            return [(simd_dot(q, upper), upper), (simd_dot(q, lower), lower)]
        }
        let radius = 3.0
        func rounded(_ p: SIMD2<Double>) -> Double {
            let s = sides(p)
            return SolidFlagstones.rounded(s, nearest: min(s[0].d, s[1].d), radius: radius)
        }
        // On the axis the shrunk wedge starts at radius / sin 15° = 11.6 mm: from there in the
        // stone reaches `radius`, closer in it falls off along the round, and the tip is joint.
        let start = radius / sin(half)
        #expect(abs(rounded(SIMD2(start, 0)) - radius) < 1e-9)
        #expect(abs(rounded(SIMD2(start - 1, 0)) - (radius - 1)) < 1e-9)
        #expect(rounded(SIMD2(start - radius - 0.5, 0)) < 0)
        // Inside, and well along a side, the plain distance.
        #expect(abs(rounded(SIMD2(20, 0)) - 20 * sin(half)) < 1e-9)
        let alongSide = SIMD2(30.0, 30 * tan(half) - 1 / cos(half))
        #expect(abs(rounded(alongSide) - 1) < 1e-9)
        // Continuous: sampled across the corner, no jump between points 0.01 mm apart.
        var worst = 0.0
        for i in 0..<400 {
            for j in 0..<100 {
                let p = SIMD2(Double(i) * 0.05, Double(j) * 0.05 - 2.5)
                let a = rounded(p), b = rounded(p + SIMD2(0.01, 0)), c = rounded(p + SIMD2(0, 0.01))
                worst = max(worst, abs(a - b) / 0.01, abs(a - c) / 0.01)
            }
        }
        #expect(worst < 1.01, "the distance changes \(worst) mm per mm")
    }

    /// Where a cut along the surface's normals would fold the mesh over (the normals converge
    /// faster than the cut is deep, as at the tip of a corner blend), the points involved take
    /// their neighbours' average displacement rather than having the cut halved away: the cut
    /// keeps most of its depth there instead of leaving a torn notch.
    @Test func relaxEvensOutAFoldRatherThanDroppingTheCut() {
        // A fine flat grid, cut 1 mm deep along directions that swing in towards a spot in the
        // middle (turning faster there than the cut is deep), so the spot folds over.
        var points: [SIMD3<Double>] = []
        let n = 20, h = 0.05
        for j in 0...n { for i in 0...n { points.append(SIMD3(Double(i - n / 2) * h, Double(j - n / 2) * h, 0)) } }
        var triangles: [SIMD3<Int32>] = []
        for j in 0..<n {
            for i in 0..<n {
                let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
                triangles += [SIMD3(a, b, d), SIMD3(a, d, c)]
            }
        }
        let m = WorkMesh(points: points, triangles: triangles, faces: triangles.map { _ in 0 })
        var offsets = points.map { p -> SIMD3<Double> in
            let w = 4 * exp(-simd_length_squared(p) / (0.1 * 0.1))
            return simd_normalize(SIMD3(-w * p.x, -w * p.y, -1)) * 1
        }
        var folded = 0
        for tri in triangles {
            let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
            let n1 = simd_cross(points[b] + offsets[b] - points[a] - offsets[a], points[c] + offsets[c] - points[a] - offsets[a])
            if n1.z < 0 { folded += 1 }
        }
        #expect(folded > 0)
        m.relax(&offsets, floor: -10)
        // Nothing folds, and the cut keeps most of its depth everywhere.
        for tri in triangles {
            let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
            let n0 = simd_cross(points[b] - points[a], points[c] - points[a])
            let n1 = simd_cross(points[b] + offsets[b] - points[a] - offsets[a], points[c] + offsets[c] - points[a] - offsets[a])
            #expect(simd_dot(n0, n1) > 0)
        }
        let shallowest = offsets.map { -$0.z }.min()!
        #expect(shallowest > 0.7, "the cut is only \(shallowest) mm deep somewhere")
    }

    /// A sliver along an edge between faces (three points of the edge in a row) goes: the other
    /// face's triangle across that edge is split at its middle point instead. The mesh stays
    /// closed and wound the same way.
    @Test func sliversAlongFaceEdgesAreDissolved() {
        // Face 0 above y = 0: a sliver (0, 1, 2) along the edge and a triangle on top; face 1
        // below: one triangle under the edge.
        let points: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.4, 0.001, 0), SIMD3(0.5, 1, 0), SIMD3(0.5, -1, 0)]
        let triangles: [SIMD3<Int32>] = [SIMD3(0, 1, 2), SIMD3(0, 2, 3), SIMD3(2, 1, 3), SIMD3(1, 0, 4)]
        var m = WorkMesh(points: points, triangles: triangles, faces: [0, 0, 0, 1])
        m.dissolveSlivers { _ in true }
        #expect(m.triangles.count == 4)
        for tri in m.triangles {
            let a = m.points[Int(tri.x)], b = m.points[Int(tri.y)], c = m.points[Int(tri.z)]
            let cross = simd_cross(b - a, c - a)
            #expect(cross.z > 0, "turned over or flat: \(tri)")
            let longest = max(simd_distance_squared(a, b), simd_distance_squared(b, c), simd_distance_squared(c, a))
            #expect(simd_length(cross) > WorkMesh.sliver * longest, "still a sliver: \(tri)")
        }
        // Every edge inside is used once each way; the outline (0-4-1-3-0) once.
        var edges: [SIMD2<Int32>: Int] = [:]
        for tri in m.triangles { for k in 0..<3 { edges[SIMD2(tri[k], tri[(k + 1) % 3]), default: 0] += 1 } }
        #expect(edges.values.allSatisfy { $0 == 1 })
        let outline: Set<SIMD2<Int32>> = [SIMD2(0, 4), SIMD2(4, 1), SIMD2(1, 3), SIMD2(3, 0)]
        for (e, _) in edges where edges[SIMD2(e.y, e.x)] == nil { #expect(outline.contains(e), "open edge \(e)") }
    }

    /// The distance used to keep cuts shallow near an edge is measured straight to the edge, not
    /// summed along the mesh's zigzag edges: on a regular mesh next to a straight edge it is the
    /// distance square to the edge, within a few microns, for every point (along edges it
    /// overshot unevenly from one point to the next, and a cut limited by it came out frayed).
    @Test func distanceToAnEdgeIsStraight() {
        // A grid of equilateral triangles (its edges zigzag away from the x axis), its row at
        // y = 0 the sources.
        var points: [SIMD3<Double>] = [], triangles: [SIMD3<Int32>] = []
        let n = 30, h = 0.1
        for j in 0...n { for i in 0...n { points.append(SIMD3(Double(i) * h + Double(j % 2) * h / 2, Double(j) * h * 0.866, 0)) } }
        for j in 0..<n {
            for i in 0..<n {
                let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
                triangles += j % 2 == 0 ? [SIMD3(a, b, c), SIMD3(b, d, c)] : [SIMD3(a, b, d), SIMD3(a, d, c)]
            }
        }
        let m = WorkMesh(points: points, triangles: triangles, faces: triangles.map { _ in 0 })
        let sources = points.map { $0.y < 1e-9 }
        let distance = m.distances(from: sources, upTo: 10)
        // Along the zigzag, the rows 0.087 mm apart are 0.1 mm of edge apart: 15 % too far.
        var worst = 0.0
        for (v, p) in points.enumerated() where p.x > 0.5 && p.x < 2.5 && p.y < 1.5 {
            worst = max(worst, abs(distance[v]! - p.y))
        }
        #expect(worst < 0.005, "off by \(worst) mm")
    }

    /// Points near a stone's rounded edge are slid along the surface onto its level lines, so
    /// the triangles follow the curve instead of crossing it in a zigzag (which shaded as a
    /// saw-toothed fringe), and no triangle turns over doing it.
    /// A stone's edge rounds over onto its top gently enough for the mesh to follow: it leaves
    /// the joint floor and meets the top level, rises steadily, and at the defaults bends over
    /// onto the top at a radius of more than 1.6 mm and is nowhere steeper than 36° (a
    /// smootherstep over the 1 mm edge the default used to be bent at 0.4 mm, which shaded as a
    /// dotted line along every crest; at 1.5 mm, 0.9 mm and 47° still read as a hard bright
    /// line tracing every stone).
    @Test func stoneEdgesRoundOverGently() throws {
        let f = FlagstonePattern.shoulder
        #expect(abs(f(0)) < 1e-12 && abs(f(1) - 1) < 1e-12)
        let h = 1e-4
        #expect(abs(f(h) - f(0)) < 1e-6 && abs(f(1) - f(1 - h)) < 1e-6, "level at both ends")
        var last = 0.0
        for i in 1...1000 {
            let t = Double(i) / 1000
            #expect(f(t) >= last - 1e-12, "falls back at \(t)")
            last = f(t)
        }
        // Continuous where the foot turns into the shoulder.
        let foot = FlagstonePattern.foot
        #expect(abs(f(foot + 1e-9) - f(foot - 1e-9)) < 1e-8)

        let pattern = FlagstonePattern(TextureValues([:]).filled(with: FlagstonePattern.parameters))
        let round = pattern.edgeRound
        let depth = pattern.depth
        func height(_ e: Double) -> Double { pattern.profile(edgeDistance: e, top: 0) }
        // Tightest convex bend (over onto the top) along the profile, as a radius in mm.
        var tightest = Double.infinity
        let step = round.width / 2000
        var e = round.start + foot * round.width
        while e < round.start + round.width {
            let d1 = (height(e + step) - height(e - step)) / (2 * step)
            let d2 = (height(e + step) - 2 * height(e) + height(e - step)) / (step * step)
            if d2 < 0 { tightest = min(tightest, pow(1 + d1 * d1, 1.5) / -d2) }
            e += step
        }
        var steepest = 0.0
        e = round.start
        while e < round.start + round.width {
            steepest = max(steepest, abs(height(e + step) - height(e - step)) / (2 * step))
            e += step
        }
        #expect(depth == 1 && pattern.edge == 2.5)
        #expect(tightest > 1.6, "the shoulder bends over at a radius of \(tightest) mm")
        #expect(atan(steepest) * 180 / .pi < 36, "the edge is \(atan(steepest) * 180 / .pi)° steep")
    }

    /// The grain on the stone tops is gentle enough for the tops' triangles (``FlagstonePattern/detail``):
    /// across one, the slope changes by under 1°. A grain twice as fine changed it by 1.7°,
    /// and seen at a glancing angle (round a heart's tip) the tops shaded as streaks along the
    /// triangles' rows.
    @Test func stoneGrainSuitsTheTopsTriangles() {
        let pattern = FlagstonePattern(TextureValues([:]).filled(with: FlagstonePattern.parameters))
        let length = pattern.detail, h = 0.02
        var worst = 0.0
        for i in 0..<60 {
            for j in 0..<60 {
                let p = SIMD2(Double(i), Double(j)) * 0.37
                let s = pattern.stone(at: p)
                guard s.edgeDistance > pattern.edgeRound.start + pattern.edgeRound.width + 0.2 else { continue }
                func top(_ q: SIMD2<Double>) -> Double { pattern.stoneTop(s, at: q) }
                for d in [SIMD2<Double>(1, 0), SIMD2(0, 1), SIMD2(0.7071, 0.7071)] {
                    let bend = (top(p + h * d) - 2 * top(p) + top(p - h * d)) / (h * h)
                    worst = max(worst, abs(bend))
                }
            }
        }
        let degrees = atan(worst * length / 2) * 180 / .pi
        #expect(degrees < 1, "the slope changes by \(degrees)° across a \(length) mm triangle")
    }

    @Test func pointsLineUpAlongTheStonesEdges() throws {
        let shape = try Shape.box(corner: Vec3(-15, -15, 0), size: Vec3(30, 30, 10))
        let top = try #require(shape.faceInfos.indices.first { shape.faceInfos[$0].normal.normalized.z > 0.99 })
        var m = WorkMesh(welding: try shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1))
        let pattern = FlagstonePattern(TextureValues(["size": 10]))
        let surface = TextureSurface(points: m.points, triangles: m.triangles.indices.filter { m.faces[$0] == Int32(top) }.map { m.triangles[$0] })
        let solid = try #require(pattern.solid(over: surface))
        m.subdivide(maxEdge: 0.4, where: { $0 == Int32(top) }, maxTriangles: 400_000)
        let before = m
        // Points on the top within a tenth of a millimetre of a level line, and how many of them
        // lie on it (to 0.01 mm).
        func onLevels(_ mesh: WorkMesh) -> (near: Int, on: Int) {
            var near = 0, on = 0
            for p in mesh.points where abs(p.z - 10) < 1e-9 {
                guard let e = solid.contour(at: p, normal: SIMD3(0, 0, 1)) else { continue }
                let off = solid.contourLevels.map { abs($0 - e) }.min()!
                if off < 0.1 { near += 1 }
                if off < 0.01 { on += 1 }
            }
            return (near, on)
        }
        let was = onLevels(before)
        m.snapToContours([Int32(top): solid]) { _ in true }
        let now = onLevels(m)
        // (Fewer near since the stones' corners are rounded by a disc: the level lines round them
        // are short arcs, which the straight step onto them meets a little less often.)
        #expect(was.near > 700)
        #expect(Double(now.on) > 0.8 * Double(now.near) && Double(now.on - was.on) > 0.25 * Double(now.near),
                "\(was) → \(now) points near / on the level lines")
        for (t, tri) in m.triangles.enumerated() {
            let a = m.points[Int(tri.x)], b = m.points[Int(tri.y)], c = m.points[Int(tri.z)]
            let a0 = before.points[Int(tri.x)], b0 = before.points[Int(tri.y)], c0 = before.points[Int(tri.z)]
            #expect(simd_dot(simd_cross(b - a, c - a), simd_cross(b0 - a0, c0 - a0)) > 0, "triangle \(t) turned over")
        }
        // Points on the box's edges stay put.
        for v in m.points.indices where abs(abs(before.points[v].x) - 15) < 1e-9 || abs(abs(before.points[v].y) - 15) < 1e-9 {
            #expect(m.points[v] == before.points[v])
        }
    }

    @Test func subdivisionKeepsUntexturedNeighboursConforming() {
        // Two triangles of a unit square, only one textured: the shared edge is split in both.
        var m = WorkMesh(points: [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 4, 0), SIMD3(0, 4, 0)],
                         triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], faces: [0, 1])
        m.subdivide(maxEdge: 1, where: { $0 == 0 }, maxTriangles: 10_000)
        var forward: [UInt64: Int] = [:]
        for tri in m.triangles {
            for (p, q) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] { forward[WorkMesh.key(p, q), default: 0] += 1 }
        }
        // Interior edges are used twice; only the square's outline (split into pieces) once.
        let boundary = forward.filter { $0.value == 1 }.count
        let outlineLength = 16.0
        let pieces = forward.filter { $0.value == 1 }.map(\.key).map { k -> Double in
            let a = m.points[Int(k >> 32)], b = m.points[Int(k & 0xFFFF_FFFF)]
            return simd_distance(a, b)
        }
        #expect(boundary > 4)
        #expect(abs(pieces.reduce(0, +) - outlineLength) < 1e-9)
        #expect(forward.values.allSatisfy { $0 <= 2 })
    }
}

@Suite("Texture export")
struct TextureExportTests {
    @Test func threeMFAndSTLCarryTheTexture() async throws {
        var o = TextureSamples.Options()
        o.diameter = 20; o.height = 12; o.pattern = .dots
        o.values = ["diameter": 4, "spacing": 7]
        let doc = try await TextureSamples.document(o)
        let model = await ModelEvaluator().evaluate(doc)
        let body = try #require(model.bodies.first)
        let meshes = try [body].printMeshes(quality: testQuality)
        let plain = try body.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)

        let xml = ThreeMFWriter.modelXML(objects: [(name: body.name, mesh: meshes[0])], preset: .bambuA1Mini, title: "Dots")
        let parsed = try ModelXML.parse(Data(xml.utf8))
        #expect(parsed.objects.count == 1)
        #expect(parsed.objects[0].triangleCount > plain.triangleCount * 4)
        // What the 3MF writer welds is closed.
        let (vertices, triangles) = ThreeMFWriter.weld(meshes[0])
        let check = MeshCheck.check(points: vertices.map { SIMD3<Double>($0) },
                                    triangles: triangles.map { SIMD3(Int32($0.0), Int32($0.1), Int32($0.2)) },
                                    selfIntersections: false)
        #expect(check.isWatertight, "\(check)")

        let stl = STLWriter.binary(meshes: meshes)
        #expect(stl.count == 84 + 50 * meshes[0].triangleCount)
    }
}
