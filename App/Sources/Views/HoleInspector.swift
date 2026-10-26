import FilletCore
import SwiftUI

/// The Hole step's controls, laid out like Fusion's Hole dialog: placement, type, size, extent.
struct HoleInspector: View {
    let hole: Hole
    let evaluator: Evaluator
    let set: (Hole) -> Void

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
            Hint("From the middle of the face, along its sides. Type a parameter to tie a hole to it.")
        }
    }
}
