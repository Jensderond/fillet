import FilletCore
import SwiftUI

/// The parametric timeline, drawn as a measuring ruler along the bottom of the window.
///
/// Every feature is a station at an even interval with a numbered tick. Tap a
/// station to change it; later steps replay. Drag stations to reorder (refused
/// when a step would land before something it uses). The orange caliper is the
/// rollback marker; steps past it are hatched like a section view.
struct TimelineView: View {
    @Bindable var session: DesignSession
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var dropTarget: Int?
    @Namespace private var markerSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stationWidth: CGFloat = 70

    private var doc: Document { session.document }
    private var markerIndex: Int { doc.activeFeatureCount }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            playback
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .bottomLeading) {
                        RulerTicks(count: doc.features.count, stationWidth: Self.stationWidth)
                        HStack(spacing: 0) {
                            if doc.features.isEmpty {
                                emptyState
                            }
                            ForEach(Array(doc.features.enumerated()), id: \.element.id) { index, feature in
                                if index == markerIndex { marker }
                                station(feature, index: index)
                                    .id(feature.id)
                            }
                            if markerIndex >= doc.features.count, !doc.features.isEmpty { marker }
                            Color.clear.frame(width: 48, height: 60)
                                .dropDestination(for: String.self) { items, _ in drop(items, at: doc.features.count) }
                        }
                        .animation(reduceMotion ? nil : Theme.Motion.move, value: markerIndex)
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: doc.features.count) { _, _ in
                    withAnimation(Theme.Motion.enter) { proxy.scrollTo("marker", anchor: .trailing) }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .frame(height: 80)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .alert("Rename step", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = renaming { session.rename(id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var emptyState: some View {
        Label("Steps appear here as you design. \(Theme.Copy.pick) one later to change it.", systemImage: "ruler")
            .font(Theme.body)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 60)
    }

    // MARK: Playback

    private var playback: some View {
        ToolCluster {
            playbackButton("backward.end.fill", "Roll back to start") { session.moveRollbackMarker(to: 0) }
                .disabled(markerIndex == 0)
            playbackButton("backward.frame.fill", "Step back") { session.moveRollbackMarker(to: max(markerIndex - 1, 0)) }
                .disabled(markerIndex == 0)
            playbackButton("forward.frame.fill", "Step forward") {
                session.moveRollbackMarker(to: markerIndex + 1 >= doc.features.count ? nil : markerIndex + 1)
            }
            .disabled(markerIndex >= doc.features.count)
            playbackButton("forward.end.fill", "Play to end") { session.moveRollbackMarker(to: nil) }
                .disabled(markerIndex >= doc.features.count)
        }
    }

    private func playbackButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .hoverHighlight()
    }

    // MARK: Stations

    private func station(_ feature: Feature, index: Int) -> some View {
        let status = session.model.status[feature.id] ?? .inactive
        let failed: String? = if case .failed(let m) = status { m } else { nil }
        return Button {
            open(feature)
        } label: {
            StationLabel(
                feature: feature, number: index + 1, rolledBack: index >= markerIndex,
                editing: session.editing?.feature == feature.id, failure: failed,
                dropTarget: dropTarget == index)
        }
        .buttonStyle(PressableStyle())
        .help(failed.map { "\(feature.name): \($0)" } ?? "\(feature.name). \(Theme.Copy.pick) to edit.")
        .accessibilityLabel("Step \(index + 1), \(feature.name)\(failed != nil ? ", failed" : "")")
        .draggable("feature:\(feature.id.uuidString)") {
            IconChip(symbol: feature.kind.symbol, tint: Theme.filletInk, size: 34)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, at: index)
        } isTargeted: { targeted in
            dropTarget = targeted ? index : (dropTarget == index ? nil : dropTarget)
        }
        .contextMenu {
            Button { open(feature) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            Button {
                newName = feature.name
                renaming = feature.id
            } label: { Label("Rename…", systemImage: "character.cursor.ibeam") }
            Button {
                session.setSuppressed(feature.id, !feature.suppressed)
            } label: {
                Label(feature.suppressed ? "Unsuppress" : "Suppress", systemImage: feature.suppressed ? "eye" : "eye.slash")
            }
            Button {
                session.moveRollbackMarker(to: index + 1 >= doc.features.count ? nil : index + 1)
            } label: { Label("Roll back to here", systemImage: "arrow.uturn.backward.circle") }
            if let failed { Text(failed) }
            Divider()
            Button(role: .destructive) { session.deleteFeature(feature.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// The rollback caliper: drag it onto a step to roll back to just after that step.
    private var marker: some View {
        // Zero layout width keeps the ruler graduations aligned with the stations.
        Color.clear
            .frame(width: 0, height: 64)
            .overlay { RollbackCaliper() }
            .matchedGeometryEffect(id: "marker", in: markerSpace)
            .id("marker")
            .draggable("rollback") { RollbackCaliper() }
            .help("Rollback marker — drag onto a step to see the model at that point")
            .accessibilityLabel("Rollback marker after step \(markerIndex)")
    }

    private func open(_ feature: Feature) {
        if case .sketch = feature.kind {
            session.editSketch(feature.id)
        } else {
            session.beginEdit(feature.id)
        }
    }

    /// Handles a drop of a step (reorder) or the marker (rollback) before `index`.
    private func drop(_ items: [String], at index: Int) -> Bool {
        dropTarget = nil
        guard let item = items.first else { return false }
        if item == "rollback" {
            session.moveRollbackMarker(to: index + 1 >= doc.features.count ? nil : index + 1)
            return true
        }
        guard item.hasPrefix("feature:"), let id = UUID(uuidString: String(item.dropFirst(8))),
            let from = doc.index(of: id)
        else { return false }
        let target = from < index ? index - 1 : index
        guard target != from else { return false }
        if !session.moveFeature(id, to: target) {
            session.message = .error("\(doc.feature(id)?.name ?? "That step") can't move there: it uses an earlier step")
            return false
        }
        return true
    }
}

/// One step on the ruler.
private struct StationLabel: View {
    let feature: Feature
    let number: Int
    let rolledBack: Bool
    let editing: Bool
    let failure: String?
    let dropTarget: Bool

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: feature.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 40, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chipFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(chipBorder, style: StrokeStyle(lineWidth: editing ? 1.5 : 1, dash: feature.suppressed ? [3, 2] : [])))
                if failure != nil {
                    Circle().fill(Theme.danger)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            Text(feature.name)
                .font(editing ? Theme.label.weight(.semibold) : Theme.label)
                .foregroundStyle(failure != nil ? Theme.dangerInk : editing ? Theme.ink : Theme.inkSecondary)
                .strikethrough(feature.suppressed)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: TimelineView.stationWidth, height: 54, alignment: .top)
        .padding(.bottom, 10)
        .background(alignment: .center) {
            if rolledBack { SectionHatch().opacity(0.6) }
        }
        .opacity(rolledBack ? 0.5 : 1)
        .overlay(alignment: .leading) {
            if dropTarget { Capsule().fill(Theme.fillet).frame(width: 2.5, height: 44) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
    }

    private var iconColor: Color {
        if failure != nil { return Theme.danger }
        return editing ? Theme.filletInk : Theme.ink
    }

    private var chipFill: Color {
        if editing { return Theme.filletSoft }
        if failure != nil { return Theme.dangerSoft }
        return hovering ? Theme.raised : Theme.raised.opacity(0.7)
    }

    private var chipBorder: Color {
        if editing { return Theme.fillet }
        if failure != nil { return Theme.danger.opacity(0.5) }
        return hovering ? Theme.hairlineStrong : Theme.hairline
    }
}

/// Ruler graduations under the stations: a major numbered tick per step, minor ticks between.
private struct RulerTicks: View {
    let count: Int
    let stationWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(Theme.inkTertiary.opacity(0.7))
            let baseline = size.height - 0.5
            var line = Path()
            line.move(to: CGPoint(x: 0, y: baseline))
            line.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(line, with: ink, lineWidth: 1)
            let minor = stationWidth / 5
            var x: CGFloat = 0
            var i = 0
            while x <= size.width {
                let major = i % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x + stationWidth / 2, y: baseline))
                tick.addLine(to: CGPoint(x: x + stationWidth / 2, y: baseline - (major ? 7 : 3)))
                context.stroke(tick, with: ink, lineWidth: major ? 1.2 : 0.8)
                if major, i / 5 < count {
                    let label = Text("\(i / 5 + 1)").font(Theme.micro).foregroundStyle(Theme.inkSecondary)
                    context.draw(label, at: CGPoint(x: x + stationWidth / 2 + 6, y: baseline - 6), anchor: .leading)
                }
                x += minor
                i += 1
            }
        }
        .frame(width: max(CGFloat(count) * TimelineView.stationWidth + 80, 200), height: 64)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Section-view hatching for rolled-back steps.
private struct SectionHatch: View {
    var body: some View {
        Canvas { context, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            context.stroke(p, with: .color(Theme.inkTertiary.opacity(0.45)), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

/// The orange caliper used as rollback marker.
private struct RollbackCaliper: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.fillet)
                .frame(width: 14, height: 9)
                .overlay(
                    HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.7)).frame(width: 1, height: 5) } })
            Rectangle().fill(Theme.fillet).frame(width: 2.5)
            Triangle().fill(Theme.fillet).frame(width: 10, height: 6)
        }
        .frame(width: 16, height: 64)
        .shadow(color: Theme.fillet.opacity(0.35), radius: 4)
        .contentShape(Rectangle().inset(by: -6))
    }
}

private struct Triangle: SwiftUI.Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct PlaybackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.ink : Theme.inkTertiary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(configuration.isPressed ? Theme.hairline : .clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
