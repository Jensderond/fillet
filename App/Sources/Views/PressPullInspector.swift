import FilletCore
import SwiftUI

/// Inspector fields of a Press Pull: the picked faces and how far they move.
struct PressPullInspector: View {
    @Bindable var session: DesignSession
    let pressPull: PressPull

    private var ev: Evaluator { session.model.parameters.evaluator }

    private func set(_ p: PressPull) { session.updateEditing { $0.kind = .pressPull(p) } }

    var body: some View {
        let p = pressPull
        SelectionCount(count: p.faces.count, noun: "face", plural: "faces", hint: "\(Theme.Copy.pick) faces to move in the viewport") {
            var x = p; x.faces = []; set(x)
        }
        ExprField(label: "Distance", value: p.distance, evaluator: ev) { var x = p; x.distance = $0; set(x) }
        Button {
            var x = p
            x.distance = Expr(stringLiteral: p.distance.source.hasPrefix("-") ? String(p.distance.source.dropFirst()) : "-(\(p.distance.source))")
            if p.distance.isLiteral, let v = try? ev.length(p.distance) { x.distance = Expr(-v) }
            set(x)
        } label: { Label("Flip direction", systemImage: "arrow.up.arrow.down") }
        .buttonStyle(SecondaryButtonStyle())
        Hint("A positive distance pulls the faces out and adds material; a negative one pushes them in.", symbol: "arrow.up.and.down")
        Hint("Drag the arrow in the viewport to change the distance.", symbol: "hand.draw")
    }
}
