import FilletViewport
import SwiftUI

/// Over the viewport while Box select is on: what a box picks, how its direction matters
/// (Fusion's convention: drag right for what's wholly inside, left for anything it touches),
/// outside a step a choice of edges, faces or bodies, and Done. Built like the sketch-plane bar.
struct BoxSelectBar: View {
    @Bindable var session: DesignSession
    @Environment(\.touchTargets) private var touch
    @Environment(\.colorScheme) private var colorScheme

    /// "edges" while a fillet picks edges, the chosen kind outside a step.
    private var noun: String {
        switch session.pickMode {
        case .edges: "edges"
        case .faces: "faces"
        case .bodies: "bodies"
        default: session.boxPicks.rawValue
        }
    }

    /// Outside a step the bar offers what to box; a step decides for itself.
    private var choosesKind: Bool { session.pickMode == .idle }

    var body: some View {
        // The legend, then the prompt, fold away when the bar runs out of room (Split View, big text).
        ViewThatFits(in: .horizontal) {
            bar(legend: true, prompt: true, kindTitles: true)
            bar(legend: false, prompt: true, kindTitles: true)
            bar(legend: false, prompt: true, kindTitles: false)
            bar(legend: false, prompt: false, kindTitles: false)
        }
        .onAppear { AccessibilityNotification.Announcement("Box select on. Drag across \(noun) to select them.").post() }
        .automationMarker("box-select-bar")
        .automationFrame("box-select-bar")
    }

    private func bar(legend: Bool, prompt: Bool, kindTitles: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.selectInk)
                    .accessibilityHidden(true)
                if prompt {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Drag across \(noun)").font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                        if legend { legendLine }
                    }
                    .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drag across \(noun) to select them. Drag right for what is inside the box, left for what it touches.")
            if choosesKind {
                divider
                HStack(spacing: 2) {
                    ForEach(BoxPicks.allCases, id: \.self) { kind in
                        KindChip(kind: kind, selected: session.boxPicks == kind, showsTitle: kindTitles) { session.boxPicks = kind }
                    }
                }
                // On a recessed track with the chosen one raised, as in the app's segmented control.
                .padding(2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
                    .fill(colorScheme == .dark ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Theme.hairline)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Box picks")
            }
            divider
            Button("Done") { session.toggleBoxSelect() }
                .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: touch ? 44 : 28)
                .contentShape(Rectangle())
                .hoverHighlight()
                .help("Turn Box select off [Esc]")
                .automationFrame("box-select.done")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: touch ? 52 : 36)
        .floatingElevation(cornerRadius: touch ? 26 : 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Box select")
    }

    /// "→ inside  ← touching", with the rims the box draws: solid for a window, dashed for crossing.
    private var legendLine: some View {
        HStack(spacing: Theme.Space.s) {
            LegendItem(arrow: "arrow.right", dashed: false, text: "inside")
            LegendItem(arrow: "arrow.left", dashed: true, text: "touching")
        }
        .accessibilityHidden(true)
    }

    private var divider: some View { Theme.hairlineStrong.frame(width: 1, height: 16) }
}

/// One half of the legend: the drag direction, a tiny box rim in that style, and what it takes.
private struct LegendItem: View {
    let arrow: String
    let dashed: Bool
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 9, weight: .bold))
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(Theme.select, style: StrokeStyle(lineWidth: 1.25, dash: dashed ? [2.5, 1.5] : []))
                .background(RoundedRectangle(cornerRadius: 1.5).fill(Theme.select.opacity(dashed ? 0.06 : 0.14)))
                .frame(width: 13, height: 9)
            Text(text)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkSecondary)
    }
}

/// Edges, faces or bodies: the kind a box picks outside a step. Selected is the raised thumb of
/// the app's segmented control, so "chosen" has one look.
private struct KindChip: View {
    let kind: BoxPicks
    let selected: Bool
    /// Narrow bars show the glyph alone (still 44 pt wide on touch, and named for VoiceOver).
    var showsTitle = true
    let action: () -> Void
    @Environment(\.touchTargets) private var touch
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private var symbol: String {
        switch kind {
        case .edges: "line.diagonal"
        case .faces: "square.fill"
        case .bodies: "cube"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? (isDark ? Theme.raised : Theme.selectInk) : Theme.inkSecondary)
                if showsTitle {
                    Text(kind.title)
                        .font(Theme.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (isDark ? Theme.raised : Theme.ink) : Theme.inkSecondary)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            // 40 + the track's 2 pt rim = 44 on touch; the hit area reaches over the rim (as ThemeSegmented).
            .frame(minWidth: touch ? 40 : 26, minHeight: touch ? 40 : 26)
            .background {
                // The segmented control's "chosen": a raised thumb with a rim (light), a slate plate (dark).
                let plate = RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                if selected {
                    if isDark {
                        plate.fill(Theme.inkSecondary)
                    } else {
                        plate.fill(Theme.raised)
                            .overlay(plate.strokeBorder(Theme.inkTertiary, lineWidth: 1))
                            .shadow(color: Theme.ink.opacity(0.08), radius: 1.5, y: 1)
                    }
                }
            }
            .contentShape(VerticalBleed(2))
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight()
        .animation(Theme.Motion.hover, value: selected)
        .help("Boxes pick \(kind.rawValue)")
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .automationFrame("box-picks.\(kind.rawValue)")
    }
}
