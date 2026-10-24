import FilletCore
import FilletKernel
import SwiftUI

/// Right-hand panel: the feature being edited, the open sketch, or the
/// current selection. Header and actions stay put; only the controls scroll.
struct InspectorView: View {
    @Bindable var session: DesignSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if session.sketchEditor != nil {
                        SketchInspector(session: session)
                    } else if let feature = session.editingFeature {
                        FeatureInspector(session: session, feature: feature)
                    } else {
                        SelectionInspector(session: session)
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if session.sketchEditor == nil, session.editingFeature != nil {
                InspectorFooter(cancel: session.cancelEdit, done: session.commitEdit)
            }
        }
        .background(Theme.panel)
    }
}

/// Icon chip, editable title and status line at the top of the inspector.
struct InspectorHeader: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var error: String?
    var onRename: ((String) -> Void)?

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                IconChip(symbol: symbol, tint: error == nil ? Theme.filletInk : Theme.dangerInk, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    if let onRename {
                        TextField("Name", text: $text)
                            .textFieldStyle(.plain)
                            .font(Theme.title)
                            .foregroundStyle(Theme.ink)
                            .onSubmit { onRename(text) }
                            .onAppear { text = title }
                            .onChange(of: title) { _, t in text = t }
                    } else {
                        Text(title).font(Theme.title).foregroundStyle(Theme.ink)
                    }
                    if let subtitle {
                        Text(subtitle).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.body)
                .foregroundStyle(Theme.dangerInk)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.dangerSoft))
                .transition(.opacity.animation(Theme.Motion.hover))
            }
        }
    }
}

/// Cancel / Done, pinned to the bottom of the inspector.
struct InspectorFooter: View {
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Cancel", action: cancel)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
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

// MARK: - Feature editing

struct FeatureInspector: View {
    @Bindable var session: DesignSession
    let feature: Feature

    private var ev: Evaluator { session.model.parameters.evaluator }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            InspectorHeader(
                symbol: feature.kind.symbol, title: feature.name, subtitle: feature.kind.subtitle,
                error: session.model.error(for: feature.id),
                onRename: { name in session.updateEditing { $0.name = name } })
            VStack(alignment: .leading, spacing: Theme.Space.m) { content }
        }
    }

    private func set(_ kind: FeatureKind) { session.updateEditing { $0.kind = kind } }

    @ViewBuilder private var content: some View {
        switch feature.kind {
        case .extrude(let e): extrude(e)
        case .revolve(let r): revolve(r)
        case .fillet(let f): edgeFeature(f, fillet: true)
        case .chamfer(let f): edgeFeature(f, fillet: false)
        case .shell(let s): shell(s)
        case .primitive(let p): primitive(p)
        case .combine(let c): combine(c)
        case .move(let m): move(m)
        case .mirror(let m): mirror(m)
        case .pattern(let p): pattern(p)
        case .layFlat:
            Hint("Tap another flat face to change which side touches the bed.")
        case .importedSTEP(let s):
            Hint("Imported from \(s.name). Add sketches and features on top of it.", symbol: "square.and.arrow.down")
        case .sketch, .unknown:
            EmptyView()
        }
    }

    // MARK: Extrude / revolve

    @ViewBuilder private func extrude(_ e: Extrude) -> some View {
        SelectionCount(count: e.regions.count, noun: "profile", hint: "Tap profiles in the sketch") {
            var x = e; x.regions = []; set(.extrude(x))
        }
        OperationPicker(operation: e.operation) { var x = e; x.operation = $0; set(.extrude(x)) }
        ExprField(label: "Distance", value: e.distance, evaluator: ev) { var x = e; x.distance = $0; set(.extrude(x)) }
        Labeled("Direction") {
            Picker("Direction", selection: Binding(
                get: { e.symmetric ? 1 : (e.back == nil ? 0 : 2) },
                set: { mode in
                    var x = e
                    x.symmetric = mode == 1
                    x.back = mode == 2 ? (e.back ?? 5) : nil
                    set(.extrude(x))
                })) {
                Text("One side").tag(0)
                Text("Symmetric").tag(1)
                Text("Two sides").tag(2)
            }
            .pickerStyle(.segmented)
        }
        if let back = e.back, !e.symmetric {
            ExprField(label: "Back", value: back, evaluator: ev) { var x = e; x.back = $0; set(.extrude(x)) }
        }
        ExprField(label: "Taper", value: e.taper, kind: .angle, evaluator: ev) { var x = e; x.taper = $0; set(.extrude(x)) }
        Button {
            var x = e
            x.distance = Expr(stringLiteral: e.distance.source.hasPrefix("-") ? String(e.distance.source.dropFirst()) : "-(\(e.distance.source))")
            if e.distance.isLiteral, let v = try? ev.length(e.distance) { x.distance = Expr(-v) }
            set(.extrude(x))
        } label: { Label("Flip direction", systemImage: "arrow.up.arrow.down") }
        .buttonStyle(SecondaryButtonStyle())
        Hint("Drag the arrow in the viewport to change the distance.", symbol: "hand.draw")
    }

    @ViewBuilder private func revolve(_ r: Revolve) -> some View {
        SelectionCount(count: r.regions.count, noun: "profile", hint: "Tap profiles in the sketch") {
            var x = r; x.regions = []; set(.revolve(x))
        }
        OperationPicker(operation: r.operation) { var x = r; x.operation = $0; set(.revolve(x)) }
        Labeled("Axis") {
            Picker("Axis", selection: Binding(
                get: { r.axis },
                set: { var x = r; x.axis = $0; set(.revolve(x)) })) {
                Text("Sketch X").tag(RevolveAxis.x)
                Text("Sketch Y").tag(RevolveAxis.y)
                ForEach(sketchLines(r.sketch), id: \.self) { id in
                    Text("Line \(id.uuidString.prefix(4))").tag(RevolveAxis.sketchLine(id))
                }
            }
        }
        ExprField(label: "Angle", value: r.angle, kind: .angle, evaluator: ev) { var x = r; x.angle = $0; set(.revolve(x)) }
    }

    private func sketchLines(_ sketch: UUID) -> [UUID] {
        guard case .sketch(let s) = session.document.feature(sketch)?.kind else { return [] }
        return s.shapes.compactMap { if case .line = $0.kind { $0.id } else { nil } }
    }

    // MARK: Modify

    @ViewBuilder private func edgeFeature(_ f: EdgeFeature, fillet: Bool) -> some View {
        SelectionCount(count: f.edges.count, noun: "edge", hint: "Tap edges in the viewport") {
            var x = f; x.edges = []
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        ExprField(label: fillet ? "Radius" : "Distance", value: f.size, evaluator: ev) {
            var x = f; x.size = $0
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        Hint(fillet ? "Tip: a 0.5–1 mm fillet on the bottom edges helps parts come off the bed; chamfers print overhang-free."
                    : "Chamfers on bottom edges print without supports.")
    }

    @ViewBuilder private func shell(_ s: Shell) -> some View {
        SelectionCount(count: s.removeFaces.count, noun: "open face", hint: "Tap faces to remove (leave none for a closed hollow)") {
            var x = s; x.removeFaces = []; set(.shell(x))
        }
        ExprField(label: "Thickness", value: s.thickness, evaluator: ev) { var x = s; x.thickness = $0; set(.shell(x)) }
        Hint("Walls of 2–3 nozzle widths (0.8–1.2 mm on a 0.4 mm nozzle) print cleanly.")
    }

    @ViewBuilder private func primitive(_ p: Primitive) -> some View {
        Labeled("Shape") {
            Picker("Shape", selection: Binding(
                get: { p.kind },
                set: { kind in
                    var x = p
                    x.kind = kind
                    x.dimensions = kind.dimensionNames.indices.map { $0 < p.dimensions.count ? p.dimensions[$0] : 20 }
                    set(.primitive(x))
                })) {
                ForEach(PrimitiveKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
        OperationPicker(operation: p.operation) { var x = p; x.operation = $0; set(.primitive(x)) }
        ForEach(Array(p.kind.dimensionNames.enumerated()), id: \.offset) { i, name in
            ExprField(label: name.capitalized, value: i < p.dimensions.count ? p.dimensions[i] : 0, evaluator: ev) { v in
                var x = p
                while x.dimensions.count <= i { x.dimensions.append(20) }
                x.dimensions[i] = v
                set(.primitive(x))
            }
        }
        StandardPlanePicker(plane: p.plane) { var x = p; x.plane = $0; set(.primitive(x)) }
        PointField(label: "Position", value: p.position, evaluator: ev) { var x = p; x.position = $0; set(.primitive(x)) }
    }

    @ViewBuilder private func combine(_ c: Combine) -> some View {
        Labeled("Target") {
            Picker("Target", selection: Binding(
                get: { c.target },
                set: { var x = c; x.target = $0; x.tools.removeAll { $0 == x.target }; set(.combine(x)) })) {
                ForEach(session.model.bodies) { Text($0.name).tag($0.ref) }
            }
        }
        SelectionCount(count: c.tools.count, noun: "tool body", hint: "Tap the bodies to combine with the target") {
            var x = c; x.tools = []; set(.combine(x))
        }
        Labeled("Operation") {
            Picker("Operation", selection: Binding(
                get: { c.operation },
                set: { var x = c; x.operation = $0; set(.combine(x)) })) {
                Text("Join").tag(Operation.join)
                Text("Cut").tag(Operation.cut)
                Text("Intersect").tag(Operation.intersect)
            }
            .pickerStyle(.segmented)
        }
        Toggle("Keep tool bodies", isOn: Binding(get: { c.keepTools }, set: { var x = c; x.keepTools = $0; set(.combine(x)) }))
    }

    @ViewBuilder private func move(_ m: Move) -> some View {
        SelectionCount(count: m.bodies.count, noun: "body", hint: "Tap bodies to move") {
            var x = m; x.bodies = []; set(.move(x))
        }
        Text("Translate").font(Theme.sectionTitle).foregroundStyle(Theme.ink)
        ExprField(label: "X", value: m.translation.x, evaluator: ev) { var x = m; x.translation.x = $0; set(.move(x)) }
        ExprField(label: "Y", value: m.translation.y, evaluator: ev) { var x = m; x.translation.y = $0; set(.move(x)) }
        ExprField(label: "Z", value: m.translation.z, evaluator: ev) { var x = m; x.translation.z = $0; set(.move(x)) }
        Text("Rotate").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, 4)
        AxisPicker(axis: m.rotationAxis) { var x = m; x.rotationAxis = $0; set(.move(x)) }
        ExprField(label: "Angle", value: m.rotationAngle, kind: .angle, evaluator: ev) { var x = m; x.rotationAngle = $0; set(.move(x)) }
    }

    @ViewBuilder private func mirror(_ m: Mirror) -> some View {
        SelectionCount(count: m.bodies.count, noun: "body", hint: "Tap bodies to mirror") {
            var x = m; x.bodies = []; set(.mirror(x))
        }
        StandardPlanePicker(plane: m.plane) { var x = m; x.plane = $0; set(.mirror(x)) }
        Toggle("Merge with original", isOn: Binding(get: { m.merge }, set: { var x = m; x.merge = $0; set(.mirror(x)) }))
    }

    @ViewBuilder private func pattern(_ p: Pattern) -> some View {
        SelectionCount(count: p.bodies.count, noun: "body", hint: "Tap bodies to pattern") {
            var x = p; x.bodies = []; set(.pattern(x))
        }
        Labeled("Type") {
            Picker("Type", selection: Binding(
                get: { if case .linear = p.layout { 0 } else { 1 } },
                set: { t in
                    var x = p
                    x.layout = t == 0 ? .linear(direction: .x, count: 3, spacing: 20) : .circular(axis: .z, count: 6, angle: 360)
                    set(.pattern(x))
                })) {
                Text("Linear").tag(0)
                Text("Circular").tag(1)
            }
            .pickerStyle(.segmented)
        }
        switch p.layout {
        case .linear(let dir, let count, let spacing):
            AxisPicker(axis: dir) { var x = p; x.layout = .linear(direction: $0, count: count, spacing: spacing); set(.pattern(x)) }
            ExprField(label: "Count", value: count, kind: .scalar, evaluator: ev) { var x = p; x.layout = .linear(direction: dir, count: $0, spacing: spacing); set(.pattern(x)) }
            ExprField(label: "Spacing", value: spacing, evaluator: ev) { var x = p; x.layout = .linear(direction: dir, count: count, spacing: $0); set(.pattern(x)) }
        case .circular(let axis, let count, let angle):
            AxisPicker(axis: axis) { var x = p; x.layout = .circular(axis: $0, count: count, angle: angle); set(.pattern(x)) }
            ExprField(label: "Count", value: count, kind: .scalar, evaluator: ev) { var x = p; x.layout = .circular(axis: axis, count: $0, angle: angle); set(.pattern(x)) }
            ExprField(label: "Angle", value: angle, kind: .angle, evaluator: ev) { var x = p; x.layout = .circular(axis: axis, count: count, angle: $0); set(.pattern(x)) }
        }
    }
}

// MARK: - Small building blocks

/// A control with its label above it, so wide controls (segmented pickers) get the full width.
struct Labeled<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(label).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
            content.labelsHidden()
        }
    }
}

/// Guidance or a printing tip, quiet enough to ignore.
struct Hint: View {
    let text: String
    var symbol = "lightbulb.min"
    init(_ text: String, symbol: String = "lightbulb.min") { self.text = text; self.symbol = symbol }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(Theme.inkTertiary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkSecondary)
    }
}

/// What a feature has picked in the viewport. Empty: a dashed well waiting
/// for taps. Filled: a blue-tinted card, matching the viewport's selection colour.
struct SelectionCount: View {
    let count: Int
    let noun: String
    let hint: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: count > 0 ? "checkmark.circle.fill" : "hand.tap")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(count > 0 ? Theme.select : Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 0 ? "Pick \(noun)s" : "\(count) \(noun)\(count == 1 ? "" : "s") picked")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(hint).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
            if count > 0 {
                Button("Clear", action: clear).buttonStyle(InlineButtonStyle(tint: Theme.selectInk))
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(count > 0 ? Theme.selectSoft : Theme.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(count > 0 ? Theme.select.opacity(0.35) : Theme.hairlineStrong,
                          style: StrokeStyle(lineWidth: 1, dash: count > 0 ? [] : [4, 3])))
        .animation(Theme.Motion.hover, value: count)
    }
}

struct OperationPicker: View {
    let operation: Operation
    let onChange: (Operation) -> Void
    var body: some View {
        Labeled("Operation") {
            Picker("Operation", selection: Binding(get: { operation }, set: { onChange($0) })) {
                Label("New", systemImage: "cube").tag(Operation.newBody)
                Label("Join", systemImage: "plus.square").tag(Operation.join)
                Label("Cut", systemImage: "minus.square").tag(Operation.cut)
                Label("Intersect", systemImage: "square.on.square.intersection.dashed").tag(Operation.intersect)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct StandardPlanePicker: View {
    let plane: SketchPlaneRef
    let onChange: (SketchPlaneRef) -> Void
    var body: some View {
        Labeled("Plane") {
            Picker("Plane", selection: Binding(
                get: { if case .standard(let p, _) = plane { p } else { StandardPlane.xy } },
                set: { onChange(.standard($0, offset: 0)) })) {
                Text("XY (bed)").tag(StandardPlane.xy)
                Text("XZ (front)").tag(StandardPlane.xz)
                Text("YZ (side)").tag(StandardPlane.yz)
            }
        }
    }
}

struct AxisPicker: View {
    let axis: AxisRef
    let onChange: (AxisRef) -> Void
    var body: some View {
        Labeled("Axis") {
            Picker("Axis", selection: Binding(
                get: { if case .edge = axis { 3 } else { axis == .x ? 0 : axis == .y ? 1 : 2 } },
                set: { onChange([AxisRef.x, .y, .z][min($0, 2)]) })) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
                if case .edge = axis { Text("Edge").tag(3) }
            }
            .pickerStyle(.segmented)
        }
    }
}

extension FeatureKind {
    /// SF Symbol for the timeline and inspector.
    var symbol: String {
        switch self {
        case .sketch: "pencil.and.outline"
        case .extrude: "square.stack.3d.up"
        case .revolve: "arrow.triangle.2.circlepath"
        case .fillet: "rectangle.roundedtop"
        case .chamfer: "skew"
        case .shell: "cube.transparent"
        case .primitive(let p):
            switch p.kind {
            case .box: "cube"
            case .cylinder: "cylinder"
            case .sphere: "circle.circle"
            case .cone: "cone"
            case .torus: "torus"
            }
        case .combine: "square.on.square"
        case .move: "move.3d"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .pattern: "square.grid.3x1.below.line.grid.1x2"
        case .importedSTEP: "square.and.arrow.down"
        case .layFlat: "arrow.down.to.line"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

extension FeatureKind {
    /// One line under the inspector title saying what the feature does.
    var subtitle: String {
        switch self {
        case .sketch: "2D profile on a plane"
        case .extrude: "Pushes profiles into a solid"
        case .revolve: "Spins profiles around an axis"
        case .fillet: "Rounds edges"
        case .chamfer: "Bevels edges"
        case .shell: "Hollows a body"
        case .primitive(let p): "\(p.kind.rawValue.capitalized) solid"
        case .combine: "Joins, cuts or intersects bodies"
        case .move: "Moves and rotates bodies"
        case .mirror: "Mirrors bodies across a plane"
        case .pattern: "Repeats bodies"
        case .importedSTEP: "Imported geometry"
        case .layFlat: "Puts a face on the print bed"
        case .unknown: "Needs a newer version of Fillet"
        }
    }
}
