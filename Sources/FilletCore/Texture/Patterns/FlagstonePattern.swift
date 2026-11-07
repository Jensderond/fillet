import Foundation

/// Irregular flat stones laid like crazy paving, with sunken mortar joints between them.
///
/// The height comes from the distance to the nearest stone's outline (its corners rounded, its
/// sides wandering a little): the joint floor sits `depth` below the surface, the stone's edge
/// rounds up out of it over `edge`, and its top is the surface itself, sunk and tilted a little
/// per stone (`relief`) and with a fine, uneven grain (`roughness`). The whole layout comes from
/// `seed`.
///
/// On a part the stones are laid out once over every textured face together, in space
/// (``solid(over:)``, ``SolidFlagstones``), so they run on unbroken over fillets and corner
/// blends. ``height(at:)`` in (u, v), used for the swatch, lays them out on a jittered grid (a
/// Voronoi diagram of one point per grid cell, every other row shifted by half a stone) that
/// repeats every ``gridSize`` stones each way, or, fitted around a closed face, once around.
public struct FlagstonePattern: TexturePattern {
    public static let id: TexturePatternID = .flagstone
    public static let displayName = "Flagstone"
    public static let summary = "Irregular flat stones with sunken mortar joints, like crazy paving or a dry-stone wall."
    public static let symbol = "circle.hexagongrid"
    public static let parameters: [TextureParameter] = [
        .length("size", "Stone size", default: 15, range: 2...150,
                help: "Typical width of a stone (around a vase: evened out so a whole number fit)"),
        .length("joint", "Joint width", default: 1.6, range: 0.2...20, help: "Width of the mortar joints between stones"),
        .length("depth", "Joint depth", default: 1, range: 0.05...10, help: "How far the joints sink below the stones"),
        .length("edge", "Edge rounding", default: 2.5, range: 0.1...20,
                help: "Width over which a stone's edge rounds down into the joint"),
        .number("irregularity", "Irregularity", default: 0.8, range: 0...1,
                help: "0: an even grid of stones; 1: as irregular as it gets"),
        .number("relief", "Stone relief", default: 0.4, range: 0...1,
                help: "How much stones differ in height and tilt, as a fraction of the joint depth"),
        .number("roughness", "Roughness", default: 0.3, range: 0...1,
                help: "Uneven grain on the stone tops, as a fraction of the joint depth"),
        .count("seed", "Layout", default: 1, range: 0...9999, help: "Another number gives another arrangement of stones"),
    ]

    /// Stones per repeat along each direction on faces that don't wrap. Even, so the half-stone
    /// shift of every other row repeats too.
    static let gridSize = 6
    /// Value-noise lattice steps per stone for the two octaves of the roughness. The fine one at
    /// a fifth of a stone, not a ninth: at a ninth its bumps were under three of the stone tops'
    /// triangles (``detail``) across, which tilted from one to the next by several degrees, and
    /// seen at a glancing angle the stone tops shaded as streaks along the triangles' rows.
    static let grain = (coarse: 3, fine: 5)

    public let size: Double
    public let joint: Double
    public let depth: Double
    public let edge: Double
    public let irregularity: Double
    public let relief: Double
    public let roughness: Double
    let seed: UInt64

    /// Distance between stone centres along u and v as laid out.
    var pitch: SIMD2<Double>
    /// Stones before the layout repeats along u and v.
    var columns: Int
    var rows: Int
    /// Extra width the edge round spreads over, mm, half into the joint and half onto the stone:
    /// a couple of the mesh's triangles across (see ``softeningSteps``), so the round comes out as
    /// a smooth curve on the mesh it is sampled on. The viewport's coarser mesh gets a slightly
    /// softer edge rather than a frayed one.
    var softening: Double
    /// ``softening`` in triangles of ``rimDetail`` (times the mesh's coarseness): for export, and
    /// for a coarser mesh (the viewport), where the triangles meet the round at fewer angles (the
    /// viewport's budget has no room for finer ones there). With the points lined up along the
    /// round (``SolidTexture/contourLevels``) and the gentler shoulder (``shoulder(_:)``), two
    /// are enough there too; three made the stones look melted.
    static let softeningSteps = (export: 2.0, coarse: 2.0)

    public init(_ values: TextureValues) {
        size = values["size"]
        // A joint can never swallow the stones.
        joint = min(values["joint"], values["size"] * 0.4)
        depth = values["depth"]
        edge = values["edge"]
        irregularity = values["irregularity"]
        relief = values["relief"]
        roughness = values["roughness"]
        seed = UInt64(max(values.int("seed"), 0))
        pitch = SIMD2(repeating: size)
        columns = Self.gridSize
        rows = Self.gridSize
        softening = 0
        softening = Self.softeningSteps.export * rimDetail
    }

    public var cell: SIMD2<Double> { pitch * SIMD2(Double(columns), Double(rows)) }
    public var amplitude: Double { depth }
    public var fitsAround: Bool { true }

    /// On the stone tops: fine enough for the roughness. Along the joints ``detail(at:)`` asks
    /// for finer.
    public var detail: Double { max(rimDetail, min(size / (roughness > 0 ? 25 : 10), 1.5)) }

    /// Along the joints and the stones' rounded edges: several triangles across the edge round,
    /// so it comes out as a smooth curve rather than a few facets catching the light unevenly,
    /// and fine enough along a joint that its outline doesn't zigzag (a ninth of the default
    /// joint).
    var rimDetail: Double { min(max(min(joint, edge) / 9, 0.05), 1.5) }

    /// Fine along the joints and stone edges, coarser on the stone tops (fine enough there for
    /// the roughness).
    public func detail(at p: SIMD2<Double>) -> Double {
        detail(edgeDistance: stone(at: p).edgeDistance)
    }

    /// Edge length wanted at a point `e` mm inside a stone's outline.
    func detail(edgeDistance e: Double) -> Double {
        let fine = rimDetail, top = detail
        guard top > fine else { return fine }
        // Outside the edge round: on the joint floor or the stone's top.
        let round = edgeRound
        let away = max(round.start - e, e - round.start - round.width, 0)
        return away <= fine ? fine : min(top, fine + (away - fine))
    }

    public func fitted(to extent: SIMD2<Double>?, wraps: Bool) -> any TexturePattern {
        guard wraps, let extent, extent.x > 0 else { return self }
        // All the way around: a whole number of columns, the layout repeating once around.
        var out = self
        out.columns = max(3, Int((extent.x / size).rounded()))
        out.pitch.x = extent.x / Double(out.columns)
        return out
    }

    public func height(at p: SIMD2<Double>) -> Double {
        let s = stone(at: p)
        return profile(edgeDistance: s.edgeDistance, top: stoneTop(s, at: p))
    }

    /// Height `e` mm inside a stone's outline whose top there is at `top`: the joint floor out to
    /// half the joint, then the edge rounding up over `edge` (``shoulder(_:)``), then the top.
    func profile(edgeDistance e: Double, top: Double) -> Double {
        let floor = -depth
        let round = edgeRound
        let t = (e - round.start) / round.width
        if t <= 0 { return floor }
        if t >= 1 { return top }
        return floor + (top - floor) * Self.shoulder(t)
    }

    /// Where the edge round turns from bending up out of the joint to bending over onto the top,
    /// as a fraction of its width (see ``shoulder(_:)``).
    static let foot = 0.35

    /// The edge round's rise from 0 to 1 across `t` in 0…1. Its curvature is half a sine wave up
    /// over the first ``foot`` of the width (the foot, down in the joint) and a longer, gentler
    /// half wave down over the rest (the shoulder onto the top), so the curve leaves the joint
    /// floor and meets the top level, with no jump in curvature anywhere.
    ///
    /// The shoulder is the part that catches the light. A symmetric curve (a smootherstep over
    /// the 1 mm the edge used to default to) bent over onto the top at a radius of 0.4 mm, about
    /// two triangles of the mesh, and shaded as a dotted line along every stone's crest, or as a
    /// crisp hairline seen at a glancing angle. This shoulder bends at most 0.84 times as sharply
    /// as a smootherstep of the same width. Over the default 2.5 mm edge it bends at a radius of
    /// about 1.9 mm and the round is at most 35° steep; at 1.5 mm (0.9 mm and 47°) the highlight
    /// along the crest still read as a hard bright line tracing every stone.
    static func shoulder(_ t: Double) -> Double {
        if t < foot { return t - foot / .pi * sin(.pi * t / foot) }
        let rest = 1 - foot
        return t + rest / .pi * sin(.pi * (t - foot) / rest)
    }

    /// Where the edge round starts (mm inside the outline) and how wide it is: `edge` from half
    /// the joint, widened by ``softening`` (never past the joint's middle).
    var edgeRound: (start: Double, width: Double) {
        let start = joint / 2 - softening / 2
        return start >= 0 ? (start, edge + softening) : (0, edge + softening + start)
    }

    // MARK: - Layout

    /// The stone a point lies on: its grid index (wrapped into one repeat), its centre and the
    /// distance from the point to its outline, mm.
    struct Stone {
        var column: Int
        var row: Int
        var center: SIMD2<Double>
        var edgeDistance: Double
    }

    /// Centre of the stone in grid cell (`i`, `j`), unwrapped, in (u, v).
    func center(_ i: Int, _ j: Int) -> SIMD2<Double> {
        let ci = wrap(i, columns), rj = wrap(j, rows)
        let jitter = SIMD2(hash(ci, rj, 1), hash(ci, rj, 2)) - 0.5
        let shift = rj & 1 == 0 ? 0.0 : 0.5
        let local = SIMD2(Double(i) + shift + 0.5, Double(j) + 0.5) + jitter * (0.9 * irregularity)
        return local * pitch
    }

    func stone(at point: SIMD2<Double>) -> Stone {
        // Joints wander a little instead of running dead straight.
        let p = point + (0.035 * size * irregularity) * SIMD2(noise(point, steps: 2, salt: 7), noise(point, steps: 2, salt: 8))
        let cj = Int((p.y / pitch.y).rounded(.down))
        // The nearest centre (jitter keeps each within its own cell, so two cells out is enough).
        var best = (i: 0, j: 0, c: SIMD2<Double>.zero, d2: Double.infinity)
        for j in (cj - 2)...(cj + 2) {
            let shift = wrap(j, rows) & 1 == 0 ? 0.0 : 0.5
            let ci = Int((p.x / pitch.x - shift).rounded(.down))
            for i in (ci - 2)...(ci + 2) {
                let c = center(i, j)
                let d = p - c
                let d2 = (d * d).sum()
                if d2 < best.d2 { best = (i, j, c, d2) }
            }
        }
        // Distance to the stone's outline: to the nearest bisector with a neighbouring centre,
        // blended where two meet so the stone's corners come out rounded.
        let round = 0.12 * size
        var edge = Double.infinity
        for j in (best.j - 2)...(best.j + 2) {
            let shift = wrap(j, rows) & 1 == 0 ? 0.0 : 0.5
            let ci = Int((best.c.x / pitch.x - shift).rounded(.down))
            for i in (ci - 2)...(ci + 2) {
                let c = center(i, j)
                let ab = c - best.c
                let l2 = (ab * ab).sum()
                guard l2 > 1e-12 else { continue }
                let mid = (best.c + c) / 2
                let d = ((mid - p) * ab).sum() / l2.squareRoot()
                let h = max(round - abs(edge - d), 0) / round
                edge = min(edge, d) - h * h * round / 4
            }
        }
        return Stone(column: wrap(best.i, columns), row: wrap(best.j, rows), center: best.c, edgeDistance: max(edge, 0))
    }

    /// Height of a stone's top at `p`: a little below the surface by a per-stone amount, tilted a
    /// little in a per-stone direction, with grain on it. Never below `-0.8 · depth`, so the joint
    /// stays the lowest part.
    func stoneTop(_ s: Stone, at p: SIMD2<Double>) -> Double {
        var top = 0.0
        if relief > 0 {
            let sink = hash(s.column, s.row, 3)
            let angle = 2 * .pi * hash(s.column, s.row, 4)
            let along = ((p - s.center) * SIMD2(cos(angle), sin(angle))).sum() / (0.6 * size)
            // Smoothly bounded tilt in -1…1.
            let tilt = along / (1 + along * along).squareRoot()
            top -= relief * 0.5 * depth * (0.5 * sink + 0.25 * (1 + tilt))
        }
        if roughness > 0 {
            let n = 0.7 * noise(p, steps: Self.grain.coarse, salt: 5) + 0.3 * noise(p, steps: Self.grain.fine, salt: 6)
            top += roughness * 0.3 * depth * n
        }
        return top
    }

    /// Smooth value noise in -1…1 with `steps` lattice steps per stone, repeating with the layout.
    func noise(_ p: SIMD2<Double>, steps: Int, salt: UInt64) -> Double {
        let q = p / pitch * Double(steps)
        let i0 = Int(q.x.rounded(.down)), j0 = Int(q.y.rounded(.down))
        let f = q - SIMD2(Double(i0), Double(j0))
        let w = f * f * f * (f * (f * 6 - 15) + 10)
        let nx = columns * steps, ny = rows * steps
        func at(_ i: Int, _ j: Int) -> Double { hash(wrap(i, nx), wrap(j, ny), salt) * 2 - 1 }
        let a = at(i0, j0), b = at(i0 + 1, j0), c = at(i0, j0 + 1), d = at(i0 + 1, j0 + 1)
        return a + (b - a) * w.x + (c - a) * w.y + (a - b - c + d) * w.x * w.y
    }

    func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

    /// A random number in 0..<1 for lattice point (`i`, `j`), stream `salt` and this layout's seed.
    func hash(_ i: Int, _ j: Int, _ salt: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(bitPattern: Int64(j)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= (seed &+ 1) &* 0x1656_67B1_9E37_79F9
        x ^= salt &* 0xD6E8_FEB8_6659_FD93
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }
}
