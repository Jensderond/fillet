import FilletCore
import SwiftUI

/// The Hole step's controls, laid out like Fusion's Hole dialog: placement, type, size, extent.
struct HoleInspector: View {
    let hole: Hole
    let evaluator: Evaluator
    let set: (Hole) -> Void
    /// Picks a screw preset (nil: keep the sizes, drop the preset).
    let applyPreset: (HolePreset?) -> Void

    private func edit(_ change: (inout Hole) -> Void) {
        var h = hole
        change(&h)
        set(h)
    }

    var body: some View {
        SelectionCount(count: hole.centers.count, noun: "hole", plural: "holes",
                       hint: hole.face == nil ? "\(Theme.Copy.pick) a flat face where a hole goes"
                           : "\(Theme.Copy.pick) the face to add holes, or a hole to remove it") {
            edit { $0.centers = [] }
        }
        Labeled("Preset") { HolePresetMenu(hole: hole, apply: applyPreset) }
        if let preset = hole.preset, preset.fit.usesClearance {
            Hint(text: Text("Adds the ") + Text(HolePreset.clearanceParameter).font(Theme.value)
                 + Text(" parameter (\(clearanceValue)) to the screw's sizes. Tune it once under Parameters for your printer."))
        }
        Labeled("Type") {
            ThemeSegmented("Type", selection: hole.holeType,
                           options: [(.simple, "Simple"), (.counterbore, "Counterbore"), (.countersink, "Countersink")]) { t in
                edit { $0.holeType = t }
            }
        }
        ExprField(label: "Diameter", value: hole.diameter, evaluator: evaluator) { v in edit { $0.diameter = v } }
        switch hole.holeType {
        case .simple:
            EmptyView()
        case .counterbore:
            ExprField(label: "Bore diameter", value: hole.counterboreDiameter, evaluator: evaluator) { v in
                edit { $0.counterboreDiameter = v }
            }
            ExprField(label: "Bore depth", value: hole.counterboreDepth, evaluator: evaluator) { v in
                edit { $0.counterboreDepth = v }
            }
        case .countersink:
            ExprField(label: "Sink diameter", value: hole.countersinkDiameter, evaluator: evaluator) { v in
                edit { $0.countersinkDiameter = v }
            }
            ExprField(label: "Sink angle", value: hole.countersinkAngle, kind: .angle, evaluator: evaluator) { v in
                edit { $0.countersinkAngle = v }
            }
        }
        Labeled("Extent") {
            ThemeSegmented("Extent", selection: hole.extent, options: [(.distance, "Distance"), (.throughAll, "Through all")]) { e in
                edit { $0.extent = e }
            }
        }
        if hole.extent == .distance {
            ExprField(label: "Depth", value: hole.depth, evaluator: evaluator) { v in edit { $0.depth = v } }
            let flat = hole.tipAngle.isLiteral && (try? evaluator.angleDegrees(hole.tipAngle)) == 0
            Labeled("Drill point") {
                ThemeSegmented("Drill point", selection: flat, options: [(false, "Angled"), (true, "Flat")]) { f in
                    edit { $0.tipAngle = f ? 0 : Hole.drillPoint }
                }
            }
            if !flat {
                ExprField(label: "Point angle", value: hole.tipAngle, kind: .angle, evaluator: evaluator) { v in
                    edit { $0.tipAngle = v }
                }
            }
        }
        if !hole.centers.isEmpty {
            Text("Positions").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
            ForEach(Array(hole.centers.enumerated()), id: \.offset) { i, c in
                PointField(label: "Hole \(i + 1)", value: c, evaluator: evaluator) { p in edit { $0.centers[i] = p } }
            }
            Hint(hole.anchor == .world
                 ? "From the origin, seen square-on to the face (X and Y like a sketch on it). Type a parameter to tie a hole to it."
                 : "From the middle of the face, along its sides. Type a parameter to tie a hole to it.")
        }
    }

    /// The design's print clearance, as it reads now ("0.2 mm").
    private var clearanceValue: String {
        guard let v = try? evaluator.length(Expr(HolePreset.clearanceParameter)) else { return "not set" }
        return "\(Expr(v).source) mm"
    }
}

/// Screw presets by fit, each listing the sizes; the label names the hole's preset, with
/// "(edited)" once its sizes were changed.
private struct HolePresetMenu: View {
    let hole: Hole
    let apply: (HolePreset?) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Menu {
            ForEach(HoleFit.allCases, id: \.self) { fit in
                Menu(fit.title.prefix(1).uppercased() + fit.title.dropFirst()) {
                    ForEach(ScrewSize.allCases, id: \.self) { size in
                        let preset = HolePreset(size, fit)
                        Button { apply(preset) } label: {
                            if hole.preset == preset { Label(size.rawValue, systemImage: "checkmark") } else { Text(size.rawValue) }
                        }
                    }
                }
            }
            if hole.preset != nil {
                Divider()
                Button("Keep sizes, drop preset") { apply(nil) }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text(hole.presetTitle ?? "Custom sizes")
                    .font(Theme.body)
                    .foregroundStyle(hole.preset == nil ? Theme.inkSecondary : Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: touch ? 44 : 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.fieldBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Preset")
        .accessibilityValue(hole.presetTitle ?? "Custom sizes")
    }
}
