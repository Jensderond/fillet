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

    @Test(arguments: [TexturePatternID.knit, .dots])
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
