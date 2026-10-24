import FilletKernel
import Foundation
import simd

/// Result of matching a stored signature against the faces/edges of a recomputed shape.
public struct ReferenceMatch: Hashable, Sendable {
    /// Index of the best face/edge in the candidate list.
    public var index: Int
    /// Lower is better; 0 is a perfect match.
    public var score: Double
    /// True when another candidate scored almost as well (e.g. after a face
    /// split in two equal halves). The best one is still returned.
    public var isAmbiguous: Bool
}

/// Resolves persistent face/edge references by geometric similarity.
///
/// Score = normalised centroid distance + orientation mismatch + size
/// mismatch. The type (plane/cylinder/…, line/circle/…) must be equal.
/// Distances are divided by the model size (bounding-box diagonal of all
/// candidates) so the tolerance is scale independent.
///
/// Weights, tuned so that a parameter tweak or a face split still matches but
/// a face pointing another way (orthogonal normal alone scores 2) is rejected:
/// - distance: `4 × d / modelSize` (a quarter of the model costs 1)
/// - planar normal: `2 × (1 − n·n₀)`; other surfaces `0.5 × (1 − n·n₀)`
/// - line tangent: `2 × (1 − |t·t₀|)` (sign agnostic); other curves `0.5 ×`
/// - size: `0.5 × |ln(area/area₀)|`, `0.5 × |ln(len/len₀)|`, radius `1 × |ln(r/r₀)|`
public enum ReferenceResolver {
    /// Matches scoring above this are rejected ("reference lost").
    public static let tolerance = 1.5
    /// Two scores closer than this make the match ambiguous.
    public static let ambiguityMargin = 0.05

    // MARK: Faces

    /// Index of the face best matching `signature`, or nil when none is close enough.
    public static func resolve(_ signature: FaceSignature, in faces: [FaceInfo]) -> Int? {
        match(signature, in: faces)?.index
    }

    /// Best match with score and ambiguity, or nil when none is within ``tolerance``.
    public static func match(_ signature: FaceSignature, in faces: [FaceInfo]) -> ReferenceMatch? {
        var points: [Vec3] = []
        for f in faces { points.append(f.boundsMin); points.append(f.boundsMax) }
        let size = modelSize(points, fallback: signature.extent.length)
        return best(faces.indices.map { i in
            faces[i].surface == signature.surface ? score(signature, faces[i], modelSize: size) : nil
        })
    }

    /// Dissimilarity of a face to a signature (ignoring type).
    public static func score(_ s: FaceSignature, _ f: FaceInfo, modelSize: Double) -> Double {
        let distance = 4 * s.centroid.distance(to: f.centroid) / modelSize
        let alignment = s.normal.normalized.dot(f.normal.normalized)
        let normal = (s.surface == .plane ? 2.0 : 0.5) * (1 - alignment)
        let area = 0.5 * logRatio(s.area, f.area)
        return distance + normal + area
    }

    // MARK: Edges

    /// Index of the edge best matching `signature`, or nil when none is close enough.
    public static func resolve(_ signature: EdgeSignature, in edges: [EdgeInfo]) -> Int? {
        match(signature, in: edges)?.index
    }

    /// Best match with score and ambiguity, or nil when none is within ``tolerance``.
    public static func match(_ signature: EdgeSignature, in edges: [EdgeInfo]) -> ReferenceMatch? {
        var points: [Vec3] = []
        for e in edges { points += [e.start, e.mid, e.end] }
        let size = modelSize(points, fallback: signature.length)
        return best(edges.indices.map { i in
            edges[i].curve == signature.curve ? score(signature, edges[i], modelSize: size) : nil
        })
    }

    /// Dissimilarity of an edge to a signature (ignoring type).
    public static func score(_ s: EdgeSignature, _ e: EdgeInfo, modelSize: Double) -> Double {
        let distance = 4 * s.mid.distance(to: e.mid) / modelSize
        let alignment = abs(s.tangent.normalized.dot(e.tangentAtMid.normalized))
        let tangent = (s.curve == .line ? 2.0 : 0.5) * (1 - alignment)
        let length = 0.5 * logRatio(s.length, e.length)
        let radius = s.curve == .circle ? logRatio(s.radius, e.radius) : 0
        return distance + tangent + length + radius
    }

    // MARK: Helpers

    private static func best(_ scores: [Double?]) -> ReferenceMatch? {
        var bestIndex: Int?
        var bestScore = Double.infinity
        var second = Double.infinity
        for (i, s) in scores.enumerated() {
            guard let s, s.isFinite else { continue }
            if s < bestScore {
                second = bestScore
                bestScore = s
                bestIndex = i
            } else if s < second {
                second = s
            }
        }
        guard let bestIndex, bestScore <= tolerance else { return nil }
        return ReferenceMatch(index: bestIndex, score: bestScore, isAmbiguous: second - bestScore < ambiguityMargin)
    }

    /// Bounding-box diagonal of the points, at least 1 mm.
    private static func modelSize(_ points: [Vec3], fallback: Double) -> Double {
        guard var lo = points.first?.simd else { return max(fallback, 1) }
        var hi = lo
        for p in points { lo = simd_min(lo, p.simd); hi = simd_max(hi, p.simd) }
        return max(simd_length(hi - lo), 1)
    }

    /// |ln(a/b)| with guards for zero/negative sizes.
    private static func logRatio(_ a: Double, _ b: Double) -> Double {
        let eps = 1e-9
        return abs(log(max(a, eps) / max(b, eps)))
    }
}
