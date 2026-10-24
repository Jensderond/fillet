import FilletKernel
import Foundation
import Testing

@testable import FilletCore

/// The six planar faces of an axis-aligned box from `lo` to `hi`.
func boxFaces(_ lo: Vec3, _ hi: Vec3) -> [FaceInfo] {
    let c = (lo + hi) / 2
    let s = hi - lo
    func face(_ n: Vec3, _ centroid: Vec3, _ area: Double) -> FaceInfo {
        // Flatten the bounds along the normal axis.
        var fmin = lo, fmax = hi
        if n.x != 0 { fmin.x = centroid.x; fmax.x = centroid.x }
        if n.y != 0 { fmin.y = centroid.y; fmax.y = centroid.y }
        if n.z != 0 { fmin.z = centroid.z; fmax.z = centroid.z }
        return FaceInfo(surface: .plane, centroid: centroid, normal: n, area: area, boundsMin: fmin, boundsMax: fmax)
    }
    return [
        face(Vec3(0, 0, -1), Vec3(c.x, c.y, lo.z), s.x * s.y),
        face(Vec3(0, 0, 1), Vec3(c.x, c.y, hi.z), s.x * s.y),
        face(Vec3(0, -1, 0), Vec3(c.x, lo.y, c.z), s.x * s.z),
        face(Vec3(0, 1, 0), Vec3(c.x, hi.y, c.z), s.x * s.z),
        face(Vec3(-1, 0, 0), Vec3(lo.x, c.y, c.z), s.y * s.z),
        face(Vec3(1, 0, 0), Vec3(hi.x, c.y, c.z), s.y * s.z),
    ]
}

func line(_ a: Vec3, _ b: Vec3) -> EdgeInfo {
    EdgeInfo(
        curve: .line, start: a, mid: (a + b) / 2, end: b, tangentAtMid: (b - a).normalized, length: a.distance(to: b),
        radius: 0)
}

@Suite("Persistent references")
struct ReferenceResolverTests {
    let box = boxFaces(.zero, Vec3(20, 20, 20))

    @Test func exactMatch() {
        for (i, f) in box.enumerated() {
            let m = ReferenceResolver.match(FaceSignature(f), in: box)
            #expect(m?.index == i)
            #expect(m?.score == 0)
            #expect(m?.isAmbiguous == false)
        }
    }

    @Test func survivesParameterTweak() {
        let top = FaceSignature(box[1])
        // Height 20 → 23 and width 20 → 22; faces reordered by the kernel.
        let tweaked = Array(boxFaces(.zero, Vec3(22, 20, 23)).reversed())
        let i = ReferenceResolver.resolve(top, in: tweaked)
        #expect(i.map { tweaked[$0].normal } == Vec3(0, 0, 1))
    }

    @Test func faceSplitPicksOneHalf() throws {
        let top = FaceSignature(box[1])
        // A slot cut across the top splits it into two 10×20 halves (minus the slot).
        var faces = box.filter { $0.normal != Vec3(0, 0, 1) }
        for x in [4.0, 16.0] {
            faces.append(
                FaceInfo(
                    surface: .plane, centroid: Vec3(x, 10, 20), normal: Vec3(0, 0, 1), area: 8 * 20,
                    boundsMin: Vec3(x - 4, 0, 20), boundsMax: Vec3(x + 4, 20, 20)))
        }
        let m = try #require(ReferenceResolver.match(top, in: faces))
        #expect(m.index >= faces.count - 2)
        #expect(m.isAmbiguous)
    }

    @Test func deletedFaceIsLost() {
        let top = FaceSignature(box[1])
        let withoutTop = box.filter { $0.normal != Vec3(0, 0, 1) }
        #expect(ReferenceResolver.resolve(top, in: withoutTop) == nil)
    }

    @Test func typeMustMatch() {
        var cylinderTop = box
        cylinderTop[1].surface = .cylinder
        #expect(ReferenceResolver.resolve(FaceSignature(box[1]), in: cylinderTop) == nil)
    }

    @Test func picksCloserOfTwoSimilarFaces() {
        // Two equal pads on a plate; reference the left pad's top face, then
        // the model shifts slightly.
        let left = FaceInfo(
            surface: .plane, centroid: Vec3(10, 10, 5), normal: .unitZ, area: 100, boundsMin: Vec3(5, 5, 5),
            boundsMax: Vec3(15, 15, 5))
        var right = left
        right.centroid = Vec3(40, 10, 5)
        right.boundsMin = Vec3(35, 5, 5)
        right.boundsMax = Vec3(45, 15, 5)
        let sig = FaceSignature(left)
        var movedLeft = left
        movedLeft.centroid = Vec3(12, 10, 5)
        let faces = [right, movedLeft]
        let m = ReferenceResolver.match(sig, in: faces)
        #expect(m?.index == 1)
        #expect(m?.isAmbiguous == false)
    }

    @Test func edgesTangentIsSignAgnostic() {
        let e = line(Vec3(0, 0, 20), Vec3(20, 0, 20))
        let reversed = line(Vec3(20, 0, 20), Vec3(0, 0, 20))
        let others = [line(Vec3(0, 0, 0), Vec3(20, 0, 0)), line(Vec3(0, 0, 0), Vec3(0, 0, 20))]
        let m = ReferenceResolver.match(EdgeSignature(e), in: others + [reversed])
        #expect(m?.index == 2)
        #expect(m.map { $0.score < 1e-12 } == true)
    }

    @Test func edgeMovedAndDeleted() {
        let top = line(Vec3(0, 20, 20), Vec3(20, 20, 20))
        let edges = [
            line(Vec3(0, 0, 0), Vec3(20, 0, 0)), line(Vec3(0, 0, 0), Vec3(0, 20, 0)),
            line(Vec3(0, 0, 0), Vec3(0, 0, 22)), line(Vec3(0, 20, 22), Vec3(20, 20, 22)),
        ]
        #expect(ReferenceResolver.resolve(EdgeSignature(top), in: edges) == 3)
        #expect(ReferenceResolver.resolve(EdgeSignature(top), in: Array(edges.prefix(3))) == nil)
    }

    @Test func circleRadiusMatters() {
        func circle(_ z: Double, _ r: Double) -> EdgeInfo {
            EdgeInfo(
                curve: .circle, start: Vec3(r, 0, z), mid: Vec3(-r, 0, z), end: Vec3(r, 0, z), tangentAtMid: Vec3(0, -1, 0),
                length: 2 * .pi * r, radius: r)
        }
        let hole = circle(10, 3)
        let candidates = [circle(10, 8), circle(10.5, 3.2)]
        #expect(ReferenceResolver.resolve(EdgeSignature(hole), in: candidates) == 1)
    }
}
