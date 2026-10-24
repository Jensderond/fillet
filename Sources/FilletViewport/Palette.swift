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
    public var sketchCurve: ViewportColor
    /// Dashed construction geometry: slate, so orange keeps meaning "active".
    public var sketchConstruction: ViewportColor
    /// The shape being drawn (rubber band): a ghosted ink stroke, not the selection blue.
    public var sketchPreview: ViewportColor
    public var sketchPoint: ViewportColor
    public var sketchPointRing: ViewportColor
    public var sketchGridMinor: ViewportColor
    public var sketchGridMajor: ViewportColor
    public var regionFill: ViewportColor
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

    public static let light = ViewportPalette(
        backgroundTop: ViewportColor(hex: 0xF7F8FA),
        backgroundBottom: ViewportColor(hex: 0xDDE1E7),
        body: .defaultBody,
        edge: ViewportColor(hex: 0x23272E, alpha: 0.92),
        accent: ViewportColor(hex: 0x1A73FF),
        hover: ViewportColor(hex: 0x69A6FF),
        selectionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.6),
        hoverFill: ViewportColor(hex: 0x8CBCFF, alpha: 0.35),
        previewEdge: ViewportColor(hex: 0x1F4FA8, alpha: 0.55),
        groundMinor: ViewportColor(hex: 0x6B7380, alpha: 0.07),
        groundMajor: ViewportColor(hex: 0x6B7380, alpha: 0.15),
        bedFill: ViewportColor(hex: 0xD3D8E0, alpha: 0.92),
        bedMinor: ViewportColor(hex: 0x6E7787, alpha: 0.16),
        bedMajor: ViewportColor(hex: 0x6E7787, alpha: 0.30),
        bedOutline: ViewportColor(hex: 0x8C95A4, alpha: 0.95),
        axisX: ViewportColor(hex: 0xE5484D),
        axisY: ViewportColor(hex: 0x30A46C),
        axisZ: ViewportColor(hex: 0x3E7BFA),
        sketchCurve: ViewportColor(hex: 0x14181F),
        sketchConstruction: ViewportColor(hex: 0x5A6680),
        sketchPreview: ViewportColor(hex: 0x1D2B45, alpha: 0.55),
        sketchPoint: ViewportColor(hex: 0x14181F),
        sketchPointRing: ViewportColor(hex: 0xFFFFFF),
        // The icon's graph-paper ruling, so blue only means "picked".
        sketchGridMinor: ViewportColor(hex: 0x4F8FB0, alpha: 0.10),
        sketchGridMajor: ViewportColor(hex: 0x4F8FB0, alpha: 0.22),
        regionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.10),
        handle: ViewportColor(hex: 0x1A73FF),
        measure: ViewportColor(hex: 0x2B2F36),
        edgeHalo: ViewportColor(hex: 0xFFFFFF, alpha: 0.9),
        shadow: ViewportColor(hex: 0x1C2633, alpha: 0.22),
        skyLight: ViewportColor(hex: 0xF2F5FA),
        groundLight: ViewportColor(hex: 0x8C8A86),
        ambient: 0.42, key: 0.62, fill: 0.20, rim: 0.22, specular: 0.10)

    public static let dark = ViewportPalette(
        // Shifted towards the chrome's navy so the viewport edge doesn't show a hue seam.
        backgroundTop: ViewportColor(hex: 0x2E3340),
        backgroundBottom: ViewportColor(hex: 0x151922),
        body: ViewportColor(hex: 0xB9BEC6),
        edge: ViewportColor(hex: 0x0B0C0E, alpha: 0.95),
        accent: ViewportColor(hex: 0x3B8BFF),
        hover: ViewportColor(hex: 0x7FB2FF),
        selectionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.6),
        hoverFill: ViewportColor(hex: 0x8CBCFF, alpha: 0.32),
        previewEdge: ViewportColor(hex: 0x9CC3FF, alpha: 0.6),
        groundMinor: ViewportColor(hex: 0xA6AFBD, alpha: 0.06),
        groundMajor: ViewportColor(hex: 0xA6AFBD, alpha: 0.13),
        bedFill: ViewportColor(hex: 0x2A2E35, alpha: 0.85),
        bedMinor: ViewportColor(hex: 0x9AA3B2, alpha: 0.09),
        bedMajor: ViewportColor(hex: 0x9AA3B2, alpha: 0.18),
        bedOutline: ViewportColor(hex: 0x6F7887, alpha: 0.9),
        axisX: ViewportColor(hex: 0xFF6369),
        axisY: ViewportColor(hex: 0x4CC38A),
        axisZ: ViewportColor(hex: 0x5B93FF),
        sketchCurve: ViewportColor(hex: 0xF2F4F7),
        sketchConstruction: ViewportColor(hex: 0x9AA5B8),
        sketchPreview: ViewportColor(hex: 0xE4E9F2, alpha: 0.6),
        sketchPoint: ViewportColor(hex: 0xF2F4F7),
        sketchPointRing: ViewportColor(hex: 0x16181C),
        sketchGridMinor: ViewportColor(hex: 0x8FB6D8, alpha: 0.10),
        sketchGridMajor: ViewportColor(hex: 0x8FB6D8, alpha: 0.22),
        regionFill: ViewportColor(hex: 0x2E9CFF, alpha: 0.14),
        handle: ViewportColor(hex: 0x3B8BFF),
        measure: ViewportColor(hex: 0xE6E8EC),
        edgeHalo: ViewportColor(hex: 0x10141C, alpha: 0.85),
        shadow: ViewportColor(hex: 0x000000, alpha: 0.38),
        skyLight: ViewportColor(hex: 0xDDE3EC),
        groundLight: ViewportColor(hex: 0x5E5C59),
        ambient: 0.36, key: 0.62, fill: 0.18, rim: 0.26, specular: 0.10)
}
