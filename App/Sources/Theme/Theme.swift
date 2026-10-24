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
    static let inkSecondary = Color(light: 0x5A6680, dark: 0x9AA5B8)
    static let inkTertiary = Color(light: 0x8A93A6, dark: 0x6C7689)
    /// Window chrome behind panels.
    static let chrome = Color(light: 0xE9EDF2, dark: 0x121519)
    /// Sidebars and inspector.
    static let panel = Color(light: 0xF6F7F9, dark: 0x1B1F25)
    /// Fields, cards and floating controls.
    static let raised = Color(light: 0xFFFFFF, dark: 0x252A32)
    static let hairline = Color(light: 0x1D2B45, dark: 0xFFFFFF).opacity(0.11)
    static let hairlineStrong = Color(light: 0x1D2B45, dark: 0xFFFFFF).opacity(0.2)

    /// The fillet orange: active state and primary actions.
    static let fillet = Color(hex: 0xF26B1D)
    static let filletSoft = Color(hex: 0xF26B1D).opacity(0.14)
    /// Model selection (matches the viewport's selection colour).
    static let select = Color(hex: 0x1F7BFF)
    static let selectSoft = Color(hex: 0x1F7BFF).opacity(0.13)
    static let danger = Color(hex: 0xE5484D)
    static let dangerSoft = Color(hex: 0xE5484D).opacity(0.12)
    static let ok = Color(hex: 0x2E9E6A)
    static let warn = Color(hex: 0xD9940F)

    // MARK: Shape

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let floating: CGFloat = 14
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

    /// Technical-drawing labels for tools and timeline steps.
    static func condensed(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    static let title = Font.system(size: 17, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let value = Font.system(size: 13, weight: .medium).monospacedDigit()
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A colour that follows the light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #endif
    }
}

// MARK: - Button styles

/// Solid fillet-orange action ("Done", "Finish sketch").
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.fillet.opacity(isEnabled ? 1 : 0.4))
                    .brightness(configuration.isPressed ? -0.08 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Quiet raised action ("Cancel", "Clear").
struct SecondaryButtonStyle: ButtonStyle {
    var role: ButtonRole?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(role == .destructive ? Theme.danger : Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Theme.hairline : Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Text-only action inside cards ("Clear", "Add parameter").
struct InlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.fillet
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
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
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.ink)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Raised card with a hairline border.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.1)) } ?? AnyShapeStyle(Theme.raised)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(Theme.hairline), lineWidth: 1))
    }
}

/// Small rounded-square icon badge used for features and tools.
struct IconChip: View {
    let symbol: String
    var tint: Color = Theme.fillet
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.14)))
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

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension View {
    /// Pointer-only hover feedback (no false positives from touch).
    func hoverHighlight() -> some View {
        #if os(iOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
    }

    func blurCrossfade(_ value: String) -> some View { modifier(BlurCrossfade(value: value)) }
}
