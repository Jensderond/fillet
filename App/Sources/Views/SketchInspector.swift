import FilletCore
import FilletKernel
import SwiftUI

/// Sketch mode: tool options and exact dimensions of the selected shape.
struct SketchInspector: View {
    @Bindable var session: DesignSession

    private var ev: Evaluator { session.model.parameters.evaluator }

    private var sketch: Sketch? {
        guard let id = session.sketchEditor?.sketch, case .sketch(let s) = session.document.feature(id)?.kind else { return nil }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "pencil.and.outline").foregroundStyle(.tint)
                Text(session.editingFeature?.name ?? "Sketch").font(.headline)
                Spacer()
            }
            if let editor = session.sketchEditor {
                if let error = session.model.error(for: editor.sketch) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                }
                options(editor)
                Divider()
                selectedShapes(editor)
            }
            Button {
                session.finishSketch()
            } label: {
                Label("Finish Sketch", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func options(_ editor: SketchEditor) -> some View {
        Picker("Snap to grid", selection: Binding(
            get: { editor.gridSize },
            set: { session.sketchEditor?.gridSize = $0 })) {
            Text("Off").tag(0.0)
            Text("0.1 mm").tag(0.1)
            Text("0.5 mm").tag(0.5)
            Text("1 mm").tag(1.0)
            Text("5 mm").tag(5.0)
        }
        Toggle("Construction lines", isOn: Binding(
            get: { editor.engine.construction },
            set: { session.sketchEditor?.engine.construction = $0 }))
        if editor.tool == .polygon {
            Stepper("Sides: \(editor.engine.polygonSides)", value: Binding(
                get: { editor.engine.polygonSides },
                set: { session.sketchEditor?.engine.polygonSides = $0 }), in: 3...64)
        }
    }

    @ViewBuilder private func selectedShapes(_ editor: SketchEditor) -> some View {
        let shapes = sketch?.shapes.filter { editor.selectedShapes.contains($0.id) } ?? []
        if shapes.isEmpty {
            Hint("Draw with Apple Pencil, or tap/drag with the mouse. Pick the Select tool to change a shape's exact dimensions.")
        } else if shapes.count == 1, let shape = shapes.first {
            ShapeDimensions(shape: shape, evaluator: ev) { updated in
                session.updateSketch("Edit \(updated.kind.typeName.capitalized)") { sketch in
                    if let i = sketch.shapes.firstIndex(where: { $0.id == updated.id }) { sketch.shapes[i] = updated }
                }
            }
        } else {
            Text("\(shapes.count) shapes selected").font(.subheadline.weight(.medium))
        }
        if !shapes.isEmpty {
            HStack {
                Button { session.toggleConstructionOfSelection() } label: { Label("Construction", systemImage: "line.diagonal") }
                Spacer()
                Button(role: .destructive) { session.deleteSelectedSketchShapes() } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Editable dimensions of one sketch shape.
struct ShapeDimensions: View {
    let shape: SketchShape
    let evaluator: Evaluator
    let onChange: (SketchShape) -> Void

    private func update(_ kind: SketchShapeKind) {
        var s = shape
        s.kind = kind
        onChange(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shape.kind.typeName.capitalized + (shape.construction ? " (construction)" : ""))
                .font(.subheadline.weight(.semibold))
            switch shape.kind {
            case .line(let a, let b):
                PointField(label: "Start", value: a, evaluator: evaluator) { update(.line(a: $0, b: b)) }
                PointField(label: "End", value: b, evaluator: evaluator) { update(.line(a: a, b: $0)) }
                if let pa = try? a.evaluate(using: evaluator), let pb = try? b.evaluate(using: evaluator) {
                    let d = pb - pa
                    Text("Length \(ExprField.format((d.x * d.x + d.y * d.y).squareRoot())) mm · angle \(ExprField.format(atan2(d.y, d.x) * 180 / .pi))°")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .rectangle(let anchor, let position, let width, let height, let angle):
                Picker("Anchor", selection: Binding(get: { anchor }, set: { update(.rectangle(anchor: $0, position: position, width: width, height: height, angle: angle)) })) {
                    Text("Corner").tag(RectangleAnchor.corner)
                    Text("Center").tag(RectangleAnchor.center)
                }
                .pickerStyle(.segmented)
                ExprField(label: "Width", value: width, evaluator: evaluator) { update(.rectangle(anchor: anchor, position: position, width: $0, height: height, angle: angle)) }
                ExprField(label: "Height", value: height, evaluator: evaluator) { update(.rectangle(anchor: anchor, position: position, width: width, height: $0, angle: angle)) }
                PointField(label: anchor == .corner ? "Corner" : "Center", value: position, evaluator: evaluator) { update(.rectangle(anchor: anchor, position: $0, width: width, height: height, angle: angle)) }
                ExprField(label: "Rotation", value: angle, kind: .angle, evaluator: evaluator) { update(.rectangle(anchor: anchor, position: position, width: width, height: height, angle: $0)) }
            case .circle(let center, let diameter):
                ExprField(label: "Diameter", value: diameter, evaluator: evaluator) { update(.circle(center: center, diameter: $0)) }
                PointField(label: "Center", value: center, evaluator: evaluator) { update(.circle(center: $0, diameter: diameter)) }
            case .arc(let start, let through, let end):
                PointField(label: "Start", value: start, evaluator: evaluator) { update(.arc(start: $0, through: through, end: end)) }
                PointField(label: "Through", value: through, evaluator: evaluator) { update(.arc(start: start, through: $0, end: end)) }
                PointField(label: "End", value: end, evaluator: evaluator) { update(.arc(start: start, through: through, end: $0)) }
            case .polygon(let center, let sides, let radius, let inscribed, let angle):
                ExprField(label: "Sides", value: sides, kind: .scalar, evaluator: evaluator) { update(.polygon(center: center, sides: $0, radius: radius, inscribed: inscribed, angle: angle)) }
                ExprField(label: "Radius", value: radius, evaluator: evaluator) { update(.polygon(center: center, sides: sides, radius: $0, inscribed: inscribed, angle: angle)) }
                Toggle("Corners on circle", isOn: Binding(get: { inscribed }, set: { update(.polygon(center: center, sides: sides, radius: radius, inscribed: $0, angle: angle)) }))
                ExprField(label: "Rotation", value: angle, kind: .angle, evaluator: evaluator) { update(.polygon(center: center, sides: sides, radius: radius, inscribed: inscribed, angle: $0)) }
                PointField(label: "Center", value: center, evaluator: evaluator) { update(.polygon(center: $0, sides: sides, radius: radius, inscribed: inscribed, angle: angle)) }
            case .slot(let a, let b, let width):
                ExprField(label: "Width", value: width, evaluator: evaluator) { update(.slot(a: a, b: b, width: $0)) }
                PointField(label: "End A", value: a, evaluator: evaluator) { update(.slot(a: $0, b: b, width: width)) }
                PointField(label: "End B", value: b, evaluator: evaluator) { update(.slot(a: a, b: $0, width: width)) }
            case .point(let p):
                PointField(label: "Position", value: p, evaluator: evaluator) { update(.point($0)) }
            case .polyline(let vertices, let closed):
                Text("\(vertices.count) points\(closed ? ", closed" : "")").foregroundStyle(.secondary)
            case .spline(let points):
                Text("\(points.count) points").foregroundStyle(.secondary)
            }
        }
    }
}
