import CoreGraphics
import Foundation
import FilletKernel

/// Edges of the viewport covered by floating chrome (points): a toolbar along the top, a
/// floating sidebar on the leading side. Framing keeps content in the part that's left.
public struct ViewportInsets: Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }

    public static let zero = ViewportInsets()

    /// The unobstructed rectangle of a view of `size` (top-left origin). Insets never take
    /// more than 60 % of either dimension, so a tiny view still frames something.
    public func rect(in size: CGSize) -> CGRect {
        let w = Double(size.width), h = Double(size.height)
        func squeeze(_ a: Double, _ b: Double, limit: Double) -> (Double, Double) {
            let sum = max(a, 0) + max(b, 0)
            guard sum > limit, sum > 0 else { return (max(a, 0), max(b, 0)) }
            return (max(a, 0) * limit / sum, max(b, 0) * limit / sum)
        }
        let (l, r) = squeeze(leading, trailing, limit: w * 0.6)
        let (t, b) = squeeze(top, bottom, limit: h * 0.6)
        return CGRect(x: l, y: t, width: max(w - l - r, 1), height: max(h - t - b, 1))
    }
}

extension Camera {
    /// The screen rectangle (points, top-left origin) the corners of `bounds` project to.
    /// Nil when a corner is behind a perspective eye.
    public func screenRect(of bounds: Bounds3, viewSize: CGSize) -> CGRect? {
        var lo = CGPoint(x: Double.infinity, y: Double.infinity)
        var hi = CGPoint(x: -Double.infinity, y: -Double.infinity)
        for i in 0..<8 {
            let p = Vec3(i & 1 == 0 ? bounds.min.x : bounds.max.x,
                         i & 2 == 0 ? bounds.min.y : bounds.max.y,
                         i & 4 == 0 ? bounds.min.z : bounds.max.z)
            guard let s = project(p, viewSize: viewSize) else { return nil }
            lo = CGPoint(x: min(lo.x, s.x), y: min(lo.y, s.y))
            hi = CGPoint(x: max(hi.x, s.x), y: max(hi.y, s.y))
        }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    /// A copy that keeps the view direction and projection but moves and zooms so `bounds`
    /// fills the unobstructed part of the view (`margin` = breathing room, 1.2 leaves ~8 % on
    /// each side) and sits centred in it.
    ///
    /// The target moves off the content's centre when the insets are uneven, so the content
    /// lands in the middle of what's visible rather than the middle of the whole view.
    public func framing(_ bounds: Bounds3, viewSize: CGSize, insets: ViewportInsets = .zero,
                        margin: Double = 1.2) -> Camera {
        guard viewSize.width > 0, viewSize.height > 0 else { return fitted(to: bounds) }
        // Give flat or point-like content a little extent so the fit stays finite.
        let size = bounds.size
        let pad = Vec3(size.x < 1 ? 0.5 : 0, size.y < 1 ? 0.5 : 0, size.z < 1 ? 0.5 : 0)
        let b = Bounds3(min: bounds.min - pad, max: bounds.max + pad)
        let safe = insets.rect(in: viewSize)
        var c = self
        c.fit(bounds: b, aspect: Double(safe.width / safe.height), margin: margin)
        // Projected size scales with 1 / distance in both projections, so a few rounds of
        // "measure, rescale, recentre" converge quickly.
        for round in 0..<16 {
            guard let box = c.screenRect(of: b, viewSize: viewSize) else {
                c.distance = min(c.distance * 2, Self.distanceRange.upperBound)
                continue
            }
            // The last rounds only recentre, so the result is centred to well under a point.
            if round < 10 {
                let scale = max(Double(box.width / safe.width), Double(box.height / safe.height), 1e-6) * margin
                c.distance = min(max(c.distance * scale, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
            }
            guard let moved = c.screenRect(of: b, viewSize: viewSize) else { continue }
            let wpp = c.worldUnitsPerPoint(at: b.center, viewSize: viewSize)
            let dx = Double(moved.midX - safe.midX), dy = Double(moved.midY - safe.midY)
            c.target = c.target + c.right * (dx * wpp) - c.up * (dy * wpp)
        }
        return c
    }

    /// Whether `bounds` is inside the unobstructed rect and not far off its centre (the
    /// centre may drift by `tolerance` of the rect's size).
    public func frames(_ bounds: Bounds3, viewSize: CGSize, insets: ViewportInsets = .zero,
                       tolerance: Double = 0.12) -> Bool {
        guard let box = screenRect(of: bounds, viewSize: viewSize) else { return false }
        let safe = insets.rect(in: viewSize)
        let inside = box.minX >= safe.minX - 1 && box.maxX <= safe.maxX + 1 && box.minY >= safe.minY - 1 && box.maxY <= safe.maxY + 1
        let centred = abs(Double(box.midX - safe.midX)) <= Double(safe.width) * tolerance
            && abs(Double(box.midY - safe.midY)) <= Double(safe.height) * tolerance
        return inside && centred
    }
}
