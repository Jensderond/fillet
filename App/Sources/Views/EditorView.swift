import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// One document window: owns the session and keeps it in sync with the file.
struct EditorView: View {
    @Binding var document: FilletDocument
    let fileURL: URL?

    @State private var session: DesignSession?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let session {
                EditorContent(session: session, fileURL: fileURL)
            } else {
                Color.clear
            }
        }
        .onAppear {
            let s = DesignSession(document: document.model)
            s.undoManager = undoManager
            s.onDocumentChange = { [$document] model in $document.wrappedValue.model = model }
            if document.model.name == nil, let name = fileURL?.deletingPathExtension().lastPathComponent {
                s.documentName = name
            }
            session = s
        }
        .onChange(of: document.model) { _, model in session?.externalUpdate(model) }
        .onChange(of: undoManager) { _, manager in session?.undoManager = manager }
    }
}

struct EditorContent: View {
    @Bindable var session: DesignSession
    let fileURL: URL?

    @State private var controller = ViewportController()
    @State private var showBrowser = true
    @AppStorage("fingerDraws") private var fingerDraws = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var showInspector: Bool {
        session.editing != nil || session.sketchEditor != nil || !session.selection.isEmpty || !session.model.bodies.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolStrip(session: session, controller: controller, showBrowser: $showBrowser)
            Divider()
            HStack(spacing: 0) {
                if showBrowser {
                    BrowserView(session: session)
                        .frame(width: 250)
                    Divider()
                }
                viewport
                if showInspector {
                    Divider()
                    InspectorView(session: session)
                        .frame(width: 320)
                }
            }
            Divider()
            TimelineView(session: session)
        }
        .navigationTitle(session.documentName ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        #endif
        .toolbar { DocumentToolbar(session: session) }
        #if os(macOS)
        .onDeleteCommand {
            if session.sketchEditor != nil { session.deleteSelectedSketchShapes() }
        }
        .onExitCommand { escape() }
        #else
        .onKeyPress(.escape) {
            escape()
            return .handled
        }
        #endif
        .focusedSceneValue(\.session, session)
        #if DEBUG && os(macOS)
        .task { await DebugAutomation.run(session) }
        #endif
        .fileImporter(isPresented: $session.importRequested, allowedContentTypes: [.step]) { result in
            if case .success(let url) = result { session.importSTEP(from: url) }
        }
    }

    private var viewport: some View {
        ZStack(alignment: .top) {
            ViewportView(
                scene: session.makeScene(),
                camera: $session.camera,
                filter: session.pickFilter,
                options: ViewportOptions(fingerDraws: fingerDraws),
                delegate: session,
                controller: controller)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { session.viewSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in session.viewSize = size }
                })
                .ignoresSafeArea(.container, edges: .bottom)

            VStack(spacing: 8) {
                if session.sketchEditor != nil {
                    SketchToolbar(session: session, fingerDraws: $fingerDraws)
                }
                if let hint = currentHint {
                    Text(hint)
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                Spacer()
                if let message = session.message {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .onTapGesture { session.message = nil }
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(4))
                            if session.message == message { session.message = nil }
                        }
                }
            }
            .padding(12)

            if session.isRecomputing {
                ProgressView().controlSize(.small).padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .clipped()
    }

    private var currentHint: String? {
        if let editor = session.sketchEditor { return editor.engine.hint }
        switch session.pickMode {
        case .regions: return "Tap the profiles to use"
        case .edges: return "Tap edges to add or remove them"
        case .faces: return "Tap faces to remove (open) them"
        case .singleFace: return "Tap the face that should touch the bed"
        case .bodies: return "Tap bodies to add or remove them"
        default: return nil
        }
    }

    private func escape() {
        if var editor = session.sketchEditor, !editor.engine.isIdle {
            editor.engine.cancel()
            session.sketchEditor = editor
        } else if session.sketchEditor != nil {
            session.finishSketch()
        } else if session.editing != nil {
            session.cancelEdit()
        } else {
            session.selection = []
        }
    }
}

// MARK: - Toolbars

/// The main tool strip: sketch, create, modify, inspect.
struct ToolStrip: View {
    @Bindable var session: DesignSession
    let controller: ViewportController
    @Binding var showBrowser: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ToolButton("Browser", "sidebar.left", active: showBrowser) { showBrowser.toggle() }
                Divider().frame(height: 28)
                Menu {
                    Button("On XY (bed)") { session.startSketch(on: .xy) }
                    Button("On XZ (front)") { session.startSketch(on: .xz) }
                    Button("On YZ (side)") { session.startSketch(on: .yz) }
                } label: {
                    ToolLabel("Sketch", "pencil.and.outline")
                } primaryAction: {
                    session.startSketch()
                }
                .menuStyle(.button).buttonStyle(.plain)
                Divider().frame(height: 28)
                ToolButton("Extrude", "square.stack.3d.up") { session.startExtrude() }
                ToolButton("Revolve", "arrow.triangle.2.circlepath") { session.startRevolve() }
                Menu {
                    ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) { session.startPrimitive(kind) }
                    }
                } label: { ToolLabel("Primitive", "cube") }
                .menuStyle(.button).buttonStyle(.plain)
                Divider().frame(height: 28)
                ToolButton("Fillet", "rectangle.roundedtop") { session.startEdgeFeature(fillet: true) }
                ToolButton("Chamfer", "skew") { session.startEdgeFeature(fillet: false) }
                ToolButton("Shell", "cube.transparent") { session.startShell() }
                ToolButton("Combine", "square.on.square") { session.startCombine() }
                ToolButton("Move", "move.3d") { session.startMove() }
                ToolButton("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.startMirror() }
                ToolButton("Pattern", "square.grid.3x1.below.line.grid.1x2") { session.startPattern() }
                Divider().frame(height: 28)
                ToolButton("Import", "square.and.arrow.down") { session.importRequested = true }
                ToolButton("Lay Flat", "arrow.down.to.line") { session.startLayFlat() }
                ToolButton("Overhangs", "exclamationmark.triangle", active: session.showOverhangs) { session.showOverhangs.toggle() }
                Divider().frame(height: 28)
                ToolButton("Fit", "arrow.up.left.and.arrow.down.right") { controller.fitAll() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .disabled(session.isBusyEditing)
    }
}

extension DesignSession {
    /// Feature buttons are disabled while a non-sketch feature is open (finish it first).
    var isBusyEditing: Bool { editing != nil && sketchEditor == nil }
}

/// Drawing tools shown at the top of the viewport in sketch mode.
struct SketchToolbar: View {
    @Bindable var session: DesignSession
    @Binding var fingerDraws: Bool

    private let tools: [(SketchTool, String)] = [
        (.select, "cursorarrow"), (.line, "line.diagonal"), (.rectangle, "rectangle"),
        (.centerRectangle, "rectangle.center.inset.filled"), (.circle, "circle"), (.arc, "point.topleft.down.to.point.bottomright.curvepath"),
        (.polygon, "hexagon"), (.slot, "capsule"), (.spline, "scribble"), (.point, "smallcircle.filled.circle"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tools, id: \.0) { tool, symbol in
                Button {
                    session.sketchEditor?.engine.setTool(tool)
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .frame(width: 40, height: 36)
                        .background(session.sketchEditor?.tool == tool ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
            Divider().frame(height: 26)
            if session.sketchEditor?.tool == .spline || session.sketchEditor?.tool == .line {
                Button("Done") {
                    let shapes = session.sketchEditor?.engine.finish() ?? []
                    session.addSketchShapes(shapes)
                }
                .buttonStyle(.bordered)
            }
            #if os(iOS)
            Toggle(isOn: $fingerDraws) { Image(systemName: "hand.draw") }
                .toggleStyle(.button)
                .help("Draw with finger")
            #endif
            Button {
                session.finishSketch()
            } label: {
                Label("Finish", systemImage: "checkmark").fixedSize()
            }
            .buttonStyle(.borderedProminent)
        }
        .fixedSize()
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

struct ToolLabel: View {
    let title: String
    let symbol: String
    var active = false
    init(_ title: String, _ symbol: String, active: Bool = false) {
        self.title = title; self.symbol = symbol; self.active = active
    }
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18)).frame(height: 22)
            Text(title).font(.system(size: 10.5))
        }
        .frame(minWidth: 54, minHeight: 44)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
    }
}

struct ToolButton: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void
    init(_ title: String, _ symbol: String, active: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) { ToolLabel(title, symbol, active: active) }
            .buttonStyle(.plain)
            .help(title)
    }
}

/// Undo/redo, printer and export in the window toolbar.
struct DocumentToolbar: ToolbarContent {
    @Bindable var session: DesignSession
    @Environment(\.undoManager) private var undoManager

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!(undoManager?.canUndo ?? false))
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!(undoManager?.canRedo ?? false))
            PrinterMenu(session: session)
            ExportMenu(session: session)
        }
    }
}
