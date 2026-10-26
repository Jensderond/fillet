import FilletCore
import FilletKernel
import SwiftUI

/// Measure's panel, where the inspector goes: what each pick measures, and between two picks the
/// shortest distance, its X, Y and Z parts and the angle. Every value can be copied.
struct MeasureInspector: View {
    @Bindable var session: DesignSession

    private var state: MeasureState { session.measure ?? MeasureState() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            InspectorHeader(symbol: "ruler", title: "Measure", subtitle: subtitle)
            Labeled("Pick") {
                ThemeSegmented("Pick", selection: state.picksBodies, options: [(false, "Faces & edges"), (true, "Bodies")]) {
                    session.setMeasurePicksBodies($0)
                }
            }
            if state.picks.isEmpty {
                Hint(state.picksBodies
                     ? "Pick a body for its volume and size, or two for the distance between them."
                     : "Pick an edge for its length, a face for its area, or two things for the distance and angle between them.",
                     symbol: "ruler")
            }
            ForEach(Array(zip(state.picks.indices, state.picks)), id: \.0) { i, pick in
                if let item = state.items[i] { card(pick, item) }
            }
            if let pair = state.pair { between(pair) }
        }
        .automationFrame("measure-panel")
    }

    private var subtitle: String {
        switch state.picks.count {
        case 0: "Pick up to two things"
        case 1: "1 picked, pick another to compare"
        default: "2 picked, a third pick starts over"
        }
    }

    // MARK: Cards

    @ViewBuilder private func card(_ pick: MeasurePick, _ m: ItemMeasurement) -> some View {
        switch m.element {
        case .body:
            MeasureCard(symbol: "cube", title: session.model.body(pick.body)?.name ?? "Body") {
                if let v = m.volume { MeasureValueRow("Volume", "\(fmt(v / 1000)) cm³") }
                if let s = m.size { MeasureValueRow("Size", "\(fmt(s.x)) × \(fmt(s.y)) × \(fmt(s.z)) mm") }
            }
        case .face:
            MeasureCard(symbol: "square.fill", title: "\((m.surface ?? .other).title) face") {
                if let a = m.area { MeasureValueRow("Area", "\(fmt(a)) mm²") }
                radiusRows(m.radius)
            }
        case .edge:
            MeasureCard(symbol: "line.diagonal", title: "\((m.curve ?? .other).title) edge") {
                if let l = m.length { MeasureValueRow("Length", "\(fmt(l)) mm") }
                radiusRows(m.radius)
            }
        case .vertex:
            MeasureCard(symbol: "smallcircle.filled.circle", title: "Vertex") {
                if let p = m.position {
                    MeasureValueRow("X", "\(fmt(p.x)) mm")
                    MeasureValueRow("Y", "\(fmt(p.y)) mm")
                    MeasureValueRow("Z", "\(fmt(p.z)) mm")
                }
            }
        }
    }

    @ViewBuilder private func radiusRows(_ radius: Double?) -> some View {
        if let r = radius {
            MeasureValueRow("Radius", "\(fmt(r)) mm")
            MeasureValueRow("Diameter", "\(fmt(r * 2)) mm")
        }
    }

    /// Ink, like the dimension line it describes on the canvas.
    private func between(_ pair: PairMeasurement) -> some View {
        MeasureCard(symbol: "ruler", title: "Between", tint: Theme.ink) {
            MeasureValueRow("Distance", "\(fmt(pair.distance)) mm", prominent: true)
            MeasureValueRow("ΔX", "\(fmt(abs(pair.delta.x))) mm")
            MeasureValueRow("ΔY", "\(fmt(abs(pair.delta.y))) mm")
            MeasureValueRow("ΔZ", "\(fmt(abs(pair.delta.z))) mm")
            if let a = pair.angle { MeasureValueRow("Angle", "\(fmt(a * 180 / .pi))°") }
        }
        .automationFrame("measure-between")
    }

    private func fmt(_ v: Double) -> String { DesignSession.measureFormat(v) }
}

/// Clear and Done, pinned to the bottom of the inspector while measuring.
struct MeasureFooter: View {
    let canClear: Bool
    let clear: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Clear", action: clear)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canClear)
            Button(action: done) {
                Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }
}

/// One measured thing: what it is, then its values.
private struct MeasureCard<Content: View>: View {
    let symbol: String
    let title: String
    var tint: Color = Theme.select
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                IconChip(symbol: symbol, tint: tint, size: 28)
                Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.bottom, Theme.Space.xs)
            content
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A label and a value with a copy button. The value copies as shown ("12.5 mm", "90°"), which
/// the app's own fields read back as an expression.
private struct MeasureValueRow: View {
    let label: String
    let value: String
    var prominent = false
    @State private var copied = false
    @Environment(\.touchTargets) private var touch

    init(_ label: String, _ value: String, prominent: Bool = false) {
        self.label = label; self.value = value; self.prominent = prominent
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.body).foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Theme.Space.s)
            Text(value)
                .font(prominent ? Theme.title.monospacedDigit() : Theme.value)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Theme.ok : Theme.inkTertiary)
                    .frame(width: touch ? 40 : 24, height: touch ? 40 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .hoverHighlight()
            .help("Copy \(value)")
            .accessibilityLabel("Copy \(label)")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        copied = true
    }
}
