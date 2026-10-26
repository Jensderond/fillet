import FilletKernel
import Foundation
import Testing

@testable import FilletCore

/// Fillets and chamfers with "Tangent chain": the pick is a seed, its chain is found on every recompute.
@Suite("Tangent chain fillets")
struct TangentChainTests {
    let boxID = UUID()
    let cornersID = UUID()
    let topID = UUID()

    /// A 40 × 20 × `height` box with `corners` of its vertical edges rounded (r = 3), the
    /// right-hand ones first, then a fillet whose one pick is the top edge on the right-hand side.
    func document(corners: Int) async throws -> (Document, EvaluatedModel) {
        var doc = Document()
        doc.parameters = [Parameter(name: "height", expression: 10)]
        doc.features = [Feature(id: boxID, name: "Box 1", .primitive(Primitive(kind: .box, dimensions: [40, 20, "height"])))]
        let model = await ModelEvaluator().evaluate(doc)
        let body = try #require(model.bodies.first)
        let shape = body.shape
        let bounds = try #require(shape.bounds)
        let vertical = shape.edgeInfos.indices.filter { abs(shape.edgeInfos[$0].tangentAtMid.z) > 0.99 }
            .sorted { shape.edgeInfos[$0].mid.x > shape.edgeInfos[$1].mid.x }
        #expect(vertical.count == 4)
        let refs = try vertical.prefix(corners).map { try #require(model.edgeRef(body: body.ref, edge: $0)) }
        doc.features.append(Feature(id: cornersID, name: "Fillet 1", .fillet(EdgeFeature(body: body.ref, edges: refs, size: 3))))
        let seed = try #require(shape.edgeInfos.indices.first { i in
            let e = shape.edgeInfos[i]
            return abs(e.mid.x - bounds.max.x) < 1e-6 && abs(e.mid.z - bounds.max.z) < 1e-6
        })
        let seedRef = try #require(model.edgeRef(body: body.ref, edge: seed))
        doc.features.append(Feature(id: topID, name: "Fillet 2",
                                    .fillet(EdgeFeature(body: body.ref, edges: [seedRef], size: 1, tangentChain: true))))
        return (doc, await ModelEvaluator().evaluate(doc, before: topID))
    }

    /// Whether every edge lies on the top of the body the step works on.
    func onTop(_ edges: [EdgeInfo], _ model: EvaluatedModel) -> Bool {
        guard let top = model.bodiesBefore?.first?.shape.bounds?.max.z else { return false }
        return edges.allSatisfy { abs($0.start.z - top) < 1e-6 && abs($0.mid.z - top) < 1e-6 && abs($0.end.z - top) < 1e-6 }
    }

    @Test func oneSeedRoundsTheWholeTopOutline() async throws {
        let (_, model) = try await document(corners: 4)
        #expect(model.status[topID] == .ok)
        let edges = try #require(model.resolvedEdges[topID])
        // Four lines and four arcs, all on the top.
        #expect(edges.count == 8)
        #expect(edges.filter { $0.curve == .circle }.count == 4)
        #expect(onTop(edges, model))
        // One reference: the seed.
        #expect(model.references[topID]?.count == 1)
    }

    @Test func chainGrowsWhenTheCornersBeforeItChange() async throws {
        var (doc, model) = try await document(corners: 2)
        // Two rounded corners on the right: the chain runs along the right side, both arcs, the front
        // and the back, and stops at the sharp left corners.
        #expect(model.status[topID] == .ok)
        #expect(model.resolvedEdges[topID]?.count == 5)

        // Round all four corners in the step before: the same seed now chains around the whole top.
        let evaluator = ModelEvaluator()
        let box = try #require(await evaluator.evaluate(doc, before: cornersID).bodiesBefore?.first?.shape)
        let refs = box.edgeInfos.indices.filter { abs(box.edgeInfos[$0].tangentAtMid.z) > 0.99 }
            .map { EdgeRef(body: BodyRef(boxID), signature: EdgeSignature(box.edgeInfo($0))) }
        guard case .fillet(var corners) = doc.features[1].kind else { Issue.record("expected a fillet"); return }
        corners.edges = refs
        doc.features[1].kind = .fillet(corners)
        model = await evaluator.evaluate(doc, before: topID)
        #expect(model.status[topID] == .ok)
        #expect(model.resolvedEdges[topID]?.count == 8)

        // A taller box: the chain moves up with it. (Not so much taller that the seed's old height
        // is nearer the bottom edge, which the reference would then find instead.)
        doc.parameters[0].expression = 14
        model = await evaluator.evaluate(doc, before: topID)
        #expect(model.status[topID] == .ok)
        let taller = try #require(model.resolvedEdges[topID])
        #expect(taller.count == 8)
        #expect(onTop(taller, model))
    }

    @Test func withoutTheChainOnlyThePickIsRounded() async throws {
        var (doc, _) = try await document(corners: 4)
        guard case .fillet(var top) = doc.features[2].kind else { Issue.record("expected a fillet"); return }
        top.tangentChain = false
        doc.features[2].kind = .fillet(top)
        let model = await ModelEvaluator().evaluate(doc)
        #expect(model.status[topID] == .ok)
        #expect(model.resolvedEdges[topID]?.count == 1)
    }

    @Test func expandedEdgesKeepPickOrderWithoutRepeats() throws {
        let box = try Shape.box(corner: .zero, size: Vec3(10, 10, 10))
        let rounded = try box.filleted(edges: box.edgeInfos.indices.filter { abs(box.edgeInfos[$0].tangentAtMid.z) > 0.99 }, radius: 2)
        let top = rounded.edgeInfos.indices.filter { i in
            let e = rounded.edgeInfos[i]
            return abs(e.start.z - 10) < 1e-6 && abs(e.mid.z - 10) < 1e-6 && abs(e.end.z - 10) < 1e-6
        }
        #expect(top.count == 8)
        var f = EdgeFeature(body: BodyRef(UUID()), edges: [], size: 1, tangentChain: true)
        // Two picks on the same chain and one that wasn't found: the chain once, from the first pick.
        let expanded = f.expandedEdges([top[3], nil, top[0]], on: rounded)
        #expect(Set(expanded) == Set(top) && expanded.count == top.count)
        f.tangentChain = false
        #expect(f.expandedEdges([top[3], nil, top[3], top[0]], on: rounded) == [top[3], top[0]])
    }

    /// Files from before the setting load as plain picks and save as they were.
    @Test func olderFilesLoadAndSaveUnchanged() throws {
        let body = BodyRef(UUID())
        let edge = EdgeRef(body: body, signature: EdgeSignature(
            curve: .line, start: .zero, mid: Vec3(1, 2, 3), end: Vec3(2, 4, 6), tangent: .unitX, length: 4, radius: 0))
        let plain = Feature(name: "Fillet", .fillet(EdgeFeature(body: body, edges: [edge], size: 2)))
        let json = try JSONEncoder().encode(plain)
        #expect(!String(decoding: json, as: UTF8.self).contains("tangentChain"))
        let decoded = try JSONDecoder().decode(Feature.self, from: json)
        guard case .fillet(let f) = decoded.kind else { Issue.record("expected a fillet"); return }
        #expect(!f.tangentChain)
        #expect(decoded == plain)

        let chained = Feature(name: "Chamfer", .chamfer(EdgeFeature(body: body, edges: [edge], size: 2, tangentChain: true)))
        let back = try JSONDecoder().decode(Feature.self, from: JSONEncoder().encode(chained))
        guard case .chamfer(let c) = back.kind else { Issue.record("expected a chamfer"); return }
        #expect(c.tangentChain)
        #expect(back == chained)
    }
}
