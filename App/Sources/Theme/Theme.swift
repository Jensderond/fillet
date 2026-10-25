import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Fillet's design tokens, taken from the app icon: navy ink line work on cool
/// drafting neutrals, with the fillet orange reserved for "active" (current
/// tool, feature being edited, primary action, rollback marker) and the
/// viewport's blue reserved for "selected in the model".
enum Theme {
    // MARK: Colour

    /// Text and line work.
    static let ink = Color(light: 0x1D2B45, dark: 0xE4E9F2)
    /// Secondary text: labels, subtitles, units. The quietest colour text may use.
    static let inkSecondary = Color(light: 0x5A6680, dark: 0x9AA5B8, highContrastLight: 0x48536B, highContrastDark: 0xB8C1D0)
    /// Non-text marks only (icons, ruler ticks, hatching): 3:1 against the panels, too faint for text.
    static let inkTertiary = Color(light: 0x737D93, dark: 0x7F8AA0, highContrastLight: 0x5E687E, highContrastDark: 0x9AA4B8)
    /// Window chrome behind panels. Dark neutrals lean towards the icon's navy.
    static let chrome = Color(light: 0xE9EDF2, dark: 0x10141C)
    /// Sidebars and inspector.
    static let panel = Color(light: 0xF6F7F9, dark: 0x171C26)
    /// Fields, cards and floating controls.
    static let raised = Color(light: 0xFFFFFF, dark: 0x212836)
    static let hairline = Color(light: 0x1D2B45, dark: 0xFFFFFF, opacity: 0.11, highContrastOpacity: 0.30)
    static let hairlineStrong = Color(light: 0x1D2B45, dark: 0xFFFFFF, opacity: 0.2, highContrastOpacity: 0.45)
    /// Text-field outline: 3:1 against the panel, so the field reads as a field (WCAG 1.4.11).
    static let fieldBorder = Color(light: 0x868FA2, dark: 0x5E687C, highContrastLight: 0x5E687E, highContrastDark: 0x8C96AA)

    /// The fillet orange, for fills (handles, the splash's fillet surface).
    static let fillet = Color(hex: 0xF26B1D)
    /// Orange marks that are controls or state on a panel: caliper, focus ring, active
    /// underline, drop bar. Burnt orange in light (4.6:1 on the panel; the bright orange is
    /// 2.84:1), the bright orange in dark (5.6:1).
    static let filletMark = Color(light: 0xC94F0B, dark: 0xF26B1D)
    static let filletSoft = Color(hex: 0xF26B1D).opacity(0.14)
    /// Burnt orange behind white labels (primary buttons): 4.5:1 with white.
    static let filletFill = Color(hex: 0xC94F0B)
    /// Orange text and glyphs (the active tool, the step being edited).
    static let filletInk = Color(light: 0xC94F0B, dark: 0xFF8A3D)
    /// Model selection; the same blue as the viewport's selection.
    static let select = Color(light: 0x1A73FF, dark: 0x3B8BFF)
    static let selectSoft = select.opacity(0.13)
    /// Blue text ("Clear" on a picked card).
    static let selectInk = Color(light: 0x0B5CD5, dark: 0x4C93FF)
    static let danger = Color(hex: 0xE5484D)
    static let dangerSoft = Color(hex: 0xE5484D).opacity(0.12)
    /// Error text, also on `dangerSoft`.
    static let dangerInk = Color(light: 0xC42B31, dark: 0xFF6369)
    static let ok = Color(hex: 0x2E9E6A)
    static let warn = Color(light: 0xA86E00, dark: 0xD9940F)
    /// The viewport's axis colours (`ViewportPalette.axisX` …), which also tint the origin
    /// planes: a plane takes the colour of the axis it faces along (XY takes Z's blue).
    static let axisX = Color(light: 0xE5484D, dark: 0xFF6369)
    static let axisY = Color(light: 0x30A46C, dark: 0x4CC38A)
    static let axisZ = Color(light: 0x3E7BFA, dark: 0x5B93FF)

    // MARK: Shape

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let floating: CGFloat = 14
    }

    /// Spacing on a 4 pt grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Hit targets. Touch gets 44 pt everywhere; the pointer keeps the denser Mac sizes.
    enum Metrics {
        static func target(touch: Bool) -> CGFloat { touch ? 44 : 32 }
        static func targetCompact(touch: Bool) -> CGFloat { touch ? 44 : 28 }
        /// Text buttons (Done, Cancel, Finish sketch).
        static func button(touch: Bool) -> CGFloat { touch ? 44 : 34 }
        #if os(iOS)
        static let prefersTouch = true
        #else
        static let prefersTouch = false
        #endif
    }

    // MARK: Motion

    /// Strong ease-out curves (Emil Kowalski's design-engineering rules): UI motion
    /// stays under 300 ms, exits are faster than entrances, keyboard-triggered
    /// changes don't animate, and nothing grows from zero.
    enum Motion {
        /// Press feedback on buttons and chips.
        static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
        /// Panels, toasts and toolbars entering.
        static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
        /// Leaving is quicker than arriving.
        static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
        /// Things moving on screen (the rollback marker).
        static let move = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.26)
        /// Hover and colour changes.
        static let hover = Animation.easeOut(duration: 0.12)
    }

    // MARK: Type

    /// Technical-drawing face at an explicit size (splash artwork only; UI uses `label` and `micro`).
    static func condensed(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    // Seven styles: title, section title, body, value, caption, and the two condensed labels.
    // iPad uses text styles, so they follow Dynamic Type and read at arm's length
    // (body 15 pt); the Mac keeps its denser point sizes (body 13 pt).
    #if os(iOS)
    static let title = Font.system(.headline)
    static let sectionTitle = Font.system(.subheadline, weight: .semibold)
    static let body = Font.system(.subheadline)
    static let caption = Font.system(.footnote)
    static let value = Font.system(.subheadline, weight: .medium).monospacedDigit()
    /// Condensed technical label: tool names, timeline steps.
    static let label = Font.system(.caption, weight: .medium).width(.condensed)
    /// Smallest condensed label: ruler numbers, view-cube faces.
    static let micro = Font.system(.caption2, weight: .semibold).width(.condensed)
    #else
    static let title = Font.system(size: 17, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let value = Font.system(size: 13, weight: .medium).monospacedDigit()
    /// Condensed technical label: tool names, timeline steps.
    static let label = Font.system(size: 11, weight: .medium).width(.condensed)
    /// Smallest condensed label: ruler numbers, view-cube faces.
    static let micro = Font.system(size: 10, weight: .semibold).width(.condensed)
    #endif

    /// Dynamic Type ceilings. Fixed-geometry chrome (tool strip, sketch bar, timeline) stops
    /// at xLarge; the scrolling panels go up to accessibility2.
    enum TypeLimit {
        static let chrome = DynamicTypeSize.xLarge
        static let panel = DynamicTypeSize.accessibility2
    }

    // MARK: Copy

    enum Copy {
        /// The pointing verb: "Click" with a pointer, "Tap" on iPad.
        #if os(iOS)
        static let pick = "Tap"
        #else
        static let pick = "Click"
        #endif
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A colour that follows the light/dark appearance and, optionally, Increase Contrast.
    init(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil,
         opacity: Double = 1, highContrastOpacity: Double? = nil) {
        func components(dark isDark: Bool, high: Bool) -> (r: Double, g: Double, b: Double, a: Double) {
            let hex = high ? (isDark ? highContrastDark ?? dark : highContrastLight ?? light) : (isDark ? dark : light)
            return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255,
                    high ? highContrastOpacity ?? opacity : opacity)
        }
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let c = components(dark: traits.userInterfaceStyle == .dark, high: traits.accessibilityContrast == .high)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let high = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let c = components(dark: isDark, high: high)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #endif
    }
}

// MARK: - Button styles

/// Solid burnt-orange action with a white label ("Done", "Finish sketch"). Darkens a touch
/// under the pointer and a little more when pressed.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.touchTargets) private var touch

        var body: some View {
            configuration.label
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: Theme.Metrics.button(touch: touch))
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.filletFill.opacity(isEnabled ? 1 : 0.4))
                        .brightness(configuration.isPressed ? -0.08 : hovering && isEnabled ? -0.04 : 0))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .onHover { hovering = $0 }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Theme.Motion.press, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: hovering)
        }
    }
}

/// Quiet raised action ("Cancel", "Clear"), with a hairline wash under the pointer.
struct SecondaryButtonStyle: ButtonStyle {
    var role: ButtonRole?

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, role: role) }

    private struct Styled: View {
        let configuration: Configuration
        let role: ButtonRole?
        @State private var hovering = false
        @Environment(\.touchTargets) private var touch

        var body: some View {
            configuration.label
                .font(Theme.body.weight(.medium))
                .foregroundStyle(role == .destructive ? Theme.dangerInk : Theme.ink)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Metrics.button(touch: touch))
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.raised)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(configuration.isPressed || hovering ? Theme.hairline : .clear)))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .onHover { hovering = $0 }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Theme.Motion.press, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: hovering)
        }
    }
}

/// Text-only action inside cards ("Clear", "Add parameter"). Ink by default; pass
/// `selectInk` for actions on picked things and `filletInk` only for a real primary action.
struct InlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A hit area that reaches `bleed` past the top and bottom of a control without moving it.
/// A touch that lands on no control (a row's label, the 8–12 pt gaps between inspector rows)
/// is handed by SwiftUI to a control near it, and not always the nearest: 2 pt under the
/// Rotation field went to Delete, 6 pt further down. A finger lands a little below where it
/// aims, so a near miss on a row went to the next control down. Rows that own their label and
/// the near half of each gap take those taps themselves. Keep `bleed` at most half the stack
/// spacing so neighbours never overlap.
struct VerticalBleed: SwiftUI.Shape {
    var bleed: CGFloat
    init(_ bleed: CGFloat) { self.bleed = bleed }
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -bleed)) }
}

// MARK: - Containers

/// A titled group of controls in a panel.
struct PanelSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title {
                Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.ink)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A glyph in a small raised square with a drafting-stamp outline, for features and selections.
/// The tint goes on the glyph only (orange editing, blue picked, ink otherwise).
struct IconChip: View {
    let symbol: String
    var tint: Color = Theme.filletInk
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

extension AnyTransition {
    /// Panel/toast entrance: slides a little from `edge` and fades; leaves faster, fading only.
    static func panel(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(x: edge == .leading ? -12 : edge == .trailing ? 12 : 0,
                                              y: edge == .top ? -8 : edge == .bottom ? 8 : 0))
                .combined(with: .scale(scale: 0.96, anchor: edge.anchor))
        return .asymmetric(insertion: insertion.animation(Theme.Motion.enter),
                           removal: .opacity.animation(Theme.Motion.exit))
    }
}

extension Edge {
    var anchor: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// Crossfade with a 2 pt blur so changing text reads as one morph rather than two overlapping labels.
struct BlurCrossfade: ViewModifier {
    let value: String
    func body(content: Content) -> some View {
        content
            .id(value)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .modifier(active: BlurModifier(radius: 2), identity: BlurModifier(radius: 0)))
                    .animation(Theme.Motion.enter),
                removal: .opacity.animation(Theme.Motion.exit)))
    }
}

/// Edge fades on a horizontal `ScrollView`, shown only on the side that has more content.
struct OverflowFade: ViewModifier {
    var width: CGFloat
    @State private var more = Edges()

    struct Edges: Equatable {
        var leading = false
        var trailing = false
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Edges.self) { g in
                Edges(leading: g.contentOffset.x > 1,
                      trailing: g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1)
            } action: { _, edges in more = edges }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [more.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                    Color.black
                    LinearGradient(colors: [.black, more.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                }
            }
    }
}

/// Bottom fade on a vertical `ScrollView`, shown only while content continues below.
///
/// Drawn over the content in the background colour, not as a `.mask`: inside a `DocumentGroup`
/// on iPad, a masked `ScrollView` is drawn a toolbar's height (54 pt) below where SwiftUI
/// hit-tests it, so every tap in the inspector landed on the control a row further down.
struct BottomFade: ViewModifier {
    var height: CGFloat
    var color: Color
    @State private var more = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1
            } action: { _, value in more = value }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [color.opacity(0), color.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .opacity(more ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension EnvironmentValues {
    /// Touch-sized (44 pt) hit targets: on for iPad, off for the Mac pointer.
    /// The debug iPad-layout render turns it on to check the touch layout on a Mac.
    @Entry var touchTargets: Bool = Theme.Metrics.prefersTouch
}

#if os(macOS)
/// The Mac's hover feedback: a hairline plate behind the control while the pointer is over it.
private struct PointerHoverPlate: ViewModifier {
    let cornerRadius: CGFloat
    let enabled: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering && isEnabled ? Theme.hairline : .clear))
                .onHover { hovering = $0 }
                .animation(Theme.Motion.hover, value: hovering)
        } else {
            content
        }
    }
}
#endif

/// Floating chrome (toasts, the sketch toolbar): one shadow, a hairline edge, and in dark
/// mode a faint top highlight, since a black shadow alone disappears on dark panels.
struct FloatingElevation: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.floating
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Theme.raised))
            .overlay(shape.strokeBorder(Theme.hairline))
            .overlay(alignment: .top) {
                if colorScheme == .dark {
                    shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25)))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 16, y: 6)
    }
}

extension View {
    /// Raised fill, hairline edge and the floating shadow.
    func floatingElevation(cornerRadius: CGFloat = Theme.Radius.floating) -> some View {
        modifier(FloatingElevation(cornerRadius: cornerRadius))
    }

    /// Pointer-only hover feedback (no false positives from touch), shaped like the control's
    /// background: the system highlight on iPad, a hairline plate on the Mac. Views that draw
    /// their own hover state pass `ownsPointerHover` so the Mac doesn't stack a second one.
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.control, ownsPointerHover: Bool = false) -> some View {
        #if os(iOS)
        self.contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
        #else
        modifier(PointerHoverPlate(cornerRadius: cornerRadius, enabled: !ownsPointerHover))
        #endif
    }

    /// Fades the bottom of a vertical scroll view into `color` (its background) while there's more below.
    func scrollEdgeFade(height: CGFloat = Theme.Space.xl, color: Color = Theme.panel) -> some View {
        modifier(BottomFade(height: height, color: color))
    }

    /// Fades the edges of a horizontal scroll view while there's more to scroll that way.
    func overflowFade(width: CGFloat = Theme.Space.l) -> some View { modifier(OverflowFade(width: width)) }

    func blurCrossfade(_ value: String) -> some View { modifier(BlurCrossfade(value: value)) }
}
