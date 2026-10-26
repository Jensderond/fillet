import FilletCore
import FilletKernel
import FilletViewport
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
                    } else if session.measure != nil {
                        MeasureInspector(session: session)
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
            // A row cut by a short drawer or panel fades out, so it reads as "more below".
            .scrollEdgeFade()
            if session.sketchEditor != nil {
                if showsSketchFooter { SketchFooter(finish: session.finishSketch) }
            } else if let measure = session.measure {
                MeasureFooter(canClear: !measure.picks.isEmpty, clear: session.escapeMeasure, done: session.endMeasure)
            } else if session.editingFeature != nil {
                InspectorFooter(cancel: session.cancelEdit, done: session.commitEdit)
            }
        }
        .background(Theme.panel)
        .dynamicTypeSize(...Theme.TypeLimit.panel)
    }
}

/// The inspector docked under the viewport at compact widths. Drag the grabber between three
/// heights (just the header and actions, a short panel that keeps the model in view, a tall
/// one for long forms); a quick flick is enough to move a detent, and a tap toggles short and
/// tall. (A system sheet would be a centred form sheet on iPad at these widths and cover the
/// model being picked.)
struct InspectorDrawer: View {
    @Bindable var session: DesignSession
    @State private var detent = 340.0
    /// Live drag distance (points, up = positive) while the grabber is held.
    @State private var drag = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let detents = [156.0, 340, 560]
    private var range: ClosedRange<Double> { Self.detents.first!...Self.detents.last! }
    private var height: Double { Momentum.rubberBand(detent + drag, in: range) }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.hairlineStrong)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag = -$0.translation.height }
                    .onEnded { value in
                        let released = Momentum.rubberBand(detent - value.translation.height, in: range)
                        let target = Momentum.restingPoint(from: released, velocity: -value.velocity.height, among: Self.detents)
                        settle(at: target)
                    })
                .onTapGesture { settle(at: detent < Self.detents[2] ? Self.detents[2] : Self.detents[1]) }
                .accessibilityElement()
                .accessibilityLabel("Inspector height")
                .accessibilityValue(detent >= Self.detents[2] ? "Tall" : detent <= Self.detents[0] ? "Header only" : "Short")
                .accessibilityHint("Swipe up or down to change the height")
                .accessibilityAdjustableAction { direction in
                    let i = Self.detents.firstIndex(of: detent) ?? 1
                    let next = direction == .increment ? min(i + 1, Self.detents.count - 1) : max(i - 1, 0)
                    settle(at: Self.detents[next])
                }
            InspectorView(session: session)
        }
        .frame(height: height)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .sensoryFeedback(.selection, trigger: detent)
    }

    /// Springs to a detent from where the finger let go (the height is continuous, so the spring
    /// picks up from there); cuts under Reduce Motion.
    private func settle(at target: Double) {
        var t = Transaction(animation: reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.12))
        t.disablesAnimations = reduceMotion
        withTransaction(t) {
            detent = target
            drag = 0
        }
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
        .automationFrame("finish-sketch-button")
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
    /// Shown when there's no error: the step works, but something about it needs checking.
    var warning: String?
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
            } else if let warning {
                // Like the error card, in the warning amber: the step still works.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                    Text(warning).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.body)
                .foregroundStyle(Theme.warn)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.warn.opacity(0.12)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Warning: \(warning)")
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
            .automationFrame("inspector-done")
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
                error: session.model.error(for: feature.id), warning: session.model.referenceWarning(for: feature),
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
        case .hole(let h): HoleInspector(hole: h, evaluator: ev, set: { set(.hole($0)) }, applyPreset: { session.applyHolePreset($0) })
        case .pressPull(let p): PressPullInspector(session: session, pressPull: p)
        case .primitive(let p): primitive(p)
        case .combine(let c): combine(c)
        case .move(let m): move(m)
        case .scale(let sc): scale(sc)
        case .loft(let l): loft(l)
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
        let chains = f.tangentChain && !f.edges.isEmpty
        SelectionCount(count: session.pickedEdgeCount(f), noun: "edge", plural: "edges",
                       hint: chains ? "In \(f.edges.count) tangent \(f.edges.count == 1 ? "chain" : "chains"). \(Theme.Copy.pick) one to drop it."
                                    : "\(Theme.Copy.pick) edges in the viewport") {
            var x = f; x.edges = []
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        TangentChainToggle(isOn: f.tangentChain) { session.setTangentChain($0) }
        ExprField(label: fillet ? "Radius" : "Distance", value: f.size, evaluator: ev) {
            var x = f; x.size = $0
            set(fillet ? .fillet(x) : .chamfer(x))
        }
        Hint(Theme.Copy.boxEdgesHint, symbol: "rectangle.dashed")
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
            .tint(Theme.switchOn)
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
        // Only moves made by an agent have a centre; the axis then runs through it instead of the origin.
        if let c = m.rotationCenter, m.rotationAxis.referencedBodies.isEmpty {
            Text("Rotation center").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
            ExprField(label: "X", value: c.x, evaluator: ev) { var x = m; x.rotationCenter?.x = $0; set(.move(x)) }
            ExprField(label: "Y", value: c.y, evaluator: ev) { var x = m; x.rotationCenter?.y = $0; set(.move(x)) }
            ExprField(label: "Z", value: c.z, evaluator: ev) { var x = m; x.rotationCenter?.z = $0; set(.move(x)) }
        }
    }

    @ViewBuilder private func scale(_ sc: Scale) -> some View {
        SelectionCount(count: sc.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to scale") {
            var x = sc; x.bodies = []; set(.scale(x))
        }
        Text("Factors").font(Theme.sectionTitle).foregroundStyle(Theme.ink)
        ExprField(label: "X", value: sc.factors.x, kind: .scalar, evaluator: ev) { var x = sc; x.factors.x = $0; set(.scale(x)) }
        ExprField(label: "Y", value: sc.factors.y, kind: .scalar, evaluator: ev) { var x = sc; x.factors.y = $0; set(.scale(x)) }
        ExprField(label: "Z", value: sc.factors.z, kind: .scalar, evaluator: ev) { var x = sc; x.factors.z = $0; set(.scale(x)) }
        Text("Center").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
        ExprField(label: "X", value: sc.center.x, evaluator: ev) { var x = sc; x.center.x = $0; set(.scale(x)) }
        ExprField(label: "Y", value: sc.center.y, evaluator: ev) { var x = sc; x.center.y = $0; set(.scale(x)) }
        ExprField(label: "Z", value: sc.center.z, evaluator: ev) { var x = sc; x.center.z = $0; set(.scale(x)) }
        // Only scales made by an agent are turned; the factors then apply along the turned axes.
        if let o = sc.orientation {
            Text("Axes turned about").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
            ExprField(label: "X", value: o.axis.x, kind: .scalar, evaluator: ev) { var x = sc; x.orientation?.axis.x = $0; set(.scale(x)) }
            ExprField(label: "Y", value: o.axis.y, kind: .scalar, evaluator: ev) { var x = sc; x.orientation?.axis.y = $0; set(.scale(x)) }
            ExprField(label: "Z", value: o.axis.z, kind: .scalar, evaluator: ev) { var x = sc; x.orientation?.axis.z = $0; set(.scale(x)) }
            ExprField(label: "Angle", value: o.angle, kind: .angle, evaluator: ev) { var x = sc; x.orientation?.angle = $0; set(.scale(x)) }
        }
    }

    /// Lofts come from agents (sections in space are hard to place by hand); here their sizes and
    /// positions can be tuned.
    @ViewBuilder private func loft(_ l: Loft) -> some View {
        OperationPicker(operation: l.operation) { var x = l; x.operation = $0; set(.loft(x)) }
        Toggle("Smooth", isOn: Binding(get: { !l.ruled }, set: { var x = l; x.ruled = !$0; set(.loft(x)) }))
            .tint(Theme.switchOn)
        ForEach(Array(l.sections.enumerated()), id: \.offset) { i, section in
            Text("Section \(i + 1)").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
            ExprField(label: section.height == nil ? "Diameter" : "Width", value: section.width, evaluator: ev) { v in
                var x = l; x.sections[i].width = v; set(.loft(x))
            }
            if let height = section.height {
                ExprField(label: "Height", value: height, evaluator: ev) { v in var x = l; x.sections[i].height = v; set(.loft(x)) }
            }
            ExprField(label: "X", value: section.center.x, evaluator: ev) { v in var x = l; x.sections[i].center.x = v; set(.loft(x)) }
            ExprField(label: "Y", value: section.center.y, evaluator: ev) { v in var x = l; x.sections[i].center.y = v; set(.loft(x)) }
            ExprField(label: "Z", value: section.center.z, evaluator: ev) { v in var x = l; x.sections[i].center.z = v; set(.loft(x)) }
        }
    }

    @ViewBuilder private func mirror(_ m: Mirror) -> some View {
        SelectionCount(count: m.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to mirror") {
            var x = m; x.bodies = []; set(.mirror(x))
        }
        StandardPlanePicker(plane: m.plane) { var x = m; x.plane = $0; set(.mirror(x)) }
        Toggle("Merge with original", isOn: Binding(get: { m.merge }, set: { var x = m; x.merge = $0; set(.mirror(x)) }))
            .tint(Theme.switchOn)
    }

    @ViewBuilder private func pattern(_ p: Pattern) -> some View {
        // Like Fusion: repeat whole bodies, or timeline steps (a cut repeats as more cuts).
        Labeled("Objects") {
            ThemeSegmented("Objects", selection: p.objects, options: [(.bodies, "Bodies"), (.features, "Features")]) { objects in
                var x = p; x.objects = objects; x.bodies = []; x.features = []; set(.pattern(x))
            }
        }
        switch p.objects {
        case .bodies:
            SelectionCount(count: p.bodies.count, noun: "body", plural: "bodies", hint: "\(Theme.Copy.pick) bodies to pattern") {
                var x = p; x.bodies = []; set(.pattern(x))
            }
        case .features:
            SelectionCount(count: p.features.count, noun: "step", plural: "steps", hint: "\(Theme.Copy.pick) steps in the timeline") {
                var x = p; x.features = []; set(.pattern(x))
            }
            if !p.features.isEmpty {
                // In timeline order, the order the pattern repeats them in.
                let doc = session.document
                let ordered = p.features.sorted { (doc.index(of: $0) ?? .max) < (doc.index(of: $1) ?? .max) }
                PatternStepList(steps: ordered.map { (id: $0, feature: doc.feature($0)) }) { id in
                    var x = p; x.features.removeAll { $0 == id }; set(.pattern(x))
                }
            }
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

/// The steps a feature pattern repeats, in the order picked, each with a way to drop it.
private struct PatternStepList: View {
    let steps: [(id: UUID, feature: Feature?)]
    let remove: (UUID) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                if i > 0 { Theme.hairline.frame(height: 1).padding(.leading, Theme.Space.m + 26 + Theme.Space.s) }
                row(step.id, step.feature)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .animation(Theme.Motion.hover, value: steps.map(\.id))
    }

    private func row(_ id: UUID, _ feature: Feature?) -> some View {
        // A step deleted since it was picked stays listed, so the pattern's error makes sense.
        let name = feature?.name ?? "Missing step"
        return HStack(spacing: Theme.Space.s) {
            IconChip(symbol: feature?.kind.symbol ?? "questionmark.square.dashed",
                     tint: feature == nil ? Theme.dangerInk : Theme.ink, size: 26)
            Text(name)
                .font(Theme.body)
                .foregroundStyle(feature == nil ? Theme.dangerInk : Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button { remove(id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Theme.Metrics.targetCompact(touch: touch), height: Theme.Metrics.targetCompact(touch: touch))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .hoverHighlight()
            .help("Remove \(name) from the pattern")
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, touch ? 0 : 2)
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

/// Fillet's segmented control: equal-width segments on a track, the chosen one on a raised
/// thumb (light) or a slate plate (dark). Unlike the system control it follows Dynamic Type, matches widths
/// across rows, and is 32 pt with a pointer and 44 pt on touch.
struct ThemeSegmented<Value: Hashable>: View {
    let label: String
    let selection: Value
    let options: [(value: Value, title: String)]
    let onChange: (Value) -> Void
    @Environment(\.touchTargets) private var touch
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    init(_ label: String, selection: Value, options: [(Value, String)], onChange: @escaping (Value) -> Void) {
        self.label = label
        self.selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.onChange = onChange
    }

    var body: some View {
        // At accessibility sizes the segments stack, so no label is ever truncated.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    if !selected { onChange(option.value) }
                } label: {
                    // Light: the chosen segment is a raised white thumb with an inkTertiary rim on a
                    // tinted track, the same "on" look as the tool-strip toggles, quieter than a solid
                    // block next to the orange primary. Dark: a solid slate plate (5.9:1 to the track).
                    Text(option.title)
                        .font(Theme.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (isDark ? Theme.raised : Theme.ink) : Theme.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, Theme.Space.xs)
                        .frame(maxWidth: .infinity, minHeight: (touch ? 44 : 32) - 4)
                        .background {
                            let plate = RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                            if selected {
                                if isDark {
                                    plate.fill(Theme.inkSecondary)
                                } else {
                                    plate.fill(Theme.raised)
                                        .overlay(plate.strokeBorder(Theme.inkTertiary, lineWidth: 1))
                                        .shadow(color: Theme.ink.opacity(0.08), radius: 1.5, y: 1)
                                }
                            }
                        }
                        // Over the track's rim and into the gaps above and below (see `VerticalBleed`).
                        .contentShape(VerticalBleed(2 + Theme.Space.xs))
                }
                .buttonStyle(PressableStyle())
                .hoverHighlight(cornerRadius: Theme.Radius.control - 2)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isDark ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Theme.hairline)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.hover, value: selection)
        .automationFrame("segmented.\(label)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var isDark: Bool { colorScheme == .dark }
}

/// Fillet's and Chamfer's "Tangent chain" (Fusion's name): on, a picked edge brings every edge
/// that runs on smoothly from it. A switch with a line saying what it does, like the panel's other
/// options; the small chain glyph echoes how the picked run looks in the viewport.
struct TangentChainToggle: View {
    let isOn: Bool
    let onChange: (Bool) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                // Sized by the label's font, so it grows with Dynamic Type.
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.ink : Theme.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tangent chain").font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(isOn ? "Picks the edges that run on smoothly too" : "Picks single edges")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.switchOn)
        .frame(minHeight: Theme.Metrics.target(touch: touch))
        .animation(Theme.Motion.hover, value: isOn)
        .automationFrame("tangent-chain")
        .help("Tangent chain: a picked edge brings every edge joined smoothly to it, like the rounded outline of a plate")
        .accessibilityHint(isOn ? "Picked edges bring the edges joined smoothly to them" : "Each pick is a single edge")
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes Clear moves under the text, so the text keeps the full width.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
            : AnyLayout(HStackLayout(spacing: Theme.Space.m))
        layout {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if count > 0 {
                Button("Clear", action: clear).buttonStyle(InlineButtonStyle(tint: Theme.selectInk))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .pressPull: "arrow.up.and.down.square"
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
        case .scale: "arrow.up.left.and.arrow.down.right"
        case .loft: "point.3.connected.trianglepath.dotted"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .pattern: "square.grid.3x1.below.line.grid.1x2"
        case .importedSTEP: "square.and.arrow.down"
        case .layFlat: "arrow.down.to.line"
        case .hole: "smallcircle.filled.circle"
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
        case .pressPull: "Moves faces in or out"
        case .primitive(let p): "\(p.kind.rawValue.capitalized) solid"
        case .combine: "Joins, cuts or intersects bodies"
        case .move: "Moves and rotates bodies"
        case .scale: "Stretches or squashes bodies"
        case .loft: "Skins a solid through sections"
        case .mirror: "Mirrors bodies across a plane"
        case .pattern(let p): p.objects == .features ? "Repeats steps from the timeline" : "Repeats bodies"
        case .importedSTEP: "Imported geometry"
        case .layFlat: "Puts a face on the print bed"
        case .hole: "Drills holes into a flat face"
        case .unknown: "Needs a newer version of Fillet"
        }
    }
}
