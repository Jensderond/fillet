import FilletCore
import SwiftUI

/// The parametric timeline, drawn as a measuring ruler along the bottom of the window.
///
/// Every feature is a station at an even interval with a numbered tick. Tap a
/// station to change it; later steps replay. Drag stations to reorder (refused
/// when a step would land before something it uses). The orange caliper is the
/// rollback marker: it follows the finger along the ruler, snapping to stations;
/// steps past it are hatched like a section view.
struct TimelineView: View {
    @Bindable var session: DesignSession
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var dropTarget: Int?
    /// Where the caliper is while it's being dragged (a station boundary), nil otherwise.
    @State private var markerDrag: Int?
    @State private var visibleWidth: CGFloat = 0
    /// The station under the pointer: its ruler number shows (names already say the order).
    @State private var hoveredStation: Int?
    @Namespace private var markerSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.touchTargets) private var touch

    /// Station pitch on the ruler; grows with the station labels under Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var stationWidth: CGFloat = 70

    private var doc: Document { session.document }
    private var markerIndex: Int { doc.activeFeatureCount }
    private var editingIndex: Int? { session.editing.flatMap { doc.index(of: $0.feature) } }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            playback
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .bottomLeading) {
                        RulerTicks(count: doc.features.count, stationWidth: stationWidth, minWidth: visibleWidth - 8,
                                   numbered: Set([hoveredStation, editingIndex].compactMap { $0 }))
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
                        .coordinateSpace(.named("ruler"))
                        .animation(reduceMotion ? nil : Theme.Motion.move, value: markerIndex)
                    }
                    .padding(.horizontal, 4)
                    // Room above the chips for their corner marks (a pattern's check, a failure dot),
                    // which the scroll view would clip; the view reaches up by as much, so nothing moves.
                    .padding(.top, Theme.Space.xs)
                }
                .padding(.top, -Theme.Space.xs)
                // A long design opens on its latest steps, where the work continues.
                .defaultScrollAnchor(.trailing, for: .initialOffset)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
                .onChange(of: doc.features.count) { _, _ in
                    withAnimation(Theme.Motion.enter) { proxy.scrollTo("marker", anchor: .trailing) }
                }
                // Opening a step from elsewhere (a failed-step banner, the browser) brings it into view.
                .onChange(of: session.editing?.feature) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Theme.Motion.move) { proxy.scrollTo(id, anchor: .center) }
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
                .frame(width: touch ? 44 : 30, height: touch ? 44 : 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .hoverHighlight()
    }

    // MARK: Stations

    /// How a step reads while a feature pattern picks its steps here (nil otherwise).
    private func patternPick(_ feature: Feature) -> StationPick? {
        guard let (pattern, p) = session.editingFeaturePattern, feature.id != pattern.id else { return nil }
        if p.features.contains(feature.id) { return .picked }
        return session.patternPickRefusal(feature.id) == nil ? .pickable : .unavailable
    }

    private func station(_ feature: Feature, index: Int) -> some View {
        let status = session.model.status[feature.id] ?? .inactive
        let failed: String? = if case .failed(let m) = status { m } else { nil }
        let pick = patternPick(feature)
        let patternName = session.editingFeaturePattern?.feature.name ?? "the pattern"
        return Button {
            // While a feature pattern is open, the ruler picks its steps instead of opening them.
            if session.editingFeaturePattern != nil {
                session.toggleEditingPatternFeature(feature.id)
            } else {
                open(feature)
            }
        } label: {
            StationLabel(
                feature: feature, number: index + 1, width: stationWidth, rolledBack: index >= markerIndex,
                editing: session.editing?.feature == feature.id, failure: failed,
                dropTarget: dropTarget == index, pick: pick)
        }
        .buttonStyle(PressableStyle())
        .automationFrame("station.\(index)")
        .hoverHighlight(ownsPointerHover: true)
        // Hovering a step highlights the body it made, like Fusion's timeline.
        .onHover { inside in
            hoverBody(of: feature, inside)
            if inside { hoveredStation = index } else if hoveredStation == index { hoveredStation = nil }
        }
        .help(helpText(feature, pick: pick, failure: failed))
        .accessibilityLabel("Step \(index + 1), \(feature.name)")
        .accessibilityValue(stateDescription(feature, index: index, failure: failed, pick: pick))
        .accessibilityHint(pick == .picked ? "Removes it from \(patternName)" : pick == .pickable ? "Adds it to \(patternName)" : "")
        .accessibilityAddTraits(session.editing?.feature == feature.id || pick == .picked ? .isSelected : [])
        .accessibilityActions {
            if index > 0 { Button("Move earlier") { move(feature, to: index - 1) } }
            if index < doc.features.count - 1 { Button("Move later") { move(feature, to: index + 1) } }
            Button("Roll back to here") { session.moveRollbackMarker(to: index + 1 >= doc.features.count ? nil : index + 1) }
        }
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
            if feature.kind.canBePatterned { patternMenuItem(feature, pick: pick, patternName: patternName) }
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

    /// The rollback caliper. It follows the finger or pointer 1:1 along the ruler, snaps
    /// to the station boundaries with a selection tick, and settles there on release.
    private var marker: some View {
        let count = doc.features.count
        // Zero layout width keeps the ruler graduations aligned with the stations; while
        // dragging, the caliper is drawn offset rather than moved in the stack.
        return Color.clear
            .frame(width: 0, height: 64)
            .overlay {
                RollbackCaliper(hitWidth: touch ? 44 : 28)
                    .offset(x: CGFloat((markerDrag ?? markerIndex) - markerIndex) * stationWidth)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("ruler"))
                            .onChanged { value in
                                markerDrag = min(max(Int((value.location.x / stationWidth).rounded()), 0), count)
                            }
                            .onEnded { _ in
                                guard let target = markerDrag else { return }
                                markerDrag = nil
                                if target != markerIndex { session.moveRollbackMarker(to: target >= count ? nil : target) }
                            })
                    .sensoryFeedback(.selection, trigger: markerDrag) { _, new in new != nil }
            }
            .matchedGeometryEffect(id: "marker", in: markerSpace)
            .id("marker")
            .help("Rollback marker. Drag it along the ruler to see the model at an earlier step.")
            .accessibilityElement()
            .accessibilityLabel("Rollback marker")
            .accessibilityValue(markerIndex >= count ? "after the last step, \(count) of \(count)" : "after step \(markerIndex) of \(count)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment where markerIndex < count:
                    session.moveRollbackMarker(to: markerIndex + 1 >= count ? nil : markerIndex + 1)
                case .decrement where markerIndex > 0:
                    session.moveRollbackMarker(to: markerIndex - 1)
                default: break
                }
            }
    }

    /// Pattern from the context menu: a feature pattern of this step, or, while one is open,
    /// adding the step to it or taking it out.
    @ViewBuilder private func patternMenuItem(_ feature: Feature, pick: StationPick?, patternName: String) -> some View {
        switch pick {
        case .picked:
            Button { session.toggleEditingPatternFeature(feature.id) } label: {
                Label("Remove from \(patternName)", systemImage: "minus.circle")
            }
        case .pickable:
            Button { session.toggleEditingPatternFeature(feature.id) } label: {
                Label("Add to \(patternName)", systemImage: "plus.circle")
            }
        case .unavailable:
            EmptyView()
        case nil:
            if session.editingFeaturePattern == nil {
                Button {
                    session.startIfAvailable(.pattern) { session.startPattern(features: [feature.id]) }
                } label: { Label("Pattern", systemImage: Self.patternSymbol) }
            }
        }
    }

    private static let patternSymbol = FeatureKind.pattern(Pattern(features: [], layout: .linear(direction: .x, count: 1, spacing: 0))).symbol

    private func helpText(_ feature: Feature, pick: StationPick?, failure: String?) -> String {
        if let failure { return "\(feature.name): \(failure)" }
        switch pick {
        case .picked: return "\(feature.name). \(Theme.Copy.pick) to remove it from the pattern."
        case .pickable: return "\(feature.name). \(Theme.Copy.pick) to add it to the pattern."
        case .unavailable: return session.patternPickRefusal(feature.id) ?? feature.name
        case nil: return "\(feature.name). \(Theme.Copy.pick) to edit."
        }
    }

    /// VoiceOver state of a step: editing, picked for a pattern, rolled back, suppressed, failed.
    private func stateDescription(_ feature: Feature, index: Int, failure: String?, pick: StationPick?) -> String {
        var parts: [String] = []
        if session.editing?.feature == feature.id { parts.append("editing") }
        if pick == .picked { parts.append("in the pattern") }
        if pick == .unavailable { parts.append("can't be added to the pattern") }
        if index >= markerIndex { parts.append("rolled back") }
        if feature.suppressed { parts.append("suppressed") }
        if let failure { parts.append("failed: \(failure)") }
        return parts.joined(separator: ", ")
    }

    /// Reorders a step, explaining a refusal (a step can't move before something it uses).
    private func move(_ feature: Feature, to index: Int) {
        if !session.moveFeature(feature.id, to: index) {
            session.message = .error("\(feature.name) can't move there: it uses an earlier step")
        }
    }

    private func hoverBody(of feature: Feature, _ inside: Bool) {
        let ids = [feature.id] + feature.referencedFeatures.sorted { $0.uuidString < $1.uuidString }
        guard let body = ids.lazy.map(BodyRef.init).first(where: { session.model.body($0) != nil }) else { return }
        if inside {
            session.hover = .body(body)
        } else if session.hover == .body(body) {
            session.hover = nil
        }
    }

    private func open(_ feature: Feature) {
        if case .sketch = feature.kind {
            session.editSketch(feature.id)
        } else {
            session.beginEdit(feature.id)
        }
    }

    /// Handles a drop of a step before `index` (reorder).
    private func drop(_ items: [String], at index: Int) -> Bool {
        dropTarget = nil
        guard let item = items.first else { return false }
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

/// A step's part in a feature pattern being edited (the timeline picks its steps).
enum StationPick: Equatable {
    /// Repeated by the pattern.
    case picked
    /// Can join the pattern.
    case pickable
    /// Can't be repeated, or comes after the pattern.
    case unavailable
}

/// One step on the ruler.
private struct StationLabel: View {
    let feature: Feature
    let number: Int
    let width: CGFloat
    let rolledBack: Bool
    let editing: Bool
    let failure: String?
    let dropTarget: Bool
    /// Set while a feature pattern picks its steps here.
    var pick: StationPick?

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var picked: Bool { pick == .picked }
    private var unavailable: Bool { pick == .unavailable }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ZStack {
                Image(systemName: feature.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 40, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chipFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(chipBorder, style: StrokeStyle(lineWidth: editing || picked ? 1.5 : 1,
                                                                         dash: feature.suppressed || (rolledBack && !editing && !picked) ? [3, 2] : [])))
                // A picked step's check rides the chip's corner where a failure dot would; the dot
                // then moves to the other corner so both stay visible.
                if failure != nil {
                    Circle().fill(Theme.danger)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                        .offset(x: picked ? -3 : 3, y: -3)
                        .frame(width: 40, height: 30, alignment: picked ? .topLeading : .topTrailing)
                }
                if picked {
                    PickedBadge()
                        .offset(x: 4, y: -4)
                        .frame(width: 40, height: 30, alignment: .topTrailing)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                }
            }
            // The check pops in with a small spring (a fade under Reduce Motion).
            .animation(reduceMotion ? Theme.Motion.hover : .spring(duration: 0.32, bounce: 0.4), value: picked)
            Text(feature.name)
                .font(editing || picked ? Theme.label.weight(.semibold) : Theme.label)
                .foregroundStyle(labelColor)
                .strikethrough(feature.suppressed)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: width, height: 50, alignment: .top)
        .padding(.bottom, 14)
        // Rolled back: hatched, an empty dashed chip, slate icon and secondary label (active
        // steps are ink); no opacity, so the name stays legible.
        .background(alignment: .center) {
            if rolledBack { SectionHatch() }
        }
        .overlay(alignment: .leading) {
            if dropTarget { Capsule().fill(Theme.filletMark).frame(width: 2.5, height: 44) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
    }

    // Picked steps take the selection blue, like the bodies a pattern picks in the viewport and
    // its "steps picked" card, so they don't read as a second step being edited (orange). Steps that
    // can't join recede to a bare tertiary chip; their names stay secondary ink, still legible.

    private var labelColor: Color {
        if failure != nil { return Theme.dangerInk }
        if picked { return Theme.ink }
        return rolledBack || unavailable ? Theme.inkSecondary : Theme.ink
    }

    private var iconColor: Color {
        if failure != nil { return Theme.danger }
        if editing { return Theme.filletInk }
        if picked { return Theme.selectInk }
        return rolledBack || unavailable ? Theme.inkTertiary : Theme.ink
    }

    private var chipFill: Color {
        if editing { return Theme.filletSoft }
        if picked { return Theme.selectSoft }
        if failure != nil { return Theme.dangerSoft }
        if unavailable { return .clear }
        if rolledBack { return hovering ? Theme.raised.opacity(0.6) : .clear }
        return hovering ? Theme.raised : Theme.raised.opacity(0.7)
    }

    private var chipBorder: Color {
        if editing { return Theme.filletMark }
        if picked { return Theme.select }
        if failure != nil { return Theme.danger.opacity(0.5) }
        if unavailable { return Theme.hairline }
        if rolledBack { return Theme.inkTertiary }
        return hovering ? Theme.hairlineStrong : Theme.hairline
    }
}

/// The check on a step a feature pattern repeats.
private struct PickedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Theme.select))
            .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// Ruler graduations under the stations: a major numbered tick per step, minor ticks between.
private struct RulerTicks: View {
    let count: Int
    let stationWidth: CGFloat
    /// The ruler runs at least the visible width, so it never stops mid-panel.
    var minWidth: CGFloat = 0
    /// Stations whose number shows (hovered, being edited): the names already give the order.
    var numbered: Set<Int> = []

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
                // A numbered station gets a short tick with its number centred on it; unnumbered
                // major graduations (past the last step) keep the long tick.
                let station = major && i / 5 < count
                var tick = Path()
                tick.move(to: CGPoint(x: x + stationWidth / 2, y: baseline))
                tick.addLine(to: CGPoint(x: x + stationWidth / 2, y: baseline - (major && !station ? 7 : 3)))
                context.stroke(tick, with: ink, lineWidth: major ? 1.2 : 0.8)
                if station, numbered.contains(i / 5) {
                    let label = Text("\(i / 5 + 1)").font(Theme.micro).foregroundStyle(Theme.inkTertiary)
                    context.draw(label, at: CGPoint(x: x + stationWidth / 2, y: baseline - 9), anchor: .center)
                }
                x += minor
                i += 1
            }
        }
        .frame(width: max(CGFloat(count) * stationWidth + 80, 200, minWidth), height: 64)
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
            context.stroke(p, with: .color(Theme.inkTertiary.opacity(0.35)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// The orange caliper used as rollback marker.
private struct RollbackCaliper: View {
    var hitWidth: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.filletMark)
                .frame(width: 14, height: 9)
                .overlay(
                    HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.7)).frame(width: 1, height: 5) } })
            Rectangle().fill(Theme.filletMark).frame(width: 2.5)
            Triangle().fill(Theme.filletMark).frame(width: 10, height: 6)
        }
        .frame(width: 16, height: 64)
        .shadow(color: Theme.filletMark.opacity(0.3), radius: 4)
        .frame(width: hitWidth)
        .contentShape(Rectangle())
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
            .foregroundStyle(isEnabled ? Theme.ink : Theme.inkTertiary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(configuration.isPressed ? Theme.hairline : .clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
