import Foundation

/// Light or dark rendering palette.
public enum ViewportAppearance: String, Sendable, Hashable, CaseIterable {
    case light, dark

    public var palette: ViewportPalette { self == .light ? .light : .dark }
}

/// All colours the renderer uses (sRGB). Pick `.light` / `.dark` or customise.
public struct ViewportPalette: Hashable, Sendable {
    public var backgroundTop: ViewportColor
    public var backgroundBottom: ViewportColor
    public var body: ViewportColor
    public var edge: ViewportColor
    /// Faces in the hidden-line style: the paper the drawing is on.
    public var paper: ViewportColor
    /// Edges on unlit faces (x-ray, wireframe, hidden line): light on the dark viewport and paper.
    public var wire: ViewportColor
    public var accent: ViewportColor
    public var hover: ViewportColor
    /// Tint for selected faces (alpha = tint amount).
    public var selectionFill: ViewportColor
    /// Tint for hovered faces (alpha = tint amount).
    public var hoverFill: ViewportColor
    public var previewEdge: ViewportColor
    public var groundMinor: ViewportColor
    public var groundMajor: ViewportColor
    public var bedFill: ViewportColor
    public var bedMinor: ViewportColor
    public var bedMajor: ViewportColor
    public var bedOutline: ViewportColor
    public var axisX: ViewportColor
    public var axisY: ViewportColor
    public var axisZ: ViewportColor
    /// A reference plane whose normal runs along no world axis (origin planes take their axis colour).
    public var referencePlane: ViewportColor
    public var sketchCurve: ViewportColor
    /// Dashed construction geometry: slate, so orange keeps meaning "active".
    public var sketchConstruction: ViewportColor
    /// The shape being drawn (rubber band): a ghosted ink stroke, not the selection blue.
    public var sketchPreview: ViewportColor
    public var sketchPoint: ViewportColor
    public var sketchPointRing: ViewportColor
    public var sketchGridMinor: ViewportColor
    public var sketchGridMajor: ViewportColor
    /// Closed sketch regions: a quiet neutral wash, so blue keeps meaning "picked".
    public var regionFill: ViewportColor
    /// A region picked as a profile (Extrude, Revolve); hover is a lighter wash of the same blue.
    public var regionPickedFill: ViewportColor
    public var handle: ViewportColor
    public var measure: ViewportColor
    /// Halo behind picked edges, so the blue reads over any surface.
    public var edgeHalo: ViewportColor
    /// Soft contact shadow under bodies on the bed (alpha = strength).
    public var shadow: ViewportColor
    /// Hemisphere ambient colours (sky = up-facing, ground = down-facing).
    public var skyLight: ViewportColor
    public var groundLight: ViewportColor
    /// Light intensities.
    public var ambient: Float
    public var key: Float
    public var fill: Float
    public var rim: Float
    public var specular: Float
    /// Opacity of picked edges where the model hides them (drawn thin and finely dashed).
    public var hiddenPickedEdgeAlpha: Float = 0.5

    public static let light = ViewportPalette(
        backgroundTop: ViewportColor(hex: 0xF7F8FA),
        backgroundBottom: ViewportColor(hex: 0xDDE1E7),
        body: .defaultBody,
        edge: ViewportColor(hex: 0x23272E, alpha: 0.92),
        paper: ViewportColor(hex: 0xFFFFFF),
        wire: ViewportColor(hex: 0x23272E, alpha: 0.92),
        accent: ViewportColor(hex: 0x1A73FF),
        hover: ViewportColor(hex: 0x69A6FF),
        selectionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.6),
        hoverFill: ViewportColor(hex: 0x8CBCFF, alpha: 0.35),
        previewEdge: ViewportColor(hex: 0x1F4FA8, alpha: 0.55),
        groundMinor: ViewportColor(hex: 0x6B7380, alpha: 0.07),
        groundMajor: ViewportColor(hex: 0x6B7380, alpha: 0.15),
        // The bed is the icon's engineering paper: cream sheet, blue-green ruling, navy edge.
        bedFill: ViewportColor(hex: 0xF5EFE0),
        bedMinor: ViewportColor(hex: 0x4F8FB0, alpha: 0.26),
        bedMajor: ViewportColor(hex: 0x4F8FB0, alpha: 0.5),
        bedOutline: ViewportColor(hex: 0x1D2B45, alpha: 0.55),
        axisX: ViewportColor(hex: 0xE5484D),
        axisY: ViewportColor(hex: 0x30A46C),
        axisZ: ViewportColor(hex: 0x3E7BFA),
        referencePlane: ViewportColor(hex: 0x5A6680),
        sketchCurve: ViewportColor(hex: 0x14181F),
        sketchConstruction: ViewportColor(hex: 0x5A6680),
        sketchPreview: ViewportColor(hex: 0x1D2B45, alpha: 0.55),
        sketchPoint: ViewportColor(hex: 0x14181F),
        sketchPointRing: ViewportColor(hex: 0xFFFFFF),
        // The icon's graph-paper ruling, so blue only means "picked".
        sketchGridMinor: ViewportColor(hex: 0x4F8FB0, alpha: 0.10),
        sketchGridMajor: ViewportColor(hex: 0x4F8FB0, alpha: 0.22),
        // Ink at 6 %: a pencil-shaded area on the paper.
        regionFill: ViewportColor(hex: 0x1D2B45, alpha: 0.06),
        regionPickedFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.34),
        handle: ViewportColor(hex: 0x1A73FF),
        measure: ViewportColor(hex: 0x2B2F36),
        edgeHalo: ViewportColor(hex: 0xFFFFFF, alpha: 0.9),
        shadow: ViewportColor(hex: 0x1D2B45, alpha: 0.5),
        skyLight: ViewportColor(hex: 0xF2F5FA),
        groundLight: ViewportColor(hex: 0x8C8A86),
        ambient: 0.42, key: 0.62, fill: 0.20, rim: 0.22, specular: 0.10)

    public static let dark = ViewportPalette(
        // Shifted towards the chrome's navy so the viewport edge doesn't show a hue seam.
        backgroundTop: ViewportColor(hex: 0x2E3340),
        backgroundBottom: ViewportColor(hex: 0x151922),
        body: ViewportColor(hex: 0xB3BDCF),
        edge: ViewportColor(hex: 0x0B0C0E, alpha: 0.95),
        // A step above the bed's navy (the view cube's near face), so parts read as sheets laid on it.
        paper: ViewportColor(hex: 0x2A3344),
        // Full strength: thin wires have to beat the bed's pale ruling.
        wire: ViewportColor(hex: 0xDCE3EE),
        accent: ViewportColor(hex: 0x3B8BFF),
        hover: ViewportColor(hex: 0x7FB2FF),
        selectionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.6),
        hoverFill: ViewportColor(hex: 0x8CBCFF, alpha: 0.32),
        previewEdge: ViewportColor(hex: 0x9CC3FF, alpha: 0.6),
        groundMinor: ViewportColor(hex: 0xA6AFBD, alpha: 0.06),
        groundMajor: ViewportColor(hex: 0xA6AFBD, alpha: 0.13),
        // The icon's dark variant: navy paper with pale-blue ruling.
        bedFill: ViewportColor(hex: 0x14203A),
        bedMinor: ViewportColor(hex: 0x8FB6D8, alpha: 0.13),
        bedMajor: ViewportColor(hex: 0x8FB6D8, alpha: 0.28),
        bedOutline: ViewportColor(hex: 0x8FB6D8, alpha: 0.5),
        axisX: ViewportColor(hex: 0xFF6369),
        axisY: ViewportColor(hex: 0x4CC38A),
        axisZ: ViewportColor(hex: 0x5B93FF),
        referencePlane: ViewportColor(hex: 0x9AA5B8),
        sketchCurve: ViewportColor(hex: 0xF2F4F7),
        sketchConstruction: ViewportColor(hex: 0x9AA5B8),
        sketchPreview: ViewportColor(hex: 0xE4E9F2, alpha: 0.6),
        sketchPoint: ViewportColor(hex: 0xF2F4F7),
        sketchPointRing: ViewportColor(hex: 0x16181C),
        sketchGridMinor: ViewportColor(hex: 0x8FB6D8, alpha: 0.10),
        sketchGridMajor: ViewportColor(hex: 0x8FB6D8, alpha: 0.22),
        // The light paper's cream at 8 %: chalk on the blueprint, not a blue slab.
        regionFill: ViewportColor(hex: 0xF5EFE0, alpha: 0.08),
        regionPickedFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.48),
        handle: ViewportColor(hex: 0x3B8BFF),
        measure: ViewportColor(hex: 0xE6E8EC),
        edgeHalo: ViewportColor(hex: 0x10141C, alpha: 0.85),
        shadow: ViewportColor(hex: 0x03060C, alpha: 0.55),
        skyLight: ViewportColor(hex: 0xDDE3EC),
        groundLight: ViewportColor(hex: 0x5E5C59),
        ambient: 0.36, key: 0.62, fill: 0.18, rim: 0.26, specular: 0.10,
        // The pale body takes the blue less well than the light palette's.
        hiddenPickedEdgeAlpha: 0.6)
}

public extension ViewportPalette {
    /// For Increase Contrast: what's drawn faint to read as behind (picked edges hidden by the
    /// model) comes up, still short of what's in front.
    var increasedContrast: ViewportPalette {
        var p = self
        p.hiddenPickedEdgeAlpha = min(hiddenPickedEdgeAlpha + 0.25, 0.85)
        return p
    }

    /// The colour a reference plane is tinted: the axis its normal runs along (XY takes Z's blue).
    func color(for plane: ReferencePlane) -> ViewportColor {
        switch plane.normalAxis {
        case 0: axisX
        case 1: axisY
        case 2: axisZ
        default: referencePlane
        }
    }
}
