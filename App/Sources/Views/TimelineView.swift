import FilletCore
import SwiftUI

/// Fusion-style parametric timeline along the bottom of the window.
///
/// Every feature is a step that can be opened and changed; later steps replay
/// automatically. Drag steps to reorder them (refused when a step would end up
/// before something it uses), drag the marker to roll the model back.
struct TimelineView: View {
    @Bindable var session: DesignSession
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var dropTarget: Int?

    private var doc: Document { session.document }
    private var markerIndex: Int { doc.activeFeatureCount }

    var body: some View {
        HStack(spacing: 6) {
            playback
            Divider().frame(height: 34)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(doc.features.enumerated()), id: \.element.id) { index, feature in
                            if index == markerIndex { marker.id("marker") }
                            step(feature, index: index)
                                .id(feature.id)
                        }
                        if markerIndex >= doc.features.count { marker.id("marker") }
                        Color.clear.frame(width: 40, height: 44)
                            .dropDestination(for: String.self) { items, _ in drop(items, at: doc.features.count) }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: doc.features.count) { _, _ in
                    withAnimation { proxy.scrollTo("marker", anchor: .trailing) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 62)
        .background(.bar)
        .alert("Rename Step", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = renaming { session.rename(id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Playback controls

    private var playback: some View {
        HStack(spacing: 0) {
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
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 34)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Steps

    private func step(_ feature: Feature, index: Int) -> some View {
        let status = session.model.status[feature.id] ?? .inactive
        let rolledBack = index >= markerIndex
        let isEditing = session.editing?.feature == feature.id
        let failed: String? = if case .failed(let m) = status { m } else { nil }

        return Button {
            open(feature)
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: feature.kind.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isEditing ? AnyShapeStyle(.tint.opacity(0.25))
                                      : failed != nil ? AnyShapeStyle(Color.red.opacity(0.18))
                                      : AnyShapeStyle(.quaternary.opacity(0.6))))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
                    if failed != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white, .red)
                            .offset(x: 4, y: -4)
                    }
                }
                Text(feature.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .frame(maxWidth: 70)
                    .strikethrough(feature.suppressed)
            }
            .padding(.horizontal, 3)
            .opacity(rolledBack || feature.suppressed ? 0.4 : 1)
            .overlay(alignment: .leading) {
                if dropTarget == index { Capsule().fill(.tint).frame(width: 3, height: 40).offset(x: -3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(failed.map { "\(feature.name): \($0)" } ?? feature.name)
        .draggable("feature:\(feature.id.uuidString)") {
            Label(feature.name, systemImage: feature.kind.symbol).padding(6).background(.regularMaterial, in: Capsule())
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
            } label: { Label("Roll Back to Here", systemImage: "arrow.uturn.backward.circle") }
            if let failed {
                Text(failed)
            }
            Divider()
            Button(role: .destructive) { session.deleteFeature(feature.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// The rollback marker: drag it onto a step to roll back to just after that step.
    private var marker: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
            Rectangle().frame(width: 3, height: 36)
        }
        .foregroundStyle(.orange)
        .frame(width: 14)
        .contentShape(Rectangle())
        .draggable("rollback") {
            Image(systemName: "arrowtriangle.down.fill").foregroundStyle(.orange)
        }
        .help("Rollback marker — drag onto a step to roll back to it")
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
            session.moveRollbackMarker(to: index >= doc.features.count ? nil : index + 1 > doc.features.count ? nil : index + 1)
            return true
        }
        guard item.hasPrefix("feature:"), let id = UUID(uuidString: String(item.dropFirst(8))),
            let from = doc.index(of: id)
        else { return false }
        let target = from < index ? index - 1 : index
        guard target != from else { return false }
        if !session.moveFeature(id, to: target) {
            session.message = "Can't move \(doc.feature(id)?.name ?? "that step") there — it depends on an earlier step"
            return false
        }
        return true
    }
}
