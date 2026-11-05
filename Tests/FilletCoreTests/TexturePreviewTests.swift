import FilletCore
import FilletKernel
import Foundation
import Testing

/// The viewport's textured mesh follows every value of a texture step being edited, on the same
/// evaluator the window keeps (so its caches are in play), not only on a fresh one.
@Suite("Texture preview")
struct TexturePreviewTests {
    private func profileDocument(_ profile: Int, on doc: Document) -> Document {
        var d = doc
        guard let i = d.features.firstIndex(where: { if case .texture = $0.kind { true } else { false } }),
              case .texture(var t) = d.features[i].kind else { return d }
        t.values["profile"] = Expr(Double(profile))
        d.features[i].kind = .texture(t)
        return d
    }

    /// How far the relief stands out, order-independent (the engine may number points
    /// differently from run to run): the mean and largest distance from the vase's axis.
    private func relief(_ m: Mesh) -> (mean: Double, max: Double) {
        let r = m.positions.map { Double(($0.x * $0.x + $0.y * $0.y).squareRoot()) }
        return (r.reduce(0, +) / Double(max(r.count, 1)), r.max() ?? 0)
    }

    @Test func switchingTheDotProfileChangesTheShownMesh() async throws {
        var o = TextureSamples.Options()
        o.base = .vase; o.diameter = 60; o.height = 80; o.shell = 2; o.pattern = .dots
        let base = try await TextureSamples.document(o)
        let evaluator = ModelEvaluator()
        var shown: [Int: (mean: Double, max: Double)] = [:]
        // Flat disc, soft dome, round cap, then back to the flat disc (the order a user clicks tiles).
        for profile in [2, 0, 1, 2] {
            let model = await evaluator.evaluate(profileDocument(profile, on: base))
            let body = try #require(model.bodies.first)
            #expect(body.textures.first?.values.int("profile") == profile)
            let r = relief(try #require(model.meshes[body.ref]))
            if let earlier = shown[profile] {
                #expect(abs(earlier.mean - r.mean) < 0.01 && abs(earlier.max - r.max) < 0.01, "profile \(profile) came back different")
            }
            shown[profile] = r
            // The same as a fresh evaluator makes it: nothing stale is served from a cache.
            let fresh = await ModelEvaluator().evaluate(profileDocument(profile, on: base))
            let f = relief(try #require(fresh.meshes[body.ref]))
            #expect(abs(f.mean - r.mean) < 0.01 && abs(f.max - r.max) < 0.01, "profile \(profile) differs from a fresh evaluation")
        }
        let profiles = shown.keys.sorted()
        for a in profiles {
            for b in profiles where b > a {
                #expect(abs(shown[a]!.mean - shown[b]!.mean) > 0.01, "profiles \(a) and \(b) show the same relief")
            }
        }
    }
}
