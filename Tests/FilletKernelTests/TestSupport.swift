import Foundation
import Testing
import simd
@testable import FilletKernel

/// |a - b| <= tol (absolute) or relative to |b|.
func close(_ a: Double, _ b: Double, rel: Double = 1e-6, abs tol: Double = 1e-9) -> Bool {
    Swift.abs(a - b) <= max(tol, rel * Swift.abs(b))
}

func p(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x, y) }

/// Rectangle as four line segments.
func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Segment2D] {
    [
        .line(p(x0, y0), p(x1, y0)), .line(p(x1, y0), p(x1, y1)),
        .line(p(x1, y1), p(x0, y1)), .line(p(x0, y1), p(x0, y0)),
    ]
}

func cube(_ size: Double = 10, at corner: Vec3 = .zero) throws -> Shape {
    try Shape.box(corner: corner, size: Vec3(size, size, size))
}

/// Index of the first edge satisfying the predicate.
func edgeIndex(_ shape: Shape, where predicate: (EdgeInfo) -> Bool) -> Int? {
    (0..<shape.edgeCount).first { predicate(shape.edgeInfo($0)) }
}

func faceIndex(_ shape: Shape, where predicate: (FaceInfo) -> Bool) -> Int? {
    (0..<shape.faceCount).first { predicate(shape.faceInfo($0)) }
}

/// Region areas sorted ascending.
func sortedAreas(_ r: SketchRegions) -> [Double] { (0..<r.count).map { r.area($0) }.sorted() }

/// Runs `body` and expects it to throw a KernelError (optionally containing `fragment`).
func expectKernelError(
    _ fragment: String? = nil, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("Expected a KernelError", sourceLocation: sourceLocation)
    } catch let e as KernelError {
        #expect(!e.message.isEmpty, sourceLocation: sourceLocation)
        if let fragment {
            #expect(
                e.message.localizedCaseInsensitiveContains(fragment), "message: \(e.message)",
                sourceLocation: sourceLocation)
        }
    } catch {
        Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FilletKernelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
