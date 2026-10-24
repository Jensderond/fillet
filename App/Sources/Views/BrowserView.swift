import FilletCore
import SwiftUI

/// Left sidebar: bodies, sketches and named parameters.
struct BrowserView: View {
    @Bindable var session: DesignSession

    var body: some View {
        List {
            Section("Bodies") {
                if session.model.bodies.isEmpty {
                    Text("No bodies yet").foregroundStyle(.secondary)
                }
                ForEach(session.model.bodies) { body in
                    HStack {
                        Image(systemName: "cube").foregroundStyle(.secondary)
                        Text(body.name)
                        Spacer()
                        Button {
                            if session.hiddenBodies.contains(body.ref) {
                                session.hiddenBodies.remove(body.ref)
                            } else {
                                session.hiddenBodies.insert(body.ref)
                            }
                        } label: {
                            Image(systemName: session.hiddenBodies.contains(body.ref) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.toggleSelection(.body(body.ref), additive: false) }
                    .listRowBackground(session.selection.contains(.body(body.ref)) ? Color.accentColor.opacity(0.15) : nil)
                }
            }
            Section("Sketches") {
                ForEach(session.document.activeFeatures.filter { if case .sketch = $0.kind { true } else { false } }) { f in
                    Button {
                        session.editSketch(f.id)
                    } label: {
                        Label(f.name, systemImage: "pencil.and.outline")
                    }
                    .buttonStyle(.plain)
                }
            }
            ParametersSection(session: session)
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
    }
}

/// Named parameters that any dimension can reference (`wall`, `width/2 + wall`).
struct ParametersSection: View {
    @Bindable var session: DesignSession

    var body: some View {
        Section {
            ForEach(session.document.parameters) { p in
                ParameterRow(session: session, parameter: p)
            }
            Button {
                let name = uniqueName()
                session.perform("Add Parameter") { $0.parameters.append(Parameter(name: name, expression: 10)) }
            } label: {
                Label("Add Parameter", systemImage: "plus")
            }
        } header: {
            Text("Parameters")
        } footer: {
            Text("Use parameter names in any dimension, e.g. width / 2 + wall.").font(.caption)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("name", text: $name)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(commitName)
                Spacer()
                Button(role: .destructive) {
                    session.perform("Delete Parameter") { $0.parameters.removeAll { $0.id == parameter.id } }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }
            ExprField(label: "=", value: parameter.expression, evaluator: evaluatorExcludingSelf) { expr in
                session.perform("Edit Parameter") { doc in
                    if let i = doc.parameters.firstIndex(where: { $0.id == parameter.id }) { doc.parameters[i].expression = expr }
                }
            }
            if let error = nameError ?? session.model.parameters.errors[parameter.id]?.message {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { name = parameter.name }
        .onChange(of: parameter.name) { _, n in name = n }
    }

    /// Other parameters' values, so the field can validate references.
    private var evaluatorExcludingSelf: Evaluator { session.model.parameters.evaluator }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let error = Parameter.validationError(forName: trimmed) {
            nameError = error
            return
        }
        if session.document.parameters.contains(where: { $0.name == trimmed && $0.id != parameter.id }) {
            nameError = "Another parameter is called \(trimmed)"
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
