import SwiftUI

public extension VisualStyle {
    /// Sentence case, like the rest of the app's copy.
    var title: String {
        switch self {
        case .shaded: "Shaded"
        case .shadedWithEdges: "Shaded with edges"
        case .shadedWithHiddenEdges: "Shaded with hidden edges"
        case .xray: "X-ray"
        case .wireframe: "Wireframe"
        case .hiddenLine: "Hidden line"
        }
    }

    /// What the style is for, under its name in the picker.
    var detail: String {
        switch self {
        case .shaded: "Surfaces, no lines"
        case .shadedWithEdges: "Surfaces and visible edges"
        case .shadedWithHiddenEdges: "Surfaces, hidden edges dashed"
        case .xray: "See through to the inside"
        case .wireframe: "Every edge, hidden ones dashed"
        case .hiddenLine: "A line drawing, no hidden edges"
        }
    }
}

/// The app's panel type scale (`Theme` in the app target, which this package can't see): text
/// styles that follow Dynamic Type on iPad, the Mac's fixed sizes.
private enum PickerType {
    #if os(iOS) || os(visionOS)
    static let header = Font.system(.subheadline, weight: .semibold)
    static let title = Font.system(.subheadline)
    static let detail = Font.system(.footnote)
    #else
    static let header = Font.system(size: 13, weight: .semibold)
    static let title = Font.system(size: 13)
    static let detail = Font.system(size: 11)
    #endif
}

/// A small cube drawn in a visual style: shaded faces, the edges in front, the three edges at
/// the hidden back corner dashed or faint. The chip and every picker row use it, so the
/// choice is shown rather than named.
struct VisualStyleGlyph: View {
    let style: VisualStyle
    var ink: Color = .primary
    var size: CGFloat = 24
    @Environment(\.colorSchemeContrast) private var contrast

    // Oblique cube in a unit square: front square, back square up and to the right.
    private static let front = [CGPoint(x: 0.10, y: 0.40), CGPoint(x: 0.62, y: 0.40), CGPoint(x: 0.62, y: 0.92), CGPoint(x: 0.10, y: 0.92)]
    private static let back = front.map { CGPoint(x: $0.x + 0.28, y: $0.y - 0.30) }

    var body: some View {
        // X-ray's faint faces would vanish under Increase Contrast.
        let xray: [Double] = contrast == .increased ? [0.14, 0.22, 0.30] : [0.08, 0.13, 0.18]
        Canvas { ctx, sz in
            let s = sz.width
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * s, y: q.y * s) }
            func poly(_ pts: [CGPoint]) -> Path { Path { $0.addLines(pts.map(p)); $0.closeSubpath() } }
            func lines(_ pairs: [(CGPoint, CGPoint)]) -> Path {
                Path { path in for (a, b) in pairs { path.move(to: p(a)); path.addLine(to: p(b)) } }
            }
            let f = Self.front, b = Self.back
            let top = poly([f[0], f[1], b[1], b[0]])
            let side = poly([f[1], b[1], b[2], f[2]])
            let face = poly(f)
            let visible = lines([(f[0], f[1]), (f[1], f[2]), (f[2], f[3]), (f[3], f[0]),
                                 (b[0], b[1]), (b[1], b[2]), (f[0], b[0]), (f[1], b[1]), (f[2], b[2])])
            let hidden = lines([(b[0], b[3]), (b[3], b[2]), (f[3], b[3])])
            let width = max(s / 18, 1)

            switch style.faces {
            case .lit:
                // Three tones of the ink: lit top, mid front, shaded side.
                ctx.fill(top, with: .color(ink.opacity(0.16)))
                ctx.fill(face, with: .color(ink.opacity(0.30)))
                ctx.fill(side, with: .color(ink.opacity(0.46)))
            case .xray:
                ctx.fill(top, with: .color(ink.opacity(xray[0])))
                ctx.fill(face, with: .color(ink.opacity(xray[1])))
                ctx.fill(side, with: .color(ink.opacity(xray[2])))
            case .paper, .none:
                break
            }
            switch style.hiddenEdges {
            case .dashed?:
                // Dashes at least 2 pt, so they still read as dashes at chip size.
                ctx.stroke(hidden, with: .color(ink.opacity(0.75)),
                           style: StrokeStyle(lineWidth: width * 0.85, lineCap: .butt, dash: [max(s / 12, 2), max(s / 14, 1.5)]))
            case .faint?:
                ctx.stroke(hidden, with: .color(ink.opacity(0.4)), style: StrokeStyle(lineWidth: width * 0.85))
            case nil:
                break
            }
            if style.showsEdges {
                ctx.stroke(visible, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The visual style chip under the view cube: the current style's glyph, opening the picker.
struct VisualStyleChip: View {
    @Binding var style: VisualStyle
    let appearance: ViewportAppearance
    let width: CGFloat
    let height: CGFloat
    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 4) {
                VisualStyleGlyph(style: style, ink: appearance.chipInk)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appearance.chipInk)
        .background(appearance.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(appearance.chipInk.opacity(hovering || picking ? 0.08 : 0)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(appearance.chipEdge))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        #if os(iOS) || os(visionOS)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .hoverEffect(.highlight)
        #endif
        .help("Visual style: \(style.title)")
        .accessibilityLabel("Visual style")
        .accessibilityValue(style.title)
        .popover(isPresented: $picking, arrowEdge: .leading) {
            VisualStylePicker(style: $style, appearance: appearance) { picking = false }
                // The chips' surface, not the system's grey, so the list belongs to the viewport chrome.
                .presentationBackground(appearance.chipFill)
                #if os(iOS) || os(visionOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }
}

/// The six styles as a list: glyph, name and what it's for; picking one closes the list.
struct VisualStylePicker: View {
    @Binding var style: VisualStyle
    let appearance: ViewportAppearance
    let done: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Visual style")
                .font(PickerType.header)
                .foregroundStyle(appearance.labelInk(highContrast: contrast == .increased))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(VisualStyle.allCases, id: \.self) { s in
                VisualStyleRow(style: s, selected: s == style, appearance: appearance) {
                    style = s
                    done()
                }
            }
        }
        .padding(8)
        // Wider at accessibility sizes, like the inspector, so names don't wrap word by word.
        .frame(width: typeSize.isAccessibilitySize ? 380 : 300)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private struct VisualStyleRow: View {
    let style: VisualStyle
    let selected: Bool
    let appearance: ViewportAppearance
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    #if os(iOS) || os(visionOS)
    private static let minHeight: CGFloat = 48
    #else
    private static let minHeight: CGFloat = 40
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VisualStyleGlyph(style: style, ink: appearance.chipInk, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(PickerType.title)
                        .foregroundStyle(appearance.chipInk)
                        .lineLimit(2)
                    Text(style.detail)
                        .font(PickerType.detail)
                        .foregroundStyle(appearance.labelInk(highContrast: contrast == .increased))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(appearance.chipInk)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: Self.minHeight)
            // The chips' hover wash; the current style keeps it, with the check.
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appearance.chipInk.opacity(selected ? 0.08 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(iOS) || os(visionOS)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .hoverEffect(.highlight)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityHint(style.detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
