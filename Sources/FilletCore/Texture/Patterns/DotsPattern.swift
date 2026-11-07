import Foundation

/// A few round dots with plain surface between them, in straight or staggered rows.
///
/// The default is a flat disc: a round plate of even height standing straight out of the wall,
/// with a small round on its top edge and a sharp foot, like a coin set on the surface. Its top
/// follows the surface (on a cylinder it is the wall moved out by the height, no dome), its side
/// is straight along the disc's own axis, and seen straight on it is a true circle. Soft domes
/// and round caps are there as other profiles.
///
/// Dots sit on a grid of `spacing` along a row and `rowSpacing` between rows; staggered rows
/// shift every other row by half a spacing. Around a closed face (a cylinder) the dots are spaced
/// evenly so a whole number fits, without stretching them. On a face with known extent the rows
/// are centred on the face and, with "Whole dots only", dots its edges would cut are left out, so
/// a vase gets complete dots with a plain band at the rim and foot instead of half dots. Without
/// it, dots run off the textured surface's outer edges (cut there), but still never across a
/// seam where two textured faces meet smoothly (a fillet and the wall beside it): each face lays
/// its dots out on its own, so one there would be cut in two, with a step, under its neighbour's.
public struct DotsPattern: TexturePattern {
    public static let id: TexturePatternID = .dots
    public static let displayName = "Dots"
    public static let summary = "Round dots with plain space between them: flat raised discs, domes, or dimples."
    public static let symbol = "circle.grid.3x3"
    public static let parameters: [TextureParameter] = [
        .length("diameter", "Dot diameter", default: 20, range: 0.5...150,
                help: "Diameter of each dot where it meets the surface"),
        .length("spacing", "Spacing", default: 32, range: 1...400,
                help: "Distance between dot centres along a row (around a vase: evened out so a whole number fits)"),
        .length("rowSpacing", "Row spacing", default: 30, range: 1...400,
                help: "Distance between the centres of neighbouring rows"),
        .length("height", "Height", default: 1, range: 0.05...30, help: "How far each dot stands out or cuts in"),
        .choice("profile", "Profile", ["Soft dome", "Round cap", "Flat disc"], default: 2,
                help: "Flat disc: a flat-topped disc with a straight side; round cap: a low cap with a crisp foot; soft dome: blends into the surface"),
        .length("edge", "Edge round", default: 0.3, range: 0...10,
                help: "Radius of the round on a flat disc's top edge"),
        .toggle("raised", "Raised", default: true, help: "Raised dots (off: recessed)"),
        .toggle("stagger", "Staggered rows", default: true, help: "Shift every other row by half a spacing"),
        .toggle("whole", "Whole dots only", default: true,
                help: "Centre the dots on each face and leave out any its edges would cut (off: dots run off the textured area's outer edges)"),
    ]

    public enum Profile: Int, Sendable { case dome = 0, cap = 1, flat = 2 }

    public let diameter: Double
    public let spacing: Double
    public let rowPitch: Double
    public let dotHeight: Double
    public let profile: Profile
    public let raised: Bool
    public let stagger: Bool
    public let whole: Bool
    let disc: Disc

    /// Grid origin: the centre of the dot in row 0, column 0.
    var origin = SIMD2<Double>(0, 0)
    /// Distance between dot centres along a row as laid out (evened out around a closed face).
    var pitch: Double
    /// Rows allowed, nil = unbounded.
    var rows: Range<Int>?
    /// Allowed centre range in u (open faces with whole dots), nil = unbounded.
    var uRange: ClosedRange<Double>?
    /// Radius of the closed face u goes around (u = radius · angle), nil on open or flat faces.
    /// Lets a flat disc stand straight along its own axis on a curved wall.
    var wrapRadius: Double?
    /// Dots (row, column) left out because an edge of a face that isn't a rectangle in (u, v)
    /// would cut them (see ``fitted(to:)``); columns counted around a closed face (0..<around).
    var dropped: Set<SIMD2<Int>> = []
    var around: Int?

    public init(_ values: TextureValues) {
        diameter = values["diameter"]
        // Dots of neighbouring columns may touch but never overlap into one blob.
        spacing = max(values["spacing"], values["diameter"] * 0.5)
        rowPitch = max(values["rowSpacing"], values["diameter"] * 0.5)
        dotHeight = values["height"]
        profile = Profile(rawValue: values.int("profile")) ?? .flat
        raised = values.bool("raised")
        stagger = values.bool("stagger")
        whole = values.bool("whole")
        disc = Disc(radius: diameter / 2, height: dotHeight, edge: values["edge"])
        pitch = spacing
        // Unbounded layouts (flat faces without whole dots, triplanar faces, swatches): row 0 half a
        // pitch up from v = 0.
        origin = SIMD2(spacing / 2, rowPitch / 2)
    }

    public var cell: SIMD2<Double> { SIMD2(spacing, stagger ? 2 * rowPitch : rowPitch) }
    public var amplitude: Double { dotHeight }
    public var fitsAround: Bool { true }

    public var detail: Double {
        if profile == .flat {
            // The disc's top and the plain wall are smooth: coarse there, fine only at the rim.
            return min(max(diameter / 20, disc.segment), 1.0)
        }
        // Enough triangles across a dot for a smooth dome, finer for crisp feet and tall dots.
        let across = profile == .dome ? 30.0 : 40.0
        let byHeight = dotHeight > 0 ? diameter / 2 / max(dotHeight / 0.6, 1) : .infinity
        return min(max(min(diameter / across, byHeight), 0.12), 1.4)
    }

    /// Around a flat disc's rim: triangles about as long as the rim's own segments (the rim itself
    /// is meshed along its curves, see ``rims(lo:hi:scale:)``), growing away from it.
    public func detail(at p: SIMD2<Double>) -> Double {
        let coarse = detail
        guard profile == .flat, dotHeight > 0, let (_, offset) = nearest(p) else { return coarse }
        let a = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        let outside = max(0, disc.innerRim - a, a - disc.foot)
        return min(coarse, disc.segment + 0.5 * outside)
    }

    /// A flat disc's outline as curves for the mesh to follow: its foot, the top of its side and
    /// steps along its edge round, each a true circle around the disc's own axis (on a cylinder:
    /// placed where the point, moved out to its height, is that far from the axis).
    public func rims(lo: SIMD2<Double>, hi: SIMD2<Double>, scale: Double) -> [TextureRim] {
        guard profile == .flat, dotHeight > 0, diameter > 0 else { return [] }
        // Discs that touch or nearly touch share their surroundings: leave those to the plain mesh.
        let gapAlong = pitch
        let gapAcross = stagger ? ((pitch / 2) * (pitch / 2) + rowPitch * rowPitch).squareRoot() : rowPitch
        guard min(gapAlong, gapAcross) > 2 * disc.foot + 4 * disc.segment * max(scale, 1) else { return [] }
        let profilePoints = disc.profile(arcSteps: max(2, min(12, Int((Disc.wall * disc.edge / (0.04 * max(scale, 1))).rounded(.up)))))
        let count = max(scale > 1 ? 64 : 128, Int((2 * .pi * disc.foot / (disc.segment * max(scale, 1))).rounded(.up)))
        var rings: [[SIMD2<Double>]] = []
        for (a, h) in profilePoints {
            var ring: [SIMD2<Double>] = []
            ring.reserveCapacity(count)
            for i in 0..<count {
                let phi = 2 * .pi * Double(i) / Double(count)
                let x = a * cos(phi), y = a * sin(phi)
                let du = wrapRadius.map { r in r * asin(max(-1, min(1, x / (r + h)))) } ?? x
                ring.append(SIMD2(du, y))
            }
            rings.append(ring)
        }
        let reach = disc.foot + 1
        let rowRange: Range<Int>
        if let rows {
            rowRange = rows
        } else {
            let r0 = Int(((lo.y - origin.y - reach) / rowPitch).rounded(.down))
            let r1 = Int(((hi.y - origin.y + reach) / rowPitch).rounded(.up))
            guard r1 >= r0, r1 - r0 < 10_000 else { return [] }
            rowRange = r0..<(r1 + 1)
        }
        var out: [TextureRim] = []
        for row in rowRange {
            let cy = Double(row) * rowPitch + origin.y
            guard cy + reach > lo.y, cy - reach < hi.y else { continue }
            let shift = stagger && row & 1 != 0 ? pitch / 2 : 0
            let cols: Range<Int>
            if let r = wrapRadius {
                cols = 0..<max(1, Int((2 * .pi * r / pitch).rounded()))
            } else {
                let c0 = Int(((lo.x - origin.x - shift - reach) / pitch).rounded(.down))
                let c1 = Int(((hi.x - origin.x - shift + reach) / pitch).rounded(.up))
                guard c1 >= c0, c1 - c0 < 10_000 else { return [] }
                cols = c0..<(c1 + 1)
            }
            for col in cols {
                let cx = Double(col) * pitch + shift
                if let uRange, !uRange.contains(cx + origin.x) { continue }
                if isDropped(row, col) { continue }
                let centre = SIMD2(cx + origin.x, cy)
                if wrapRadius == nil, centre.x + reach < lo.x || centre.x - reach > hi.x { continue }
                out.append(TextureRim(center: centre, rings: rings))
            }
        }
        return out
    }

    /// Distance kept between a whole dot's foot and the face edge, mm.
    var margin: Double { min(1.5, 0.04 * diameter) }

    public func fitted(to extent: SIMD2<Double>?, wraps: Bool) -> any TexturePattern {
        guard let extent, extent.x > 0, extent.y > 0 else { return self }
        var out = self
        if wraps {
            // All the way around: a whole number of evenly spaced columns, the dots kept round.
            // Rows start a quarter pitch from the seam, so it runs midway between staggered rows.
            let count = max(1, (extent.x / spacing).rounded())
            out.pitch = extent.x / count
            out.origin.x = out.pitch * (stagger ? 0.25 : 0.5)
            out.wrapRadius = extent.x / (2 * .pi)
            out.around = Int(count)
            out.uRange = nil
        }
        guard whole else { return out }
        let r = diameter / 2 + margin
        // Rows: as many as fit whole, centred on the face; none when not even one fits.
        let freeV = extent.y - 2 * r
        if freeV < 0 {
            out.rows = 0..<0
            return out
        }
        let rowCount = Int((freeV / rowPitch + 1e-9).rounded(.down)) + 1
        out.rows = 0..<rowCount
        out.origin.y = (extent.y - Double(rowCount - 1) * rowPitch) / 2
        if !wraps {
            let freeU = extent.x - 2 * r
            if freeU < 0 {
                out.rows = 0..<0
                return out
            }
            let count = Int((freeU / spacing + 1e-9).rounded(.down)) + 1
            var span = Double(count - 1) * spacing
            // Staggered rows: when the shifted row also fits `count` dots, centre the pair of rows.
            if stagger && rowCount > 1 && span + spacing / 2 <= freeU + 1e-9 { span += spacing / 2 }
            out.origin.x = (extent.x - span) / 2
            out.uRange = (r - 1e-6)...(extent.x - r + 1e-6)
        }
        return out
    }

    /// Also leaves out the dots an edge of the face would cut (or come closer to than the
    /// margin), wherever the face's outline runs in (u, v): with whole dots any edge, without
    /// them only seams to smoothly joined textured faces (``TextureFace/Segment/seam``). Each
    /// face lays its dots out on its own, so a dot across a seam would be cut in two with a step
    /// down the middle, the neighbour's dots overlapping it; at the textured surface's outer
    /// edges (a sharp edge, an untextured face) cut dots are what turning whole dots off asks for.
    public func fitted(to face: TextureFace) -> any TexturePattern {
        guard var out = fitted(to: face.extent, wraps: face.wraps) as? DotsPattern else { return self }
        guard !face.border.isEmpty, let extent = face.extent else { return out }
        let seamsOnly = !whole
        if seamsOnly && !face.border.contains(where: \.seam) { return out }
        let r = diameter / 2 + margin
        let rows: Range<Int>
        if let fitted = out.rows {
            rows = fitted
        } else {
            // Every row with a dot reaching onto the face.
            let r0 = Int(((-r - out.origin.y) / rowPitch).rounded(.down))
            let r1 = Int(((extent.y + r - out.origin.y) / rowPitch).rounded(.up))
            guard r1 >= r0, r1 - r0 < 10_000 else { return out }
            rows = r0..<(r1 + 1)
        }
        for row in rows {
            let cy = Double(row) * rowPitch + out.origin.y
            let shift = stagger && row & 1 != 0 ? out.pitch / 2 : 0
            let cols: Range<Int>
            if let around = out.around {
                cols = 0..<around
            } else {
                let lo = out.uRange?.lowerBound ?? -r, hi = out.uRange?.upperBound ?? extent.x + r
                let c0 = Int(((lo - out.origin.x - shift) / out.pitch).rounded(.up))
                let c1 = Int(((hi - out.origin.x - shift) / out.pitch).rounded(.down))
                guard c1 >= c0, c1 - c0 < 10_000 else { continue }
                cols = c0..<(c1 + 1)
            }
            for col in cols {
                let centre = SIMD2(Double(col) * out.pitch + shift + out.origin.x, cy)
                if face.clearance(at: centre, seamsOnly: seamsOnly) < r { out.dropped.insert(SIMD2(row, col)) }
            }
        }
        return out
    }

    /// Whether the dot in `row`, `col` is left out (see ``fitted(to:)``).
    func isDropped(_ row: Int, _ col: Int) -> Bool {
        guard !dropped.isEmpty else { return false }
        let c = around.map { ((col % $0) + $0) % $0 } ?? col
        return dropped.contains(SIMD2(row, c))
    }

    /// The dot whose centre is nearest `p`: its offset from `p` along u (as an angle around a
    /// closed face) and v, and the offset in mm on the surface's tangent plane at the dot centre.
    func nearest(_ p: SIMD2<Double>) -> (du: Double, offset: SIMD2<Double>)? {
        guard diameter > 0 else { return nil }
        let q = p - origin
        let nearRow = Int((q.y / rowPitch).rounded())
        var best: (Double, SIMD2<Double>)?
        var bestD2 = Double.infinity
        for row in (nearRow - 1)...(nearRow + 1) {
            if let rows, !rows.contains(row) { continue }
            let dy = q.y - Double(row) * rowPitch
            let shift = stagger && row & 1 != 0 ? pitch / 2 : 0
            let nearCol = Int(((q.x - shift) / pitch).rounded())
            for col in (nearCol - 1)...(nearCol + 1) {
                let cx = Double(col) * pitch + shift
                if let uRange, !uRange.contains(cx + origin.x) { continue }
                if isDropped(row, col) { continue }
                let du = q.x - cx
                let d2 = du * du + dy * dy
                guard d2 < bestD2 else { continue }
                bestD2 = d2
                // Around a cylinder the disc's side runs along its axis: across the wall that is
                // R·sin(angle) from the axis, not the arc length.
                let x = wrapRadius.map { $0 * sin(du / $0) } ?? du
                best = (du, SIMD2(x, dy))
            }
        }
        return best
    }

    public func height(at p: SIMD2<Double>) -> Double {
        let a = diameter / 2
        guard a > 0, dotHeight > 0 else { return 0 }
        let sign: Double = raised ? 1 : -1
        if profile == .flat {
            guard let (du, offset) = nearest(p) else { return 0 }
            return sign * disc.height(du: du, offset: offset, wrapRadius: wrapRadius)
        }
        let q = p - origin
        let nearRow = Int((q.y / rowPitch).rounded())
        var best = 0.0
        // A dot may reach into the neighbouring rows when it is wider than the row spacing.
        let reach = Int((a / rowPitch).rounded(.up))
        for row in (nearRow - reach)...(nearRow + reach) {
            if let rows, !rows.contains(row) { continue }
            let dy = q.y - Double(row) * rowPitch
            guard abs(dy) < a else { continue }
            let shift = stagger && row & 1 != 0 ? pitch / 2 : 0
            let nearCol = Int(((q.x - shift) / pitch).rounded())
            let colReach = Int((a / pitch).rounded(.up))
            for col in (nearCol - colReach)...(nearCol + colReach) {
                let cx = Double(col) * pitch + shift
                if let uRange, !uRange.contains(cx + origin.x) { continue }
                if isDropped(row, col) { continue }
                let dx = q.x - cx
                let d2 = dx * dx + dy * dy
                guard d2 < a * a else { continue }
                best = max(best, shape((d2.squareRoot()) / a))
            }
        }
        return sign * best * dotHeight
    }

    /// The dome or cap profile, 0…1, at `x` = distance from the centre over the radius (0…1).
    func shape(_ x: Double) -> Double {
        guard x < 1 else { return 0 }
        switch profile {
        case .dome:
            // A bell that leaves the surface tangentially, like a blown bubble on a vase.
            let s = 1 - x * x
            return s * s
        case .cap, .flat:
            // A round cap (parabolic, close to a sphere for low dots) whose last stretch bends
            // smoothly into the surface, so the foot is crisp but has no step.
            let foot = 0.12, x0 = 1 - foot
            guard x > x0 else { return 1 - x * x }
            let t = (x - x0) / foot
            let w = 1 - t * t * (3 - 2 * t)
            return max(0, (1 - x0 * x0 - 2 * x0 * (x - x0)) * w)
        }
    }

    /// A flat disc's cross-section: a straight side (steep enough to read as a step, not quite
    /// vertical so a displaced mesh can follow it), a round of radius `edge` onto a flat top, and a
    /// sharp foot. The mesh follows its outline exactly (``DotsPattern/rims(lo:hi:scale:)``).
    struct Disc: Sendable {
        /// Side angle from the surface, radians.
        static let wall = 80.0 * Double.pi / 180

        let height: Double
        let edge: Double
        /// Distance from the axis where the side meets the surface.
        let foot: Double
        let roundCentre: SIMD2<Double>
        /// Height where the side meets the round.
        let roundStart: Double
        let cot: Double
        /// Length of the rim's segments around the disc, mm.
        let segment: Double

        init(radius: Double, height h: Double, edge e: Double) {
            height = max(h, 0)
            cot = 1 / tan(Self.wall)
            edge = max(0, min(e, 0.9 * height, 0.4 * radius))
            // The side leans in by `run` over its height: centre it on the dot's radius.
            let run = height * cot
            foot = radius + run / 2
            // Round tangent to the top (h = height) and to the side line a = foot - h·cot.
            let s = sin(Self.wall), c = cos(Self.wall)
            let ch = height - edge
            roundCentre = SIMD2(foot - ch * cot - edge / s, ch)
            roundStart = ch + edge * c
            segment = max(0.02, min(0.25, 2 * .pi * foot / 128))
        }

        /// Distance from the axis where the round starts on the top.
        var outer: Double { foot }
        var innerRim: Double { edge > 0 ? roundCentre.x : foot - height * cot }

        /// Points (distance from the axis, height) along the outline from the foot to the top,
        /// at every corner and `arcSteps` steps along the round.
        func profile(arcSteps: Int) -> [(Double, Double)] {
            var out: [(Double, Double)] = [(foot, 0)]
            guard edge > 0 else {
                out.append((foot - height * cot, height))
                return out
            }
            for k in 0...arcSteps {
                let psi = Self.wall * (1 - Double(k) / Double(arcSteps))
                out.append((roundCentre.x + edge * sin(psi), roundCentre.y + edge * cos(psi)))
            }
            return out
        }

        /// How far the disc reaches from its axis at height `h` above the surface.
        func reach(_ h: Double) -> Double {
            if h <= roundStart { return foot - h * cot }
            let dh = h - roundCentre.y
            return roundCentre.x + max(0, edge * edge - dh * dh).squareRoot()
        }

        /// Height of the disc along the surface normal at a point `du` (u from the dot centre)
        /// and `offset` (tangent-plane offset from the axis, see ``DotsPattern/nearest(_:)``).
        /// On a wall of radius R the normal there leans away from the disc's axis, so the point
        /// moved out by h is R+h from the wall's axis and (R+h)·sin(du/R) from the disc's.
        func height(du: Double, offset: SIMD2<Double>, wrapRadius: Double?) -> Double {
            func axisDistance(_ h: Double) -> Double {
                let x: Double
                if let r = wrapRadius { x = (r + h) * sin(du / r) } else { x = offset.x }
                return (x * x + offset.y * offset.y).squareRoot()
            }
            guard height > 0, axisDistance(0) < foot else { return 0 }
            if axisDistance(height) <= reach(height) { return height }
            // Inside is monotone along the normal: farther out, farther from the axis and a
            // smaller reach. Bisect for where the point leaves the disc.
            var lo = 0.0, hi = height
            for _ in 0..<48 {
                let mid = (lo + hi) / 2
                if axisDistance(mid) <= reach(mid) { lo = mid } else { hi = mid }
            }
            return lo
        }
    }
}
