import FilletCore
import FilletKernel
import SwiftUI

/// Sketch mode: tool options and exact dimensions of the selected shape.
struct SketchInspector: View {
    @Bindable var session: DesignSession
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ev: Evaluator { session.model.parameters.evaluator }

    private var sketch: Sketch? {
        guard let id = session.sketchEditor?.sketch, case .sketch(let s) = session.document.feature(id)?.kind else { return nil }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if let editor = session.sketchEditor {
                InspectorHeader(
                    symbol: "pencil.and.outline", title: session.editingFeature?.name ?? "Sketch",
                    subtitle: "Finish the sketch to extrude or revolve it",
                    error: session.model.error(for: editor.sketch))
                PanelSection("Drawing") { options(editor) }
                PanelSection(selectedTitle(editor)) { selectedShapes(editor) }
            }
        }
    }

    #if os(iOS)
    static let drawingHint = "Draw with Apple Pencil. Turn on finger drawing in the toolbar to draw with a finger. Use the Select tool and tap a shape to type exact dimensions."
    #else
    static let drawingHint = "Click points to draw. Use the Select tool and click a shape to type exact dimensions."
    #endif

    /// One selected shape titles itself ("Circle"); otherwise the section needs a name.
    private func selectedTitle(_ editor: SketchEditor) -> String? {
        switch editor.selectedShapes.count {
        case 0: "Dimensions"
        case 1: nil
        default: "Selection"
        }
    }

    @ViewBuilder private func options(_ editor: SketchEditor) -> some View {
        // Explicit label: an iPad menu picker shows only its value.
        HStack {
            Text("Snap to grid").foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.s)
            Picker("Snap to grid", selection: Binding(
                get: { editor.gridSize },
                set: { session.sketchEditor?.gridSize = $0 })) {
                Text("Off").tag(0.0)
                Text("0.1 mm").tag(0.1)
                Text("0.5 mm").tag(0.5)
                Text("1 mm").tag(1.0)
                Text("5 mm").tag(5.0)
            }
            .labelsHidden()
            .fixedSize()
        }
        Toggle("Draw construction lines", isOn: Binding(
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
            Hint(Self.drawingHint, symbol: "pencil.tip")
        } else if shapes.count == 1, let shape = shapes.first {
            ShapeDimensions(shape: shape, evaluator: ev) { updated in
                session.updateSketch("Edit \(updated.kind.typeName.capitalized)") { sketch in
                    if let i = sketch.shapes.firstIndex(where: { $0.id == updated.id }) { sketch.shapes[i] = updated }
                }
            }
        } else {
            Text("\(shapes.count) shapes selected").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
        }
        if !shapes.isEmpty {
            // Side by side, or at accessibility sizes stacked at full width, where two buttons
            // in a row would break "Construction" mid-word.
            let stacked = typeSize.isAccessibilitySize
            let row = stacked ? AnyLayout(VStackLayout(spacing: Theme.Space.s)) : AnyLayout(HStackLayout(spacing: Theme.Space.s))
            row {
                Button { session.toggleConstructionOfSelection() } label: {
                    Label("Construction", systemImage: "line.diagonal").frame(maxWidth: stacked ? .infinity : nil)
                }
                .buttonStyle(SecondaryButtonStyle())
                if !stacked { Spacer(minLength: 0) }
                Button(role: .destructive) { session.deleteSelectedSketchShapes() } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: stacked ? .infinity : nil)
                }
                .buttonStyle(SecondaryButtonStyle(role: .destructive))
                // ⌘⌫, the platform "delete object" chord: a bare ⌫ key equivalent could
                // compete with a focused field. Plain ⌫ still works on Mac via onDeleteCommand.
                .keyboardShortcut(.delete, modifiers: .command)
            }
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(shape.kind.typeName.capitalized).font(Theme.sectionTitle).foregroundStyle(Theme.ink)
                if shape.construction {
                    Text("Construction").font(Theme.caption.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }
            switch shape.kind {
            case .line(let a, let b):
                PointField(label: "Start", value: a, evaluator: evaluator) { update(.line(a: $0, b: b)) }
                PointField(label: "End", value: b, evaluator: evaluator) { update(.line(a: a, b: $0)) }
                if let pa = try? a.evaluate(using: evaluator), let pb = try? b.evaluate(using: evaluator) {
                    let d = pb - pa
                    Text("Length \(ExprField.format((d.x * d.x + d.y * d.y).squareRoot())) mm, angle \(ExprField.format(atan2(d.y, d.x) * 180 / .pi))°")
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                }
            case .rectangle(let anchor, let position, let width, let height, let angle):
                ThemeSegmented("Anchor", selection: anchor, options: [(.corner, "Corner"), (.center, "Center")]) {
                    update(.rectangle(anchor: $0, position: position, width: width, height: height, angle: angle))
                }
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
                Text("\(vertices.count) points\(closed ? ", closed" : "")").font(Theme.body).foregroundStyle(Theme.inkSecondary)
            case .spline(let points):
                Text("\(points.count) points").font(Theme.body).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}
