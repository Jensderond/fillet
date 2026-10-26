import FilletCore
import FilletKernel
import SwiftUI

/// Measurements of the current selection, or a design summary when nothing is selected.
struct SelectionInspector: View {
    @Bindable var session: DesignSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if session.selection.isEmpty {
                summary
            } else {
                InspectorHeader(
                    symbol: "cursorarrow.rays", title: session.selection.count == 1 ? name(of: session.selection[0]) : "\(session.selection.count) selected",
                    subtitle: session.selection.count == 2 ? nil : "Pick two items to measure between them", tint: Theme.select)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(session.selection.prefix(4).enumerated()), id: \.offset) { _, item in
                        describe(item)
                    }
                }
                if session.selection.count == 2 { distance }
                actions
            }
        }
    }

    @ViewBuilder private var summary: some View {
        // Nothing is active here, so the chip is ink, not orange.
        InspectorHeader(symbol: "printer", title: "Print check", subtitle: session.document.printerPreset.name, tint: Theme.inkSecondary)
        if session.model.bodies.isEmpty {
            if session.document.features.isEmpty {
                Button { session.startSketch(on: .xy) } label: {
                    Label("Start a sketch on the bed", systemImage: "pencil.and.outline").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Hint("Start with Sketch in the toolbar, draw a profile on the bed, then Extrude it.", symbol: "pencil.and.outline")
        } else if let a = session.printAnalysis {
            VStack(spacing: 0) {
                CheckRow(state: a.fitsOnBed ? .ok : .bad, title: "Fits the bed",
                         detail: a.fitsOnBed ? (a.fitsOnlyRotated ? "Rotate 90° in the slicer" : "\(fmt(a.size.x)) × \(fmt(a.size.y)) × \(fmt(a.size.z)) mm")
                                             : "\(fmt(a.size.x)) × \(fmt(a.size.y)) × \(fmt(a.size.z)) mm is too big")
                Theme.hairline.frame(height: 1)
                CheckRow(state: a.overhangCount == 0 ? .ok : .warn, title: a.overhangCount == 0 ? "No overhangs" : "Overhangs",
                         detail: a.overhangCount == 0 ? "Prints without supports" : "\(fmt(a.overhangArea)) mm² past \(Int(session.overhangAngle))°",
                         action: a.overhangCount == 0 ? nil : ("Show", { session.showOverhangs = true }))
                Theme.hairline.frame(height: 1)
                CheckRow(state: a.isWatertight ? .ok : .bad, title: a.isWatertight ? "Watertight" : "Not watertight",
                         detail: a.watertightIssue ?? "Safe to slice")
                let failed = session.failedFeatures
                if let first = failed.first {
                    Theme.hairline.frame(height: 1)
                    CheckRow(state: .bad, title: failed.count == 1 ? "1 step failed" : "\(failed.count) steps failed",
                             detail: "\(first.feature.name): \(first.reason)",
                             action: ("Show", { session.run(.showFeature(first.feature.id)) }))
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))

            PanelSection("Material") {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
                    row("Volume", "\(fmt(a.volume / 1000)) cm³")
                    row("PLA, solid", "\(fmt(a.grams(.pla))) g")
                    row("Bodies", "\(session.model.bodies.count)")
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(Theme.body).foregroundStyle(Theme.inkSecondary)
            Text(v).font(Theme.value).foregroundStyle(Theme.ink)
        }
    }

    /// One picked item names the inspector ("Flat face", "Body 1") instead of a generic "Selection".
    private func name(of s: Selection) -> String {
        switch s {
        case .face(let b, let i): session.model.body(b)?.shape.faceInfoIfValid(i).map { "\($0.surface.title) face" } ?? "Face"
        case .edge(let b, let i): session.model.body(b)?.shape.edgeInfoIfValid(i).map { "\($0.curve.title) edge" } ?? "Edge"
        case .body(let b): session.model.body(b)?.name ?? "Body"
        default: "Selection"
        }
    }

    @ViewBuilder private func describe(_ s: Selection) -> some View {
        switch s {
        case .face(let b, let i):
            if let shape = session.model.body(b)?.shape, let info = shape.faceInfoIfValid(i) {
                MeasureRow(symbol: "square.fill", title: "\(info.surface.title) face", detail: "Area \(fmt(info.area)) mm²")
            }
        case .edge(let b, let i):
            if let shape = session.model.body(b)?.shape, let info = shape.edgeInfoIfValid(i) {
                MeasureRow(symbol: "line.diagonal", title: "\(info.curve.title) edge",
                           detail: info.curve == .circle ? "Ø \(fmt(info.radius * 2)) mm, length \(fmt(info.length)) mm"
                                                         : "Length \(fmt(info.length)) mm")
            }
        case .body(let b):
            if let body = session.model.body(b) {
                MeasureRow(symbol: "cube", title: body.name, detail: body.shape.bounds.map { b in
                    let d = b.max - b.min
                    return "\(fmt(d.x)) × \(fmt(d.y)) × \(fmt(d.z)) mm"
                } ?? "")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var distance: some View {
        if let d = session.selectionDistance {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "ruler").foregroundStyle(Theme.select)
                Text("Distance").font(Theme.body).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("\(fmt(d)) mm").font(Theme.title.monospacedDigit()).foregroundStyle(Theme.ink)
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.selectSoft))
        }
    }

    @ViewBuilder private var actions: some View {
        PanelSection("Next") {
            VStack(spacing: Theme.Space.s) {
                if !session.selectedEdges.isEmpty {
                    ActionRow(symbol: "rectangle.roundedtop", title: "Fillet edges") { session.startEdgeFeature(fillet: true) }
                    ActionRow(symbol: "skew", title: "Chamfer edges") { session.startEdgeFeature(fillet: false) }
                }
                if let (b, f) = session.selectedFaces.first, session.model.body(b)?.shape.facePlane(f) != nil {
                    ActionRow(symbol: "pencil.and.outline", title: "Sketch on this face") { session.startSketch() }
                    ActionRow(symbol: "arrow.down.to.line", title: "Lay flat on the bed") { session.startLayFlat() }
                }
                if !session.selectedFaces.isEmpty {
                    ActionRow(symbol: "cube.transparent", title: "Shell, removing these faces") { session.startShell() }
                }
            }
            Button("Clear selection") { session.selection = [] }
                .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
                .padding(.top, Theme.Space.xs)
        }
    }

    private func fmt(_ v: Double) -> String { ExprField.format((v * 100).rounded() / 100) }
}

extension DesignSession {
    /// Print analysis of all visible bodies.
    var printAnalysis: PrintAnalysis? {
        let meshes = model.bodies.filter { !hiddenBodies.contains($0.ref) }.compactMap { model.meshes[$0.ref] }
        guard !meshes.isEmpty else { return nil }
        return PrintAnalysis.analyze(meshes: meshes, preset: document.printerPreset, overhangAngleDegrees: overhangAngle)
    }

    /// Minimum distance between two selected faces/edges/bodies.
    var selectionDistance: Double? {
        guard selection.count == 2 else { return nil }
        func shape(_ s: Selection) -> Shape? {
            switch s {
            case .face(let b, let i): try? model.body(b)?.shape.face(i)
            case .edge(let b, let i): try? model.body(b)?.shape.edge(i)
            case .body(let b): model.body(b)?.shape
            default: nil
            }
        }
        guard let a = shape(selection[0]), let b = shape(selection[1]) else { return nil }
        return a.distance(to: b)?.distance
    }
}

extension SurfaceType {
    var title: String {
        switch self {
        case .plane: "Flat"
        case .cylinder: "Cylindrical"
        case .cone: "Conical"
        case .sphere: "Spherical"
        case .torus: "Toroidal"
        case .bspline: "Freeform"
        case .other: "Curved"
        }
    }
}

extension CurveType {
    var title: String {
        switch self {
        case .line: "Straight"
        case .circle: "Circular"
        case .ellipse: "Elliptical"
        case .bspline: "Curved"
        case .other: "Curved"
        }
    }
}

/// One check in the print summary.
private struct CheckRow: View {
    enum State { case ok, warn, bad }
    let state: State
    let title: String
    let detail: String
    var action: (String, () -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the action goes under the text, which keeps the full width
        // instead of wrapping word by word beside it.
        let stacked = typeSize.isAccessibilitySize
        HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: Theme.Space.m) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : state == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.system(size: 15))
                .foregroundStyle(state == .ok ? Theme.ok : state == .warn ? Theme.warn : Theme.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                if stacked, let action {
                    Button(action.0, action: action.1).buttonStyle(InlineButtonStyle()).padding(.top, Theme.Space.xs)
                }
            }
            Spacer(minLength: 0)
            if !stacked, let action {
                Button(action.0, action: action.1).buttonStyle(InlineButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
    }
}

/// A measured item in the selection list.
private struct MeasureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconChip(symbol: symbol, tint: Theme.select, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A suggested next step for the selection.
private struct ActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 20)
                Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: max(38, Theme.Metrics.target(touch: touch)))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Theme.raised : Theme.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(hovering ? Theme.hairlineStrong : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .hoverHighlight(ownsPointerHover: true)
    }
}
