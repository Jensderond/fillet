import Foundation
import simd
import FilletKernel

/// An sRGB colour with straight (non-premultiplied) alpha.
public struct ViewportColor: Hashable, Codable, Sendable {
    public var r, g, b, a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Float = 1) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
    }

    public func withAlpha(_ a: Float) -> ViewportColor { ViewportColor(r, g, b, a) }
    /// Mixed towards white by `amount` (0…1).
    public func lightened(_ amount: Float) -> ViewportColor {
        ViewportColor(r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount, a)
    }

    /// Linear-light RGBA (what the shaders work in).
    var linear: SIMD4<Float> {
        func l(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD4(l(r), l(g), l(b), a)
    }

    public static let white = ViewportColor(1, 1, 1)
    public static let black = ViewportColor(0, 0, 0)
    /// Default body colour: a grey a step towards the icon's navy ink, so the part reads as the
    /// drawing's subject against the cream bed (and the selection blue and overhang red stay distinct).
    public static let defaultBody = ViewportColor(hex: 0xBAC3D3)
    /// Accent blue used for selection.
    public static let accent = ViewportColor(hex: 0x1F7BFF)
    /// Translucent blue used for "new body / join" previews.
    public static let previewAdd = ViewportColor(hex: 0x3D8BFF, alpha: 0.38)
    /// Translucent red used for "cut" previews.
    public static let previewCut = ViewportColor(hex: 0xFF4D4D, alpha: 0.38)
}

/// Whole-body highlight state.
public enum BodyHighlight: Hashable, Sendable {
    case none, hover, selected
}

/// One solid body (or a translucent feature preview) to draw.
public struct SceneBody: Identifiable, Sendable {
    public var id: UUID
    public var mesh: Mesh
    /// Bump whenever `mesh` changes. GPU buffers and the picking BVH are cached by
    /// `(id, version)` plus a cheap fingerprint of the mesh.
    public var version: Int
    /// Body colour; nil = palette default.
    public var color: ViewportColor?
    /// 1 = opaque. Anything below is drawn in the translucent pass.
    public var opacity: Float
    public var visible: Bool
    public var highlight: BodyHighlight
    public var showsEdges: Bool
    /// Whether the body takes part in picking.
    public var pickable: Bool

    public init(id: UUID, mesh: Mesh, version: Int = 0, color: ViewportColor? = nil, opacity: Float = 1,
                visible: Bool = true, highlight: BodyHighlight = .none, showsEdges: Bool = true, pickable: Bool = true) {
        self.id = id; self.mesh = mesh; self.version = version; self.color = color; self.opacity = opacity
        self.visible = visible; self.highlight = highlight; self.showsEdges = showsEdges; self.pickable = pickable
    }
}

/// How a sketch curve is drawn.
public enum SketchCurveStyle: UInt8, Hashable, Sendable, CaseIterable {
    case normal = 0, hover, selected, construction, preview
    /// A selected construction shape: selection blue, still dashed.
    case selectedConstruction
}

/// A polyline in sketch-plane coordinates (mm) belonging to one sketch shape.
public struct SketchCurve: Hashable, Sendable {
    /// The sketch shape this curve belongs to (picked as `.sketchShape(shapeID)`).
    public var shapeID: UUID
    public var points: [SIMD2<Double>]
    public var style: SketchCurveStyle
    public var closed: Bool

    public init(shapeID: UUID, points: [SIMD2<Double>], style: SketchCurveStyle = .normal, closed: Bool = false) {
        self.shapeID = shapeID; self.points = points; self.style = style; self.closed = closed
    }
}

/// How a sketch point is drawn.
public enum SketchPointStyle: UInt8, Hashable, Sendable, CaseIterable {
    case normal = 0, hover, selected, preview, snap
}

/// A point of a sketch shape (endpoint, centre, …) in sketch-plane coordinates.
public struct SketchPoint: Hashable, Sendable {
    public var shapeID: UUID
    /// Index of the point within its shape (picked as `.sketchPoint(shape:index:)`).
    public var index: Int
    public var position: SIMD2<Double>
    public var style: SketchPointStyle

    public init(shapeID: UUID, index: Int, position: SIMD2<Double>, style: SketchPointStyle = .normal) {
        self.shapeID = shapeID; self.index = index; self.position = position; self.style = style
    }
}

/// A closed profile region, triangulated in sketch-plane coordinates.
public struct SketchRegion: Hashable, Sendable {
    /// Region index (picked as `.region(index)`).
    public var index: Int
    /// Three points per triangle.
    public var triangles: [SIMD2<Double>]
    public var selected: Bool
    public var hover: Bool

    public init(index: Int, triangles: [SIMD2<Double>], selected: Bool = false, hover: Bool = false) {
        self.index = index; self.triangles = triangles; self.selected = selected; self.hover = hover
    }
}

/// Grid drawn on the sketch plane.
public struct SketchGrid: Hashable, Sendable {
    /// Minor line spacing in mm.
    public var spacing: Double
    /// Every n-th line is a major line.
    public var majorEvery: Int
    /// Half-size of the drawn grid square in mm.
    public var extent: Double

    public init(spacing: Double = 5, majorEvery: Int = 5, extent: Double = 200) {
        self.spacing = spacing; self.majorEvery = majorEvery; self.extent = extent
    }
}

/// The active sketch drawn on top of the model.
public struct SketchOverlay: Hashable, Sendable {
    public var plane: Plane
    public var curves: [SketchCurve]
    public var points: [SketchPoint]
    public var regions: [SketchRegion]
    public var grid: SketchGrid?

    public init(plane: Plane, curves: [SketchCurve] = [], points: [SketchPoint] = [], regions: [SketchRegion] = [],
                grid: SketchGrid? = SketchGrid()) {
        self.plane = plane; self.curves = curves; self.points = points; self.regions = regions; self.grid = grid
    }
}

/// The printer bed, drawn as a subtle plate at z = 0 with a fine grid.
public struct BuildPlate: Hashable, Codable, Sendable {
    public var name: String
    /// Bed width (x), depth (y) and maximum print height (z) in mm.
    public var size: SIMD3<Double>
    /// Bed centre in world XY.
    public var center: SIMD2<Double>

    public init(name: String, size: SIMD3<Double>, center: SIMD2<Double> = .zero) {
        self.name = name; self.size = size; self.center = center
    }

    public var minXY: SIMD2<Double> { center - SIMD2(size.x, size.y) / 2 }
    public var maxXY: SIMD2<Double> { center + SIMD2(size.x, size.y) / 2 }
}

/// Overhang visualisation: down-facing triangles steeper than the threshold are tinted.
public struct OverhangStyle: Hashable, Sendable {
    /// Overhang angle from vertical in degrees (45 = common FDM limit).
    public var thresholdDegrees: Double
    /// Triangles lying on this height (the bed) are never tinted.
    public var bedZ: Double
    public var color: ViewportColor

    public init(thresholdDegrees: Double = 45, bedZ: Double = 0, color: ViewportColor = ViewportColor(hex: 0xFF5A36)) {
        self.thresholdDegrees = thresholdDegrees; self.bedZ = bedZ; self.color = color
    }
}

/// A draggable arrow handle (e.g. extrude distance). The arrow tip sits at
/// `origin + direction * value`; dragging reports a new `value`.
public struct Handle: Hashable, Sendable, Identifiable {
    public var id: String
    public var origin: Vec3
    /// Unit axis the handle moves along.
    public var direction: Vec3
    public var value: Double
    /// Allowed values (drag results are clamped).
    public var range: ClosedRange<Double>?
    public var color: ViewportColor?

    public init(id: String, origin: Vec3, direction: Vec3, value: Double, range: ClosedRange<Double>? = nil,
                color: ViewportColor? = nil) {
        self.id = id; self.origin = origin; self.direction = direction.normalized; self.value = value
        self.range = range; self.color = color
    }

    /// World position of the arrow tip.
    public var tip: Vec3 { origin + direction * value }
}

/// A picked edge drawn on top of the model: thick, in the selection blue, with a halo, and
/// faintly where the model hides it, so a pick reads at arm's length.
public struct EdgeHighlight: Hashable, Sendable {
    public var points: [Vec3]
    /// Dashed: an edge that no longer exists in what's shown (the sharp edge a fillet replaces).
    public var dashed: Bool

    public init(points: [Vec3], dashed: Bool = false) { self.points = points; self.dashed = dashed }
}

/// A construction plane drawn as a translucent patch the user can pick (the origin planes
/// while choosing where to sketch). Tinted by the axis its normal runs along (an XY plane
/// takes Z's blue), or the palette's neutral plane colour when it runs along none.
public struct ReferencePlane: Hashable, Sendable, Identifiable {
    /// Picked as `.referencePlane(id)`.
    public var id: String
    public var plane: Plane
    /// The patch drawn, in plane coordinates (the plane itself is unbounded; picking uses the patch).
    public var u: ClosedRange<Double>
    public var v: ClosedRange<Double>
    /// Short name drawn at the patch's far corner ("XY").
    public var label: String

    public init(id: String, plane: Plane, u: ClosedRange<Double>, v: ClosedRange<Double>, label: String) {
        self.id = id; self.plane = plane; self.u = u; self.v = v; self.label = label
    }

    /// The patch's corners, counter-clockwise from (u.lower, v.lower).
    public var corners: [Vec3] {
        [plane.point(u: u.lowerBound, v: v.lowerBound), plane.point(u: u.upperBound, v: v.lowerBound),
         plane.point(u: u.upperBound, v: v.upperBound), plane.point(u: u.lowerBound, v: v.upperBound)]
    }

    /// Where the label sits: the corner furthest along both plane axes.
    public var labelAnchor: Vec3 { plane.point(u: u.upperBound, v: v.upperBound) }

    /// The world axis the normal runs along (0 = X, 1 = Y, 2 = Z), nil for a tilted plane.
    public var normalAxis: Int? {
        let n = plane.normal
        let a = [abs(n.x), abs(n.y), abs(n.z)]
        return a.firstIndex { $0 > 0.999 }
    }
}

/// Whether a measure's value can be typed, and how far that has got.
public enum MeasureEntry: Hashable, Sendable {
    /// Follows the pointer.
    case live
    /// Being typed. `label` is the text so far; before the first key it is the live value,
    /// shown selected (`replacing`) because typing replaces it.
    case typing(replacing: Bool)
    /// Typed and held.
    case locked
}

/// A dimension-like annotation: a line between two points with a text label.
public struct MeasureAnnotation: Hashable, Sendable, Identifiable {
    public var id: String
    public var from: Vec3
    public var to: Vec3
    public var label: String
    /// False for a bare value label (no dimension line or end dots), e.g. beside a handle.
    public var showsLine: Bool
    public var entry: MeasureEntry

    public init(id: String, from: Vec3, to: Vec3, label: String, showsLine: Bool = true, entry: MeasureEntry = .live) {
        self.id = id; self.from = from; self.to = to; self.label = label; self.showsLine = showsLine; self.entry = entry
    }
}

/// Something the user can point at in the viewport.
public enum PickTarget: Hashable, Sendable, Codable {
    /// A B-rep face (index into the mesh's `triangleFaces` space).
    case face(body: UUID, index: Int)
    /// A B-rep edge (index into `Mesh.edges`).
    case edge(body: UUID, index: Int)
    /// A whole body.
    case body(UUID)
    /// A sketch profile region.
    case region(Int)
    /// A sketch shape (any of its curves).
    case sketchShape(UUID)
    /// A characteristic point of a sketch shape.
    case sketchPoint(shape: UUID, index: Int)
    /// A drag handle.
    case handle(String)
    /// A reference plane (see `ReferencePlane`).
    case referencePlane(String)

    /// The body this target belongs to, if any.
    public var bodyID: UUID? {
        switch self {
        case .face(let b, _), .edge(let b, _), .body(let b): b
        default: nil
        }
    }
}

/// What can be picked.
public struct PickFilter: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let faces = PickFilter(rawValue: 1 << 0)
    public static let edges = PickFilter(rawValue: 1 << 1)
    /// Whole bodies (a face hit is reported as `.body` when `.faces` is not set).
    public static let bodies = PickFilter(rawValue: 1 << 2)
    public static let sketchPoints = PickFilter(rawValue: 1 << 3)
    public static let sketchCurves = PickFilter(rawValue: 1 << 4)
    public static let regions = PickFilter(rawValue: 1 << 5)
    public static let handles = PickFilter(rawValue: 1 << 6)
    public static let referencePlanes = PickFilter(rawValue: 1 << 7)

    public static let sketch: PickFilter = [.sketchPoints, .sketchCurves]
    /// Faces, edges and handles.
    public static let `default`: PickFilter = [.faces, .edges, .handles]
    public static let all: PickFilter = [.faces, .edges, .bodies, .sketchPoints, .sketchCurves, .regions, .handles, .referencePlanes]
    public static let none: PickFilter = []
}

/// Everything the viewport draws. Plain value; rebuild it whenever the model changes.
public struct ViewportScene: Sendable {
    public var bodies: [SceneBody]
    /// Translucent feature previews (drawn after opaque bodies, not pickable).
    public var previews: [SceneBody]
    public var sketch: SketchOverlay?
    public var plate: BuildPlate?
    public var selection: Set<PickTarget>
    /// Hover target; nil lets the viewport show its own pointer hover.
    public var hover: PickTarget?
    public var overhang: OverhangStyle?
    public var handles: [Handle]
    public var measures: [MeasureAnnotation]
    /// Picked edges drawn over everything else (see `EdgeHighlight`).
    public var edgeHighlights: [EdgeHighlight] = []
    /// Pickable construction planes (drawn translucent, under the sketch overlay).
    public var referencePlanes: [ReferencePlane] = []
    /// Faces that can be picked, per body; nil = all. A face outside its body's set still stops
    /// the pick ray (it hides what is behind it) but picks nothing and shows no hover.
    public var pickableFaces: [UUID: Set<Int>]?
    /// Infinite-feel ground grid on z = 0.
    public var showsGroundGrid: Bool

    public init(bodies: [SceneBody] = [], previews: [SceneBody] = [], sketch: SketchOverlay? = nil,
                plate: BuildPlate? = nil, selection: Set<PickTarget> = [], hover: PickTarget? = nil,
                overhang: OverhangStyle? = nil, handles: [Handle] = [], measures: [MeasureAnnotation] = [],
                referencePlanes: [ReferencePlane] = [], showsGroundGrid: Bool = true) {
        self.bodies = bodies; self.previews = previews; self.sketch = sketch; self.plate = plate
        self.selection = selection; self.hover = hover; self.overhang = overhang; self.handles = handles
        self.measures = measures; self.referencePlanes = referencePlanes; self.showsGroundGrid = showsGroundGrid
    }

    /// Whether `pickableFaces` lets a face be picked.
    func canPick(face: Int, of body: UUID) -> Bool {
        pickableFaces.map { $0[body]?.contains(face) == true } ?? true
    }

    /// Bounds of visible bodies and previews (nil when empty).
    public var modelBounds: Bounds3? {
        var b: Bounds3?
        for body in bodies + previews where body.visible {
            guard let mb = body.mesh.bounds3 else { continue }
            b = b.map { $0.union(mb) } ?? mb
        }
        return b
    }

    /// Bounds of everything drawn: model, plate, sketch and handles.
    public var bounds: Bounds3? {
        var b = modelBounds
        func add(_ p: Vec3) { b = b.map { $0.union(p) } ?? Bounds3(min: p, max: p) }
        if let plate {
            add(Vec3(plate.minXY.x, plate.minXY.y, 0))
            add(Vec3(plate.maxXY.x, plate.maxXY.y, 0))
        }
        if let s = sketch {
            for c in s.curves { for p in c.points { add(s.plane.point(p)) } }
            for p in s.points { add(s.plane.point(p.position)) }
        }
        for h in handles { add(h.origin); add(h.tip) }
        for r in referencePlanes { r.corners.forEach(add) }
        return b
    }

    /// Bounds to frame with "fit all": the model if there is one, else the plate.
    public var fitBounds: Bounds3? {
        if let m = modelBounds { return m }
        return bounds
    }
}
