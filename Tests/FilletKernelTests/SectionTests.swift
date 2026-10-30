import FilletKernel
import Foundation
import simd
import Testing

@Suite("Sections")
struct SectionTests {
    /// A 10 mm cube with a Ø6 bore down its middle, cut halfway up: the square outside and the
    /// bore's circle, every point on the plane.
    @Test func cubeWithABore() throws {
        let bore = try Shape.cylinder(base: Plane(origin: Vec3(5, 5, -1), normal: .unitZ, xDir: .unitX), radius: 3, height: 12)
        let part = try cube(10).cut(by: bore)
        let lines = try part.section(by: Plane(origin: Vec3(0, 0, 4), normal: .unitZ, xDir: .unitX), linearDeflection: 0.001, angularDeflection: 0.05)
        let points = lines.flatMap { $0 }
        #expect(!lines.isEmpty)
        for p in points { #expect(abs(p.z - 4) < 1e-5) }
        // The square: points on its sides; the bore: points on the circle, finely spaced.
        let onSquare = points.filter { abs($0.x) < 1e-5 || abs($0.x - 10) < 1e-5 || abs($0.y) < 1e-5 || abs($0.y - 10) < 1e-5 }
        let onCircle = points.filter { abs(simd_length(SIMD2($0.x - 5, $0.y - 5)) - 3) < 1e-4 }
        #expect(onSquare.count + onCircle.count == points.count)
        #expect(onCircle.count >= 2 * 60, "the bore's circle is drawn round, not as a few chords (\(onCircle.count) points)")
        // Sides of the square run corner to corner: 4 lines, 2 points each.
        #expect(lines.filter { $0.count == 2 }.count >= 4)
    }

    @Test func aPlaneThatMissesCutsNothing() throws {
        let lines = try cube(10).section(by: Plane(origin: Vec3(0, 0, 20), normal: .unitZ, xDir: .unitX))
        #expect(lines.isEmpty)
    }

    /// Tilted through a sphere: a circle of the right radius, wherever it is cut.
    @Test func tiltedThroughASphere() throws {
        let n = simd_normalize(SIMD3<Double>(1, 1, 1))
        let normal = Vec3(n.x, n.y, n.z)
        let plane = Plane(origin: normal * 2, normal: normal, xDir: Vec3(1, -1, 0).normalized)
        let lines = try Shape.sphere(center: .zero, radius: 5).section(by: plane, linearDeflection: 0.001, angularDeflection: 0.05)
        let r = (25.0 - 4).squareRoot()
        let points = lines.flatMap { $0 }
        #expect(points.count > 50)
        for p in points {
            let q = Vec3(Double(p.x), Double(p.y), Double(p.z))
            #expect(abs((q - plane.origin).dot(normal)) < 1e-3)
            #expect(abs((q - plane.origin).length - r) < 1e-3)
        }
    }
}
