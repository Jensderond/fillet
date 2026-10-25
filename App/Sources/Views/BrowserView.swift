import FilletCore
import SwiftUI

/// Left sidebar: bodies, sketches and named parameters.
struct BrowserView: View {
    @Bindable var session: DesignSession
    @Environment(\.touchTargets) private var touch

    private var sketches: [Feature] {
        session.document.activeFeatures.filter { if case .sketch = $0.kind { true } else { false } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PanelSection("Bodies") {
                    if session.model.bodies.isEmpty {
                        Hint("Extrude a sketch to make your first body.", symbol: "cube")
                    }
                    VStack(spacing: 2) {
                        ForEach(session.model.bodies) { body in
                            let hidden = session.hiddenBodies.contains(body.ref)
                            BrowserRow(
                                symbol: "cube.fill", title: body.name, selected: session.selection.contains(.body(body.ref)),
                                dimmed: hidden, tint: session.document.bodyColors[body.ref].flatMap(Color.init(bodyHex:)),
                                trailing: {
                                    Button {
                                        if hidden { session.hiddenBodies.remove(body.ref) } else { session.hiddenBodies.insert(body.ref) }
                                    } label: {
                                        Image(systemName: hidden ? "eye.slash" : "eye")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(hidden ? Theme.inkTertiary : Theme.inkSecondary)
                                            .frame(width: touch ? 44 : 26, height: touch ? 44 : 26)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressableStyle())
                                    .hoverHighlight()
                                    .help(hidden ? "Show \(body.name)" : "Hide \(body.name)")
                                    .accessibilityLabel(hidden ? "Show \(body.name)" : "Hide \(body.name)")
                                }
                            ) {
                                session.toggleSelection(.body(body.ref), additive: false)
                            }
                            .contextMenu { BodyColorMenu(session: session, bodyRef: body.ref) }
                        }
                    }
                }
                PanelSection("Sketches") {
                    if sketches.isEmpty {
                        Hint("Sketches you draw are listed here.", symbol: "pencil.and.outline")
                    }
                    VStack(spacing: 2) {
                        ForEach(sketches) { f in
                            BrowserRow(symbol: "pencil.and.outline", title: f.name, selected: false,
                                       isActive: session.sketchEditor?.sketch == f.id,
                                       dimmed: false, trailing: { EmptyView() }) {
                                session.editSketch(f.id)
                            }
                        }
                    }
                }
                ParametersSection(session: session)
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.panel)
        .dynamicTypeSize(...Theme.TypeLimit.panel)
    }
}

/// Display colours for bodies (context menu on a body row).
struct BodyColorMenu: View {
    let session: DesignSession
    let bodyRef: BodyRef

    static let swatches: [(name: String, hex: String)] = [
        ("Slate", ""), ("Red", "#E53935"), ("Orange", "#FB8C00"), ("Yellow", "#FDD835"), ("Green", "#43A047"),
        ("Teal", "#00897B"), ("Blue", "#1E88E5"), ("Purple", "#8E24AA"), ("Pink", "#EC407A"), ("Brown", "#8D6E63"),
        ("White", "#F5F5F5"), ("Black", "#263238"),
    ]

    var body: some View {
        Menu("Color") {
            ForEach(Self.swatches, id: \.name) { swatch in
                Button {
                    session.perform("Color Body") { $0.bodyColors[bodyRef] = swatch.hex.isEmpty ? nil : swatch.hex }
                } label: {
                    Label(swatch.name, systemImage: (session.document.bodyColors[bodyRef] ?? "") == swatch.hex ? "checkmark" : "circle.fill")
                }
            }
        }
    }
}

extension Color {
    /// A body colour as stored in the document (`#RRGGBB`).
    init?(bodyHex: String) {
        let s = bodyHex.hasPrefix("#") ? String(bodyHex.dropFirst()) : bodyHex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// A sidebar row with hover, selected (picked, blue) and active (being edited, orange) states.
struct BrowserRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let selected: Bool
    var isActive = false
    let dimmed: Bool
    /// The body's own colour for the symbol (when it has one and isn't picked or being edited).
    var tint: Color? = nil
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.touchTargets) private var touch

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: action) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? Theme.filletInk : selected ? Theme.select : dimmed ? Theme.inkTertiary : tint ?? Theme.inkSecondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(Theme.body.weight(selected || isActive ? .semibold : .regular))
                        // Hidden bodies step down to secondary ink (5.4:1): quieter, still readable.
                        .foregroundStyle(dimmed ? Theme.inkSecondary : Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            trailing
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.xs)
        .frame(minHeight: touch ? 44 : 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isActive ? Theme.filletSoft : selected ? Theme.selectSoft : hovering ? Theme.hairline : .clear))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .hoverHighlight(ownsPointerHover: true)
    }
}

/// Named parameters that any dimension can reference (`wall`, `width / 2 + wall`).
struct ParametersSection: View {
    @Bindable var session: DesignSession

    var body: some View {
        PanelSection("Parameters") {
            if session.document.parameters.isEmpty {
                Hint(text: Text("Name a value, then use it in any field: \(Text("width / 2 + wall").font(Theme.caption.monospaced()).foregroundStyle(Theme.ink))"),
                     symbol: "function")
            }
            VStack(spacing: Theme.Space.s) {
                ForEach(session.document.parameters) { p in
                    ParameterRow(session: session, parameter: p)
                }
            }
            Button {
                let name = uniqueName()
                session.perform("Add Parameter") { $0.parameters.append(Parameter(name: name, expression: 10)) }
            } label: {
                Label("Add parameter", systemImage: "plus")
            }
            .buttonStyle(InlineButtonStyle())
        }
    }

    private func uniqueName() -> String {
        let names = Set(session.document.parameters.map(\.name))
        var i = 1
        while names.contains("p\(i)") { i += 1 }
        return "p\(i)"
    }
}

struct ParameterRow: View {
    @Bindable var session: DesignSession
    let parameter: Parameter
    @State private var name = ""
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool
    @State private var nameHovering = false
    @Environment(\.touchTargets) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField("name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.body.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($nameFocused)
                    .focusedValue(\.isEditingText, nameFocused ? true : nil)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    // An underline on hover and focus says "this name is editable" (orange while typing).
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(nameFocused ? Theme.filletMark : nameHovering ? Theme.hairlineStrong : .clear)
                            .frame(height: nameFocused ? 1.5 : 1)
                    }
                    .onHover { nameHovering = $0 }
                    .animation(Theme.Motion.hover, value: nameHovering)
                Spacer(minLength: 0)
                Button {
                    session.perform("Delete Parameter") { $0.parameters.removeAll { $0.id == parameter.id } }
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        .frame(width: touch ? 44 : 24, height: touch ? 44 : 24).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .hoverHighlight()
                .help("Delete \(parameter.name)")
                .accessibilityLabel("Delete \(parameter.name)")
            }
            ExprField(label: "=", value: parameter.expression, labelWidth: nil, evaluator: session.model.parameters.evaluator) { expr in
                session.perform("Edit Parameter") { doc in
                    if let i = doc.parameters.firstIndex(where: { $0.id == parameter.id }) { doc.parameters[i].expression = expr }
                }
            }
            if let error = nameError ?? session.model.parameters.errors[parameter.id]?.message {
                Label(error, systemImage: "exclamationmark.circle.fill").font(Theme.caption).foregroundStyle(Theme.dangerInk)
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .onAppear { name = parameter.name }
        .onChange(of: parameter.name) { _, n in name = n }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != parameter.name else { nameError = nil; return }
        if let error = Parameter.validationError(forName: trimmed) {
            nameError = error
            return
        }
        if session.document.parameters.contains(where: { $0.name == trimmed && $0.id != parameter.id }) {
            nameError = "Another parameter is already called \(trimmed)"
            return
        }
        nameError = nil
        let old = parameter.name
        session.perform("Rename Parameter") { doc in
            if let i = doc.parameters.firstIndex(where: { $0.id == parameter.id }) { doc.parameters[i].name = trimmed }
            doc.renameParameterReferences(from: old, to: trimmed)
        }
    }
}
