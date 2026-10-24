import CoreGraphics
import Foundation
import simd

/// The app icon's drawing as screen-space geometry: an orthographic view of a
/// W×D×H box whose top-front edge (y = 0, z = H, running along x) is rounded.
///
/// Ported from `docs/icon/icon.py` (`Cam`, `Part`) and `docs/icon/flat.py`
/// (`Iso`), with the same eye direction and proportions, so the splash and the
/// icon are the same drawing. The one addition: the radius can vary along the
/// edge (`radius(x)` in 0…1 of the final radius), which is how the splash
/// shows the fillet being applied, one cross-section at a time.
struct SplashBlock {
    // World: x right, y back (depth), z up. Same numbers as `Iso()` in flat.py.
    static let width = 1.15
    static let depth = 0.8
    static let height = 0.72
    static let radius = 0.4
    private static let eye = SIMD3<Double>(-1.0, -0.78, 0.82)

    /// Cross-sections sampled along the edge.
    static let sections = 40
    /// Points per fillet arc.
    static let arcSegments = 24

    private let right: SIMD3<Double>
    private let up: SIMD3<Double>
    private let scale: Double
    private let origin: SIMD2<Double>
    private let center: CGPoint

    /// Projects the block so its silhouette is `drawingWidth` wide, centred on `center`.
    init(drawingWidth: Double, center: CGPoint) {
        let view = simd_normalize(Self.eye)
        let forward = -view
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        self.right = right
        self.up = up
        let raw = Self.corners.map { SIMD2(simd_dot($0, right), -simd_dot($0, up)) }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        scale = drawingWidth / (xs.max()! - xs.min()!)
        origin = SIMD2((xs.max()! + xs.min()!) / 2, (ys.max()! + ys.min()!) / 2)
        self.center = center
    }

    /// Height of the projected silhouette for a given drawing width.
    static func aspect() -> Double {
        let block = SplashBlock(drawingWidth: 1, center: .zero)
        let ys = corners.map { block.point($0).y }
        return ys.max()! - ys.min()!
    }

    private static var corners: [SIMD3<Double>] {
        [0, width].flatMap { x in [0, depth].flatMap { y in [0, height].map { z in SIMD3(x, y, z) } } }
    }

    func point(_ p: SIMD3<Double>) -> CGPoint {
        CGPoint(x: center.x + (simd_dot(p, right) - origin.x) * scale,
                y: center.y + (-simd_dot(p, up) - origin.y) * scale)
    }

    // MARK: Edges

    /// Fillet profile at `x` with world radius `r`, from the front face up to the top face.
    func arc(x: Double, r: Double) -> [CGPoint] {
        let h = Self.height
        return (0...Self.arcSegments).map { i in
            let phi = Double.pi / 2 * Double(i) / Double(Self.arcSegments)
            return point(SIMD3(x, r * (1 - cos(phi)), h - r + r * sin(phi)))
        }
    }

    /// The left face's outline, starting at the top-back corner and running down,
    /// forward, up the front edge and over the fillet profile at x = 0.
    func leftFaceLoop(r: Double) -> [CGPoint] {
        let (d, h) = (Self.depth, Self.height)
        return [point(SIMD3(0, d, h)), point(SIMD3(0, d, 0)), point(SIMD3(0, 0, 0)), point(SIMD3(0, 0, h - r))]
            + arc(x: 0, r: r) + [point(SIMD3(0, d, h))]
    }

    /// The silhouette from the bottom-front-left corner along the bottom, up the
    /// right end, over the fillet profile at x = W and back along the top.
    func silhouette(r: Double) -> [CGPoint] {
        let (w, d, h) = (Self.width, Self.depth, Self.height)
        return [point(SIMD3(0, 0, 0)), point(SIMD3(w, 0, 0)), point(SIMD3(w, 0, h - r))]
            + arc(x: w, r: r) + [point(SIMD3(w, d, h)), point(SIMD3(0, d, h))]
    }

    /// The three edges that meet at the hidden back-bottom-right corner, each
    /// running away from that corner (so they can be traced outward from it).
    func hiddenEdges() -> [[CGPoint]] {
        let (w, d, h) = (Self.width, Self.depth, Self.height)
        let corner = point(SIMD3(w, d, 0))
        return [[corner, point(SIMD3(w, d, h))], [corner, point(SIMD3(0, d, 0))], [corner, point(SIMD3(w, 0, 0))]]
    }

    // MARK: The fillet, cross-section by cross-section

    /// x of section `i`.
    static func sectionX(_ i: Int) -> Double { width * Double(i) / Double(sections) }

    /// Where the fillet meets the front face, along the whole edge, for per-section radii.
    func frontTangent(radii: [Double]) -> [CGPoint] {
        radii.indices.map { point(SIMD3(Self.sectionX($0), 0, Self.height - radii[$0])) }
    }

    /// Where the fillet meets the top face.
    func topTangent(radii: [Double]) -> [CGPoint] {
        radii.indices.map { point(SIMD3(Self.sectionX($0), radii[$0], Self.height)) }
    }

    /// The fillet surface as one region: thin strips between neighbouring
    /// cross-sections, all wound the same way so overlaps fill as a union.
    func filletSurface(radii: [Double]) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<(radii.count - 1) where max(radii[i], radii[i + 1]) > 0.0005 {
            let a = arc(x: Self.sectionX(i), r: radii[i])
            let b = arc(x: Self.sectionX(i + 1), r: radii[i + 1])
            path.addLines(between: a + b.reversed())
            path.closeSubpath()
        }
        return path
    }
}
