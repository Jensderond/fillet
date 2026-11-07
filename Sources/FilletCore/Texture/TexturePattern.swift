import Foundation
import simd

/// One value a texture pattern takes, declared by the pattern so the inspector, the MCP tool,
/// document coding and the texture-lab harness all handle it without pattern-specific code.
public struct TextureParameter: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Millimetres.
        case length
        /// Degrees.
        case angle
        /// A whole number.
        case count
        /// A plain number (a ratio, a factor).
        case number
        /// On (1) or off (0), shown as a switch.
        case toggle
        /// An index into these option names, shown as a menu.
        case choice([String])
    }

    /// Key in ``Texture/values`` and ``TextureValues``. Never rename one once shipped: files store it.
    public var id: String
    /// Label, e.g. "Stitch width".
    public var name: String
    public var kind: Kind
    public var defaultValue: Double
    /// Allowed values (in the kind's unit); recompute reports a value outside it.
    public var range: ClosedRange<Double>
    /// One short sentence for tooltips and the MCP tool's schema.
    public var help: String
    /// Set when the value only does something while another parameter has certain values (a
    /// disc's rim rounding only with the flat disc profile). The inspector then shows it directly
    /// under that parameter, and only while it applies. Nil: always shown, in declaration order.
    public var shownWhen: TextureCondition?

    public init(_ id: String, _ name: String, _ kind: Kind, default defaultValue: Double, range: ClosedRange<Double>,
                help: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.defaultValue = defaultValue; self.range = range; self.help = help
    }

    /// Unit shown after the value ("mm", "°" or nothing).
    public var unit: String {
        switch kind {
        case .length: "mm"
        case .angle: "°"
        default: ""
        }
    }

    public static func length(_ id: String, _ name: String, default d: Double, range: ClosedRange<Double>, help: String = "") -> Self {
        Self(id, name, .length, default: d, range: range, help: help)
    }

    public static func angle(_ id: String, _ name: String, default d: Double, range: ClosedRange<Double> = -360...360,
                             help: String = "") -> Self {
        Self(id, name, .angle, default: d, range: range, help: help)
    }

    public static func count(_ id: String, _ name: String, default d: Int, range: ClosedRange<Int>, help: String = "") -> Self {
        Self(id, name, .count, default: Double(d), range: Double(range.lowerBound)...Double(range.upperBound), help: help)
    }

    public static func number(_ id: String, _ name: String, default d: Double, range: ClosedRange<Double>, help: String = "") -> Self {
        Self(id, name, .number, default: d, range: range, help: help)
    }

    public static func toggle(_ id: String, _ name: String, default d: Bool, help: String = "") -> Self {
        Self(id, name, .toggle, default: d ? 1 : 0, range: 0...1, help: help)
    }

    public static func choice(_ id: String, _ name: String, _ options: [String], default d: Int = 0, help: String = "") -> Self {
        Self(id, name, .choice(options), default: Double(d), range: 0...Double(max(options.count - 1, 0)), help: help)
    }

    /// This parameter, shown only while parameter `id` has one of `values` (for a choice: option
    /// indices), e.g. `.length("rim", …).shown(when: "profile", is: 2)`.
    public func shown(when id: String, is values: Double...) -> Self {
        var p = self; p.shownWhen = TextureCondition(parameter: id, values: Set(values)); return p
    }

    /// This parameter with another label and help line (same id, so files keep their values).
    public func named(_ name: String, help: String? = nil) -> Self {
        var p = self; p.name = name; if let help { p.help = help }; return p
    }
}

/// When a parameter applies: while `parameter` has one of `values`.
public struct TextureCondition: Hashable, Sendable {
    public var parameter: String
    public var values: Set<Double>

    public init(parameter: String, values: Set<Double>) { self.parameter = parameter; self.values = values }

    /// Whether it holds for these values (a missing value counts as not set).
    public func holds(_ values: TextureValues) -> Bool {
        values.values[parameter].map { v in self.values.contains { abs($0 - v) < 1e-9 } } ?? false
    }
}

/// A pattern's parameter values after recompute: numbers in the parameter's unit (mm, degrees).
public struct TextureValues: Hashable, Sendable {
    public var values: [String: Double]

    public init(_ values: [String: Double] = [:]) { self.values = values }

    /// The value, or 0 for an id that isn't set (patterns get every declared id filled in).
    public subscript(_ id: String) -> Double { values[id] ?? 0 }
    public func bool(_ id: String) -> Bool { self[id] >= 0.5 }
    public func int(_ id: String) -> Int { Int(self[id].rounded()) }

    /// The defaults of `parameters`, overridden by these values.
    func filled(with parameters: [TextureParameter]) -> TextureValues {
        var all = values
        for p in parameters where all[p.id] == nil { all[p.id] = p.defaultValue }
        return TextureValues(all)
    }
}

/// A surface texture: a height field over the face's surface coordinates.
///
/// **Adding a texture** is one new file in `Sources/FilletCore/Texture/Patterns/` with a type
/// conforming to this protocol, plus one line in ``TextureCatalog/patterns``. Everything else
/// (the timeline step, the inspector, file coding, the MCP `texture` tool, the texture-lab
/// harness) reads the pattern's declarations generically.
///
/// Coordinates: `u` runs across/around the face and `v` along/up it, both in millimetres of
/// surface. On a cylinder, cone or other face that turns around an axis, `u` goes around the axis
/// (counter-clockwise looking down it) and `v` up the profile, so rows run around a vase and
/// columns up it. On a flat face `u` is horizontal and `v` runs up the face (on a horizontal face
/// u = world X, v = world Y). Other faces use a triplanar blend of the world planes.
///
/// Heights are along the outward normal in mm: positive raises the surface, negative cuts into it.
public protocol TexturePattern: Sendable {
    /// Stored in files; never change it once shipped.
    static var id: TexturePatternID { get }
    /// Menu name, e.g. "Knit".
    static var displayName: String { get }
    /// One sentence for the inspector and the MCP tool.
    static var summary: String { get }
    /// SF Symbol for menus and the timeline.
    static var symbol: String { get }
    /// The values this pattern takes, in display order.
    static var parameters: [TextureParameter] { get }

    /// The pattern with these values (every declared parameter is present).
    init(_ values: TextureValues)

    /// Size of one repeat in (u, v), mm. Around a closed face (a full cylinder) the engine fits a
    /// whole number of repeats, stretching `u` slightly, so `height` must repeat every `cell.x`
    /// in u for the seam to be invisible.
    var cell: SIMD2<Double> { get }
    /// Largest |height| the pattern produces, mm.
    var amplitude: Double { get }
    /// Edge length the surface is subdivided to for export, mm (the smallest detail worth
    /// resolving, typically a fifth to a tenth of a stitch or dot). The display uses coarser.
    var detail: Double { get }
    /// Height at surface point `p` = (u, v), mm along the outward normal.
    func height(at p: SIMD2<Double>) -> Double

    /// This pattern laid out for one face whose (u, v) run from 0 to `extent` (nil when the face
    /// has no such coordinates, e.g. a triplanar face). `wraps` is true when u goes all the way
    /// around (it then repeats every `extent.x`, a whole number of `cell.x`). Lets a pattern centre
    /// its features on the face or leave out ones its edges would cut. Default: unchanged.
    func fitted(to extent: SIMD2<Double>?, wraps: Bool) -> any TexturePattern

    /// This pattern laid out for one face, knowing its outline: lets a pattern leave out features
    /// that would cross an edge of a face that isn't a rectangle in (u, v) (a fillet trimmed by a
    /// corner blend, a face with a hole). Default: ``fitted(to:wraps:)`` with the face's extent.
    func fitted(to face: TextureFace) -> any TexturePattern

    /// Edge length wanted around `p`, mm, at most ``detail``: lets a pattern ask for fine
    /// triangles only where its height changes sharply (a dot's rim), and keep the rest coarse.
    /// Default: ``detail`` everywhere.
    func detail(at p: SIMD2<Double>) -> Double

    /// True when ``fitted(to:wraps:)`` spaces the pattern evenly around a closed face by itself:
    /// u is then plain arc length (no stretching to a whole number of ``cell`` repeats), so
    /// round features stay round. Default: false.
    var fitsAround: Bool { get }

    /// Outlines the mesh should follow exactly (``TextureRim``), for the features of this pattern
    /// (as fitted to a face) inside the (u, v) box `lo`…`hi`. A sharp step such as a disc's edge
    /// renders ragged when it runs across the triangles; meshed along its own curves it is clean.
    /// `scale` (1 for export, more for the display) coarsens them. Default: none.
    func rims(lo: SIMD2<Double>, hi: SIMD2<Double>, scale: Double) -> [TextureRim]

    /// The parameters as the inspector and the MCP tool present them: a chance to adjust labels,
    /// help or ``TextureParameter/shownWhen`` from a file beside the pattern's own. Ids, kinds,
    /// defaults and ranges must stay as declared. Default: `parameters` unchanged.
    static func presented(_ parameters: [TextureParameter]) -> [TextureParameter]

    /// Whether the shared "Fade at face border" value can visibly change this pattern with these
    /// values. False when the pattern keeps its features clear of face borders itself (dots with
    /// "Whole dots only"), so the inspector leaves the field out. Default: true.
    static func fadesAtBorders(_ values: TextureValues) -> Bool

    /// This pattern laid out over the whole surface the texture covers, in space, instead of in
    /// each face's own (u, v): the engine then samples ``SolidTexture/height(at:normal:)`` at each
    /// point and ``SolidTexture/detail(at:normal:)`` for the triangles, and ``height(at:)`` only
    /// draws the swatch. Use it for features that must run on across the edges between faces
    /// (each face's (u, v) is laid out on its own, so where a fillet meets a flat face two layouts
    /// butt together). Nil (the default): the per-face (u, v) path.
    func solid(over surface: TextureSurface) -> (any SolidTexture)?
}

/// A round feature's outline for the mesh to follow (see ``TexturePattern/rims(lo:hi:scale:)``):
/// nested closed curves around a centre, e.g. a disc's foot, the top of its side and the steps
/// of its edge round. The engine cuts the mesh out between the outermost and innermost curve,
/// meshes strips between neighbouring curves and joins the outer and inner one to the mesh
/// around them. Where it can't (the outline crosses a face edge or another rim), it leaves the
/// mesh as it is.
public struct TextureRim: Sendable {
    /// Centre in (u, v), mm.
    public var center: SIMD2<Double>
    /// Curves as offsets from `center` in (u, v), outermost first. Each runs counter-clockwise
    /// and is star-shaped around the centre; all have the same number of points.
    public var rings: [[SIMD2<Double>]]

    public init(center: SIMD2<Double>, rings: [[SIMD2<Double>]]) {
        self.center = center; self.rings = rings
    }
}

/// A face as a pattern is laid out on it (see ``TexturePattern/fitted(to:)``): its size in
/// (u, v) and its outline there.
public struct TextureFace: Sendable {
    /// u and v run from 0 to this; nil when the face has no such coordinates (a triplanar face).
    public var extent: SIMD2<Double>?
    /// u goes all the way around, repeating every `extent.x`.
    public var wraps: Bool
    /// The face's edges in (u, v), as segments; empty when unknown.
    public var border: [Segment]

    public struct Segment: Sendable {
        public var a: SIMD2<Double>
        public var b: SIMD2<Double>
        /// The face on the other side is textured too and joins this one smoothly: a seam inside
        /// the textured surface (each face lays its pattern out on its own, so a feature across
        /// it would be cut in two with a step), not the textured surface's outer edge.
        public var seam: Bool
        public init(_ a: SIMD2<Double>, _ b: SIMD2<Double>, seam: Bool = false) { self.a = a; self.b = b; self.seam = seam }
    }

    public init(extent: SIMD2<Double>?, wraps: Bool, border: [Segment] = []) {
        self.extent = extent; self.wraps = wraps; self.border = border
    }

    /// Distance from `p` to the nearest edge of the face in (u, v), mm (around a closed face,
    /// the shortest way round); infinity when the outline is unknown. `seamsOnly`: only the
    /// edges that are seams (see ``Segment/seam``).
    public func clearance(at p: SIMD2<Double>, seamsOnly: Bool = false) -> Double {
        var best = Double.infinity
        let shifts: [Double] = wraps ? [-(extent?.x ?? 0), 0, extent?.x ?? 0] : [0]
        for s in border where !seamsOnly || s.seam {
            let d = s.b - s.a
            let l2 = simd_length_squared(d)
            for shift in shifts {
                let q = p + SIMD2(shift, 0)
                let t = l2 > 0 ? max(0, min(1, simd_dot(q - s.a, d) / l2)) : 0
                best = min(best, simd_distance_squared(q, s.a + t * d))
            }
        }
        return best.squareRoot()
    }
}

extension TexturePattern {
    public func fitted(to extent: SIMD2<Double>?, wraps: Bool) -> any TexturePattern { self }
    public func fitted(to face: TextureFace) -> any TexturePattern { fitted(to: face.extent, wraps: face.wraps) }
    public func detail(at p: SIMD2<Double>) -> Double { detail }
    public var fitsAround: Bool { false }
    public func rims(lo: SIMD2<Double>, hi: SIMD2<Double>, scale: Double) -> [TextureRim] { [] }
    public static func presented(_ parameters: [TextureParameter]) -> [TextureParameter] { parameters }
    public static func fadesAtBorders(_ values: TextureValues) -> Bool { true }
    public func solid(over surface: TextureSurface) -> (any SolidTexture)? { nil }
}

/// All texture patterns, and the parameters every texture has.
public enum TextureCatalog {
    /// Registered patterns, in menu order. Adding a pattern = one line here.
    public static let patterns: [any TexturePattern.Type] = [
        KnitPattern.self,
        DotsPattern.self,
        FlagstonePattern.self,
    ]

    /// Parameters the engine itself reads, appended to every pattern's own.
    public static let common: [TextureParameter] = [
        .length("fade", "Fade at face border", default: 1, range: 0...50,
                help: "Distance over which the texture fades out where it meets an untextured face or a sharp edge"),
    ]

    public static func pattern(_ id: TexturePatternID) -> (any TexturePattern.Type)? {
        patterns.first { $0.id == id }
    }

    /// The pattern's parameters followed by ``common`` (empty for an unknown pattern).
    public static func parameters(for id: TexturePatternID) -> [TextureParameter] {
        guard let p = pattern(id) else { return [] }
        let declared = p.parameters
        // A presentation may relabel or condition parameters, never change what files store.
        let shown = p.presented(declared)
        let own = shown.count == declared.count && zip(shown, declared).allSatisfy {
            $0.id == $1.id && $0.kind == $1.kind && $0.defaultValue == $1.defaultValue && $0.range == $1.range
        } ? shown : declared
        return own + common
    }

    /// Whether the shared fade value can visibly change pattern `id` with these values (see
    /// ``TexturePattern/fadesAtBorders(_:)``); true for an unknown pattern.
    public static func fadesAtBorders(_ id: TexturePatternID, _ values: TextureValues) -> Bool {
        pattern(id)?.fadesAtBorders(values.filled(with: parameters(for: id))) ?? true
    }

    /// Default expressions for a new texture step with this pattern.
    public static func defaultValues(for id: TexturePatternID) -> [String: Expr] {
        Dictionary(uniqueKeysWithValues: parameters(for: id).map { ($0.id, Expr($0.defaultValue)) })
    }

    /// Evaluates a texture's expressions (missing ones take defaults) and checks their ranges.
    public static func resolve(_ texture: Texture, using ev: Evaluator) throws -> TextureValues {
        guard pattern(texture.pattern) != nil else {
            throw FeatureError("The “\(texture.pattern)” texture needs a newer version of Fillet")
        }
        var out: [String: Double] = [:]
        for p in parameters(for: texture.pattern) {
            let expr = texture.values[p.id] ?? Expr(p.defaultValue)
            let v: Double
            switch p.kind {
            case .length: v = try ev.length(expr)
            case .angle: v = try ev.angleDegrees(expr)
            case .count, .toggle, .choice: v = Double(try ev.integer(expr))
            case .number: v = try ev.scalar(expr)
            }
            guard v.isFinite, p.range.contains(v) else {
                throw FeatureError("\(p.name) must be between \(format(p.range.lowerBound))\(p.unit.isEmpty ? "" : " \(p.unit)") and \(format(p.range.upperBound))\(p.unit.isEmpty ? "" : " \(p.unit)")")
            }
            out[p.id] = v
        }
        return TextureValues(out)
    }

    /// The pattern instance for resolved values (nil for an unknown pattern).
    public static func make(_ id: TexturePatternID, _ values: TextureValues) -> (any TexturePattern)? {
        guard let p = pattern(id) else { return nil }
        return p.init(values.filled(with: parameters(for: id)))
    }

    /// Heights over `cells` repeats of the pattern on a `size` × `size` grid, row by row from
    /// v = 0 up, normalised to 0…1 (for inspector swatches and docs).
    public static func swatch(_ id: TexturePatternID, _ values: TextureValues = TextureValues(), size: Int = 64,
                              cells: Double = 2) -> [Float] {
        guard let pattern = make(id, values), size > 0 else { return [] }
        let span = max(pattern.cell.x, pattern.cell.y) * cells
        var heights: [Double] = []
        heights.reserveCapacity(size * size)
        for j in 0..<size {
            for i in 0..<size {
                heights.append(pattern.height(at: SIMD2(Double(i) + 0.5, Double(j) + 0.5) * (span / Double(size))))
            }
        }
        let lo = heights.min() ?? 0, hi = heights.max() ?? 1
        let range = hi - lo > 1e-12 ? hi - lo : 1
        return heights.map { Float(($0 - lo) / range) }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
