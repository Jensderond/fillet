import FilletCore
import FilletKernel
import SwiftUI

/// Right-hand panel: the feature being edited, the open sketch, or the
/// current selection. Header and actions stay put; only the controls scroll.
struct InspectorView: View {
    @Bindable var session: DesignSession
    /// Whether this inspector carries Finish sketch (the floating bar has it otherwise).
    var showsSketchFooter = true

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
                // System controls (toggles, steppers, menu pickers) follow the panel's type and
                // ink rather than the platform defaults (17 pt and the orange tint on iPad).
                .font(Theme.body)
                .tint(Theme.ink)
            }
            if session.sketchEditor != nil {
                if showsSketchFooter { SketchFooter(finish: session.finishSketch) }
            } else if session.editingFeature != nil {
                InspectorFooter(cancel: session.cancelEdit, done: session.commitEdit)
            }
        }
        .background(Theme.panel)
        .dynamicTypeSize(...Theme.TypeLimit.panel)
    }
}

/// The inspector docked under the viewport at compact widths. The grabber switches between
/// a short panel that keeps the model in view and a tall one for long forms. (A system sheet
/// would be a centred form sheet on iPad at these widths and cover the model being picked.)
struct InspectorDrawer: View {
    @Bindable var session: DesignSession
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                Capsule().fill(Theme.hairlineStrong)
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.l + Theme.Space.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Make inspector shorter" : "Make inspector taller")
            InspectorView(session: session)
        }
        .frame(height: expanded ? 560 : 340)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .animation(Theme.Motion.enter, value: expanded)
    }
}

/// Finish, pinned to the bottom of the inspector in sketch mode (the counterpart of Cancel / Done).
/// ⌘↩ lives in the Sketch menu, so the button carries no shortcut of its own.
struct SketchFooter: View {
    let finish: () -> Void

    var body: some View {
        Button(action: finish) {
            Label("Finish sketch", systemImage: "checkmark").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .automationMarker("finish-sketch")
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }
}

/// Icon chip, editable title and status line at the top of the inspector.
/// The chip is orange for something being edited, blue for the selection and ink otherwise.
struct InspectorHeader: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = Theme.filletInk
    var error: String?
    var onRename: ((String) -> Void)?

    @State private var text = ""
    @FocusState private var renaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                IconChip(symbol: symbol, tint: error == nil ? tint : Theme.dangerInk, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    if let onRename {
                        TextField("Name", text: $text)
                            .textFieldStyle(.plain)
                            .font(Theme.title)
                            .foregroundStyle(Theme.ink)
                            .focused($renaming)
                            .focusedValue(\.isEditingText, renaming ? true : nil)
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
            Hint("\(Theme.Copy.pick) another flat face to change which side touches the bed.")
        case .importedSTEP(let s):
            Hint("Imported from \(s.name). Add sketches and features on top of it.", symbol: "square.and.arrow.down")
        case .sketch, .unknown:
            EmptyView()
        }
    }

    // MARK: Extrude / revolve

    @ViewBuilder private func extrude(_ e: Extrude) -> some View {
        SelectionCount(count: e.regions.count, noun: "profile", plural: "profiles", hint: "\(Theme.Copy.pick) profiles in the sketch") {
            var x = e; x.regions = []; set(.extrude(x))
        }
        OperationPicker(operation: e.operation) { var x = e; x.operation = $0; set(.extrude(x)) }
        ExprField(label: "Distance", value: e.distance, evaluator: ev) { var x = e; x.distance = $0; set(.extrude(x)) }
        Labeled("Direction") {
            ThemeSegmented("Direction", selection: e.symmetric ? 1 : (e.back == nil ? 0 : 2),
                           options: [(0, "One side"), (1, "Symmetric"), (2, "Two sides")]) { mode in
                var x = e
                x.symmetric = mode == 1
                x.back = mode == 2 ? (e.back ?? 5) : nil
                set(.extrude(x))
            }
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
        SelectionCount(count: r.regions.count, noun: "profile", plural: "profiles", hint: "\(Theme.Copy.pick) profiles in the sketch") {
            var x = r; x.regions = []; set(.revolve(x))
        }
        OperationPicker(operation: r.operation) { var x = r; x.operation = $0; set(.revolve(x)) }
        Labeled("Axis") {
            Picker("Axis", selection: Binding(
                get: { r.axis },
                set: { var x = r; x.axis = $0; set(.revolve(x)) })) {
                Text("Sketch X").tag(RevolveAxis.x)
                Text("Sketch Y").tag(RevolveAxis.y)
                // Lines by their place in the sketch; the chosen one is highlighted in the viewport.
                ForEach(Array(sketchLines(r.sketch).enumerated()), id: \.element) { i, id in
                    Text("Line \(i + 1)").tag(RevolveAxis.sketchLine(id))
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
        SelectionCount(count: f.edges.count, noun: "edge", plural: "edges", hint: "\(Theme.Copy.pick) edges in the viewport") {
            var x = f; x.edges = []
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        ExprField(label: fillet ? "Radius" : "Distance", value: f.size, evaluator: ev) {
            var x = f; x.size = $0
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        Hint(fillet ? "Tip: a 0.5–1 mm fillet on bottom edges helps parts release; chamfers print without supports."
                    : "Chamfers on bottom edges print without supports.")
    }

    @ViewBuilder private func shell(_ s: Shell) -> some View {
        SelectionCount(count: s.removeFaces.count, noun: "open face", plural: "open faces",
                       hint: "\(Theme.Copy.pick) faces to remove (leave none for a closed hollow)") {
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
        SelectionCount(count: c.tools.count, noun: "tool body", plural: "tool bodies", hint: "\(Theme.Copy.pick) the bodies to combine with the target") {
            var x = c; x.tools = []; set(.combine(x))
        }
        Labeled("Operation") {
            ThemeSegmented("Operation", selection: c.operation,
                           options: [(.join, "Join"), (.cut, "Cut"), (.intersect, "Intersect")]) { op in
                var x = c; x.operation = op; set(.combine(x))
            }
        }
        Toggle("Keep tool bodies", isOn: Binding(get: { c.keepTools }, set: { var x = c; x.keepTools = $0; set(.combine(x)) }))
    }

    @ViewBuilder private func move(_ m: Move) -> some View {
        SelectionCount(count: m.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to move") {
            var x = m; x.bodies = []; set(.move(x))
        }
        Text("Translate").font(Theme.sectionTitle).foregroundStyle(Theme.ink)
        ExprField(label: "X", value: m.translation.x, evaluator: ev) { var x = m; x.translation.x = $0; set(.move(x)) }
        ExprField(label: "Y", value: m.translation.y, evaluator: ev) { var x = m; x.translation.y = $0; set(.move(x)) }
        ExprField(label: "Z", value: m.translation.z, evaluator: ev) { var x = m; x.translation.z = $0; set(.move(x)) }
        Text("Rotate").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
        AxisPicker(axis: m.rotationAxis) { var x = m; x.rotationAxis = $0; set(.move(x)) }
        ExprField(label: "Angle", value: m.rotationAngle, kind: .angle, evaluator: ev) { var x = m; x.rotationAngle = $0; set(.move(x)) }
    }

    @ViewBuilder private func mirror(_ m: Mirror) -> some View {
        SelectionCount(count: m.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to mirror") {
            var x = m; x.bodies = []; set(.mirror(x))
        }
        StandardPlanePicker(plane: m.plane) { var x = m; x.plane = $0; set(.mirror(x)) }
        Toggle("Merge with original", isOn: Binding(get: { m.merge }, set: { var x = m; x.merge = $0; set(.mirror(x)) }))
    }

    @ViewBuilder private func pattern(_ p: Pattern) -> some View {
        SelectionCount(count: p.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to pattern") {
            var x = p; x.bodies = []; set(.pattern(x))
        }
        Labeled("Type") {
            ThemeSegmented("Type", selection: { if case .linear = p.layout { 0 } else { 1 } }(),
                           options: [(0, "Linear"), (1, "Circular")]) { t in
                var x = p
                x.layout = t == 0 ? .linear(direction: .x, count: 3, spacing: 20) : .circular(axis: .z, count: 6, angle: 360)
                set(.pattern(x))
            }
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
            content.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Fillet's segmented control: equal-width segments on a raised track, the chosen one in ink
/// on a stronger plate. Unlike the system control it follows Dynamic Type, matches widths
/// across rows, and is 32 pt with a pointer and 44 pt on touch.
struct ThemeSegmented<Value: Hashable>: View {
    let label: String
    let selection: Value
    let options: [(value: Value, title: String)]
    let onChange: (Value) -> Void
    @Environment(\.touchTargets) private var touch

    init(_ label: String, selection: Value, options: [(Value, String)], onChange: @escaping (Value) -> Void) {
        self.label = label
        self.selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    if !selected { onChange(option.value) }
                } label: {
                    Text(option.title)
                        .font(Theme.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, Theme.Space.xs)
                        .frame(maxWidth: .infinity, minHeight: (touch ? 44 : 32) - 4)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                            .fill(selected ? Theme.hairlineStrong : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .hoverHighlight(cornerRadius: Theme.Radius.control - 2)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.hover, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Guidance or a printing tip, quiet enough to ignore.
struct Hint: View {
    let text: Text
    var symbol = "lightbulb.min"
    init(_ text: String, symbol: String = "lightbulb.min") { self.text = Text(text); self.symbol = symbol }
    /// Styled text, e.g. with an expression in the value face.
    init(text: Text, symbol: String = "lightbulb.min") { self.text = text; self.symbol = symbol }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
            text.fixedSize(horizontal: false, vertical: true)
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
    let plural: String
    let hint: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: count > 0 ? "checkmark.circle.fill" : "hand.tap")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(count > 0 ? Theme.select : Theme.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 0 ? "Pick \(plural)" : "\(count) \(count == 1 ? noun : plural) picked")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text(hint).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            .accessibilityElement(children: .combine)
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
            ThemeSegmented("Operation", selection: operation,
                           options: [(.newBody, "New"), (.join, "Join"), (.cut, "Cut"), (.intersect, "Intersect")],
                           onChange: onChange)
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
            let isEdge = { if case .edge = axis { true } else { false } }()
            ThemeSegmented("Axis", selection: isEdge ? 3 : axis == .x ? 0 : axis == .y ? 1 : 2,
                           options: [(0, "X"), (1, "Y"), (2, "Z")] + (isEdge ? [(3, "Edge")] : [])) {
                onChange([AxisRef.x, .y, .z][min($0, 2)])
            }
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
