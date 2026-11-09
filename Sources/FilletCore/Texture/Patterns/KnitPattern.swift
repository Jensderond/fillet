import Foundation

/// Stockinette knitting: columns of V-shaped stitches stacked straight up, each V two slanted
/// strands of yarn.
///
/// Each leg is a plump leaf of yarn with a round cross-section: fullest in the middle and tapering
/// to slim, still round, ends. Its height follows its thickness, so the strand stays round as it
/// narrows and no end is ever a knife edge. Its centre line is a gentle S: steep at both ends and
/// leaning out in the middle, like a strand pulled into a loop. The two legs of a V meet at the
/// bottom on the column's centre line and spread out to the column's edges at the top, where they
/// meet the legs of the neighbouring columns. A leg is about two rows long: its tapered lower end
/// lies in front of the row below, and its top end dips behind the bottom of the stitch above, as
/// the loop pulled through does in real knitting. The crevices between the leaves sink well below
/// the surface, so the stitches read at a glance. Where leaves press together the crease is
/// rounded a little, and where one meets the surface beneath it its foot is filleted, so the mesh
/// never shows a cliff or a burr.
///
/// On a face that turns all the way around (a vase, a bowl) a whole number of rows is fitted
/// between the face's bottom and top edges, so every row is complete, and the stitches settle into
/// the surface near those edges (or, with "Cut at edges", keep their full depth up to them, like a
/// knitted piece cut off by the bed and the rim). Straight walls that meet smoothly all the way
/// around (an extruded heart) count as one such face. A narrow rounded rim is finished as a
/// bound-off edge: a twisted rope of yarn, two strands per stitch.
public struct KnitPattern: TexturePattern {
    public static let id: TexturePatternID = .knit
    public static let displayName = "Knit"
    public static let summary = "Columns of knitted V stitches, like a stockinette sweater."
    public static let symbol = "chevron.down"
    public static let parameters: [TextureParameter] = [
        .length("stitchWidth", "Stitch width", default: 8, range: 1...40, help: "Width of one stitch (one V) around the face"),
        .length("stitchHeight", "Stitch height", default: 7, range: 1...40, help: "Height of one row of stitches"),
        .length("depth", "Depth", default: 1.8, range: 0.05...8, help: "How far the yarn stands out"),
        .number("yarn", "Yarn thickness", default: 1, range: 0.6...1.4,
                help: "Thickness of the yarn relative to the stitch: below 1 leaves more space between the legs"),
        .toggle("raised", "Raised", default: true, help: "Stitches stand out from the surface (off: cut into it)"),
        .toggle("cutEdges", "Cut at edges", default: false,
                help: "Stitches keep their full depth right up to the face's bottom and top edges, cut off there like the edge of a knitted piece, instead of settling into the surface"),
    ]

    public let width: Double
    public private(set) var rowHeight: Double
    public let depth: Double
    public let yarn: Double
    public let raised: Bool
    /// Stitches run at full depth to the bottom and top edges instead of settling (see `height`).
    public let cutEdges: Bool
    /// v of the first row boundary (rows start every `rowHeight` from here).
    private var rowOrigin = 0.0
    /// Length in v of the face the pattern is fitted to, when it goes all the way around: the
    /// stitches settle into the surface within a short distance of its bottom and top edges, so
    /// they meet a rounded rim or a neighbouring face cleanly.
    private var faceLength: Double?
    /// Width in v of a narrow band all the way around (a rounded rim), which is finished with one
    /// rope (a bound-off edge) instead of stitches that would not fit on it.
    private var beadWidth: Double?

    /// The right leg in stitch-local millimetres (stitch centre at the origin, x across, y up);
    /// the left leg is its mirror image. Its centre line runs from (`x0`, `y0`) at the bottom to
    /// (`x0 + dx`, `y0 + dy`) at the top, bowed outwards (see `bow`).
    private var x0 = 0.0, y0 = 0.0, dx = 1.0, dy = 1.0
    /// Half the yarn's thickness at its plumpest.
    private var radius = 1.0

    /// Depth of the crevices between the leaves, as a fraction of `depth` below the surface.
    private static let pocket = 0.9
    /// How much the centre line bends: its slope is (1 + bow) times the average at both ends
    /// and (1 − bow) in the middle. Negative: the leg leaves the V's point steeply, leans out in
    /// the middle and turns up again at the column's edge at the top, a gentle S.
    private static let bow = -0.25
    /// Thickness at the ends, as a fraction of the plumpest: a leaf, not a tube.
    private static let endThickness = 0.25
    /// Exponent on the leaf's thickness profile (sin along its length): below 1 keeps it full
    /// over most of its length and tapers it near the ends.
    private static let fullPow = 0.6
    /// Half the leaf's plumpest thickness across (measured horizontally), as a fraction of the
    /// stitch width: two leaves side by side just fill a column and press together.
    private static let radiusFactor = 0.24
    /// How far the leg reaches below and above the stitch centre, in rows.
    private static let reach = 1.0
    /// How much lower the top end lies (passing behind the stitch above), as a fraction.
    private static let topDip = 0.3
    /// How much lower the bottom end lies (sinking into the opening under the V's point).
    private static let bottomSink = 0.15
    /// Shape of the yarn's cross-section: a circular arc whose centre sits this far (in tube
    /// radii) below the floor. 0 would be a half circle with vertical sides; larger is flatter.
    private static let sectionDrop = 0.3
    private static let sectionNorm = (1 + sectionDrop * sectionDrop).squareRoot() - sectionDrop
    /// How far the bottom end's cap is drawn out downwards, in cap radii.
    private static let bottomRamp = 3.0
    /// Height (in tube heights) over which a tube's foot is rounded into what lies beneath it.
    private static let fillet = 0.3
    /// Height over which the crease between two tubes pressing together is rounded.
    private static let crease = 0.3
    /// The rim's rope: how many strand widths a strand shifts from one edge of the rim to the
    /// other (its twist), how far it stands out (times `depth`) and how deep the grooves between
    /// strands are (as a fraction of that).
    private static let ropeSlant = 2.2
    private static let ropeHeight = 0.5
    private static let ropeFloor = 0.35

    public init(_ values: TextureValues) {
        width = values["stitchWidth"]
        rowHeight = values["stitchHeight"]
        depth = values["depth"]
        yarn = values["yarn"] == 0 ? 1 : values["yarn"]
        raised = values.bool("raised")
        cutEdges = values.bool("cutEdges")
        layOutLegs()
    }

    private mutating func layOutLegs() {
        // Bottom end just off the column's centre line, a row below the stitch centre; top end at
        // the column's edge, a row up (behind the next row's bottom).
        x0 = 0.02 * width
        y0 = -Self.reach * rowHeight
        dx = 0.5 * width - x0
        dy = Self.reach * rowHeight - y0
        // Two legs side by side fill a column, so neighbours press together.
        let cosSlant = dy / (dx * dx + dy * dy).squareRoot()
        radius = Self.radiusFactor * width * cosSlant * yarn
    }

    public var cell: SIMD2<Double> { SIMD2(width, rowHeight) }
    public var amplitude: Double { depth * (1 + Self.pocket) }
    public var detail: Double { max(min(width, rowHeight) / Self.detailDivisor, 0.08) }
    /// Triangle size: about a twelfth of the stitch, finer (`steepDetail`) along the leaves'
    /// flanks. A 160 mm bowl stays under a million triangles, the most Bambu Studio slices
    /// without warning that the model is slow to process.
    private static let detailDivisor = 12.0
    private static let steepDetail = 0.65

    public func detail(at p: SIMD2<Double>) -> Double {
        // Finer along the steep sides of the tubes, where a tube's flank meets the crevice or
        // another tube: coarse triangles there would leave a saw-tooth outline.
        guard beadWidth == nil else { return detail * 0.7 }
        let (a, b) = topTwo(p)
        let steep = (0.62...1.3).contains(a.q) || (b.value > a.value - 0.35 && (0.62...1.3).contains(b.q))
        return steep ? detail * Self.steepDetail : detail
    }

    public func fitted(to extent: SIMD2<Double>?, wraps: Bool) -> any TexturePattern {
        guard wraps, let extent, extent.y > 0 else { return self }
        var out = self
        if extent.y < rowHeight * 1.3 {
            // Too narrow for rows of stitches: a rounded rim, finished as a bound-off edge.
            out.beadWidth = extent.y
            return out
        }
        // Around a vase or bowl: a whole number of rows from the bottom edge to the top one, so
        // every row is complete.
        let rows = max(1, (extent.y / rowHeight).rounded())
        out.rowHeight = extent.y / rows
        out.rowOrigin = 0
        out.faceLength = extent.y
        out.layOutLegs()
        return out
    }

    public func height(at p: SIMD2<Double>) -> Double {
        if let band = beadWidth { return bead(p, band: band) }
        let (a, b) = topTwo(p)
        let first = a.value, second = b.value
        // Tubes pressing together: the crease between the two highest is rounded a little (only
        // those two take part, so where several meet the rounding never piles up into a burr).
        // Then each foot is filleted into the floor.
        let h = Self.smoothMax(Self.smoothMax(first, second, k: Self.crease), 0, k: Self.fillet)
        // Crevices between the tubes sink below the surface.
        var m = (1 + Self.pocket) * h - Self.pocket
        if let length = faceLength, !cutEdges {
            // The stitches settle into the surface at the bottom and top edges, where they meet
            // the base or a rim (finished as a rope, see `bead`). Over a longer stretch at the
            // bottom, so yarn pushed outwards near a base on the bed never reaches below it.
            let e = min(p.y / (0.7 * rowHeight), (length - p.y) / (0.35 * rowHeight))
            if e < 1 { m *= e <= 0 ? 0 : e * e * (3 - 2 * e) }
        }
        return raised ? m * depth : (m - 1) * depth
    }

    /// A rounded rim `band` wide: a twisted rope all the way around, standing a little
    /// proud along the middle of the band and meeting the surface smoothly at both edges.
    private func bead(_ p: SIMD2<Double>, band: Double) -> Double {
        let c = max(0, min(1, p.y / band))
        let e = min(c, 1 - c) / 0.22
        let ease = e >= 1 ? 1 : e * e * (3 - 2 * e)
        // A bound-off edge: a twisted rope of slanted strands, two per stitch.
        let strands = 2.0
        let phase = p.x * strands / width + Self.ropeSlant * (c - 0.5)
        // The groove between strands is rounded off a little, so it doesn't alias into a saw-tooth.
        let t = sin(.pi * (phase - phase.rounded(.down)))
        let soft = 0.06
        let lobe = pow(((t * t + soft).squareRoot() - soft.squareRoot()) / ((1 + soft).squareRoot() - soft.squareRoot()), 0.7)
        let m = Self.ropeHeight * ease * (Self.ropeFloor + (1 - Self.ropeFloor) * lobe)
        return raised ? m * depth : (m - 1) * depth
    }

    /// The two highest leg values at `p` (see `leg`), over the legs of the nine stitches around
    /// it. Legs that are too far away to matter count as −1.
    private func topTwo(_ p: SIMD2<Double>) -> (LegSample, LegSample) {
        let y = p.y - rowOrigin
        let ci = (p.x / width).rounded(.down), cj = (y / rowHeight).rounded(.down)
        let none = LegSample(value: -1, q: .infinity)
        var a = none, b = none
        for dj in -1...1 {
            for di in -1...1 {
                let centre = SIMD2((ci + Double(di) + 0.5) * width, (cj + Double(dj) + 0.5) * rowHeight)
                let local = SIMD2(p.x, y) - centre
                for h in [leg(local), leg(SIMD2(-local.x, local.y))] where h.value > b.value {
                    if h.value > a.value { b = a; a = h } else { b = h }
                }
            }
        }
        return (a, b)
    }

    /// The right leg at `local`: its height (1 on the plumpest part's crest) where it covers the
    /// point, negative just outside its foot (the round section continued below the floor, so
    /// the fillet in `height` has something to blend), and −1 well away from it.
    private struct LegSample {
        /// Height, see `leg`.
        var value: Double
        /// Distance from the leg's centre line in (local) tube radii.
        var q: Double
    }

    private func leg(_ local: SIMD2<Double>) -> LegSample {
        let s = (local.y - y0) / dy
        let sc = max(0, min(1, s))
        // Centre line, a gentle S: x = x0 + dx·g(s) with g(s) = s + bow·sin(2πs)/2π.
        let g = sc + Self.bow * sin(2 * .pi * sc) / (2 * .pi)
        let slope = dx * (1 + Self.bow * cos(2 * .pi * sc)) / dy
        let cx = x0 + dx * g
        let ox = local.x - cx
        let dist: Double
        if s >= 0 && s <= 1 {
            dist = abs(ox) / (1 + slope * slope).squareRoot()
        } else {
            // Past an end: a round cap. The bottom one is drawn out downwards into a gentle
            // ramp, so the underside of the V never faces straight down where the face
            // overhangs (the lower part of a bowl), which would print as a floating island.
            let oy = (local.y - (y0 + dy * sc)) / (s < 0 ? Self.bottomRamp : 1)
            dist = (ox * ox + oy * oy).squareRoot()
        }
        // Thickness: plumpest a little below the middle, thinner towards both ends.
        let e = Self.endThickness
        let fullness = pow(sin(.pi * pow(sc, 0.85)), Self.fullPow)
        let r = radius * (e + (1 - e) * fullness)
        let q = dist / r
        let k = Self.sectionDrop
        let r2 = 1 + k * k - q * q
        guard r2 > 0 else { return LegSample(value: -1, q: q) }
        // Height follows thickness, so the section stays round as the leg narrows; the top end
        // also dips a little more, passing behind the stitch above.
        // The bottom end sinks a little too, into the opening under the V's point.
        let dip = sc <= 0.35 ? 0 : (sc - 0.35) / 0.65
        let sink = sc >= 0.3 ? 0 : 1 - sc / 0.3
        let scale = (r / radius) * (1 - Self.topDip * dip * dip * (3 - 2 * dip)) * (1 - Self.bottomSink * sink * sink)
        let arc = (r2.squareRoot() - k) / Self.sectionNorm
        return LegSample(value: max(arc * scale, -1), q: q)
    }

    /// Maximum of `a` and `b` with the crease between them rounded over `k`.
    private static func smoothMax(_ a: Double, _ b: Double, k: Double) -> Double {
        let h = max(k - abs(a - b), 0) / k
        return max(a, b) + h * h * k / 4
    }
}
