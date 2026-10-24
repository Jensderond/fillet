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
                Theme.chrome
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
    @State private var showUpdating = false
    @AppStorage("fingerDraws") private var fingerDraws = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showInspector: Bool {
        session.editing != nil || session.sketchEditor != nil || !session.selection.isEmpty || !session.model.bodies.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolStrip(session: session, controller: controller, showBrowser: $showBrowser)
            HStack(spacing: 0) {
                if showBrowser {
                    BrowserView(session: session)
                        .frame(width: 252)
                        .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .leading, reduceMotion: reduceMotion))
                }
                viewport
                if showInspector {
                    InspectorView(session: session)
                        .frame(width: 320)
                        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .trailing, reduceMotion: reduceMotion))
                }
            }
            .animation(Theme.Motion.enter, value: showInspector)
            .animation(Theme.Motion.enter, value: showBrowser)
            TimelineView(session: session)
        }
        .background(Theme.chrome)
        .tint(Theme.fillet)
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
        .fileImporter(isPresented: $session.importRequested, allowedContentTypes: [.step]) { result in
            if case .success(let url) = result { session.importSTEP(from: url) }
        }
        #if DEBUG && os(macOS)
        .task { await DebugAutomation.run(session) }
        #endif
        // Only show "Updating" when a recompute takes long enough to notice.
        .task(id: session.isRecomputing) {
            guard session.isRecomputing else { showUpdating = false; return }
            try? await Task.sleep(for: .milliseconds(180))
            if session.isRecomputing { showUpdating = true }
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

            VStack(spacing: 10) {
                if session.sketchEditor != nil {
                    SketchToolbar(session: session, fingerDraws: $fingerDraws)
                        .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                if let hint = currentHint {
                    HintPill(text: hint.text, symbol: hint.symbol)
                        .blurCrossfade(hint.text)
                }
                Spacer(minLength: 0)
                if let message = session.message {
                    Toast(text: message) { session.message = nil }
                        .transition(.panel(from: .bottom, reduceMotion: reduceMotion))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(4))
                            if session.message == message { session.message = nil }
                        }
                }
            }
            .padding(14)
            .animation(Theme.Motion.enter, value: session.sketchEditor != nil)
            .animation(Theme.Motion.enter, value: session.message)

            if showUpdating {
                Label("Updating", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity.animation(Theme.Motion.exit))
            }
        }
        .clipped()
    }

    private var currentHint: (text: String, symbol: String)? {
        if let editor = session.sketchEditor {
            return (editor.engine.hint, editor.tool == .select ? "cursorarrow" : "pencil.tip")
        }
        switch session.pickMode {
        case .regions: return ("Tap the profiles to use", "hand.tap")
        case .edges: return ("Tap edges to add or remove them", "hand.tap")
        case .faces: return ("Tap faces to remove them", "hand.tap")
        case .singleFace: return ("Tap the face that should touch the bed", "hand.tap")
        case .bodies: return ("Tap bodies to add or remove them", "hand.tap")
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

// MARK: - Viewport overlays

/// What the viewport is waiting for, in ink on a solid pill so it reads over any geometry.
struct HintPill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.raised)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.ink.opacity(0.88)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct Toast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.fillet)
            Text(text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .frame(maxWidth: 460)
    }
}

// MARK: - Tool strip

/// Main tools, grouped into clusters by job: sketch, create, modify, print.
struct ToolStrip: View {
    @Bindable var session: DesignSession
    let controller: ViewportController
    @Binding var showBrowser: Bool

    var body: some View {
        HStack(spacing: 10) {
            ToolButton("Browser", "sidebar.left", active: showBrowser, toggle: true) { showBrowser.toggle() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ToolCluster {
                        Menu {
                            Button("On XY (bed)") { session.startSketch(on: .xy) }
                            Button("On XZ (front)") { session.startSketch(on: .xz) }
                            Button("On YZ (side)") { session.startSketch(on: .yz) }
                        } label: {
                            ToolLabel("Sketch", "pencil.and.outline", active: session.sketchEditor != nil)
                        } primaryAction: {
                            session.startSketch()
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .help("New sketch on the selected face, or on the bed")
                    }
                    ToolCluster {
                        ToolButton("Extrude", "square.stack.3d.up", active: session.editingKind == "extrude") { session.startExtrude() }
                        ToolButton("Revolve", "arrow.triangle.2.circlepath", active: session.editingKind == "revolve") { session.startRevolve() }
                        Menu {
                            ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue.capitalized) { session.startPrimitive(kind) }
                            }
                        } label: {
                            ToolLabel("Primitive", "cube", active: session.editingKind == "primitive")
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    ToolCluster {
                        ToolButton("Fillet", "rectangle.roundedtop", active: session.editingKind == "fillet") { session.startEdgeFeature(fillet: true) }
                        ToolButton("Chamfer", "skew", active: session.editingKind == "chamfer") { session.startEdgeFeature(fillet: false) }
                        ToolButton("Shell", "cube.transparent", active: session.editingKind == "shell") { session.startShell() }
                        ToolButton("Combine", "square.on.square", active: session.editingKind == "combine") { session.startCombine() }
                        ToolButton("Move", "move.3d", active: session.editingKind == "move") { session.startMove() }
                        ToolButton("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", active: session.editingKind == "mirror") { session.startMirror() }
                        ToolButton("Pattern", "square.grid.3x1.below.line.grid.1x2", active: session.editingKind == "pattern") { session.startPattern() }
                    }
                    ToolCluster {
                        ToolButton("Import", "square.and.arrow.down") { session.importRequested = true }
                        ToolButton("Lay Flat", "arrow.down.to.line", active: session.editingKind == "layFlat") { session.startLayFlat() }
                        ToolButton("Overhangs", "exclamationmark.triangle", active: session.showOverhangs, toggle: true) { session.showOverhangs.toggle() }
                    }
                }
                .padding(.vertical, 1)
            }
            .disabled(session.isBusyEditing)
            Spacer(minLength: 0)
            ToolButton("Fit", "arrow.up.left.and.arrow.down.right") { controller.fitAll() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

extension DesignSession {
    /// Feature buttons are disabled while a non-sketch feature is open (finish it first).
    var isBusyEditing: Bool { editing != nil && sketchEditor == nil }

    /// Type of the feature being edited, for highlighting its tool.
    var editingKind: String? { sketchEditor == nil ? editingFeature?.kind.typeName : nil }
}

/// A group of related tools on a faint raised plate.
struct ToolCluster<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 1) { content }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Icon over a condensed label, with hover, press and active states.
struct ToolLabel: View {
    let title: String
    let symbol: String
    var active = false
    var pressed = false
    /// View toggles (browser, overhangs) show "on" in ink; orange stays reserved for the tool in progress.
    var isToggle = false

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, _ symbol: String, active: Bool = false, pressed: Bool = false, isToggle: Bool = false) {
        self.title = title; self.symbol = symbol; self.active = active; self.pressed = pressed; self.isToggle = isToggle
    }

    private var accent: Color { isToggle ? Theme.ink : Theme.fillet }
    private var activeFill: Color { isToggle ? Theme.hairlineStrong : Theme.filletSoft }

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(height: 21)
                .foregroundStyle(active ? accent : Theme.ink)
            Text(title)
                .font(Theme.condensed(11, active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 54, minHeight: 44)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(active ? activeFill : hovering || pressed ? Theme.hairline : .clear))
        .overlay(alignment: .bottom) {
            if active, !isToggle {
                Capsule().fill(Theme.fillet).frame(width: 18, height: 2.5).offset(y: -1)
            }
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.press, value: pressed)
    }
}

struct ToolButtonStyle: ButtonStyle {
    var title: String
    var symbol: String
    var active: Bool
    var isToggle: Bool
    func makeBody(configuration: Configuration) -> some View {
        ToolLabel(title, symbol, active: active, pressed: configuration.isPressed, isToggle: isToggle)
    }
}

struct ToolButton: View {
    let title: String
    let symbol: String
    var active = false
    var isToggle = false
    let action: () -> Void
    init(_ title: String, _ symbol: String, active: Bool = false, toggle: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.isToggle = toggle; self.action = action
    }
    var body: some View {
        Button(title, action: action)
            .buttonStyle(ToolButtonStyle(title: title, symbol: symbol, active: active, isToggle: isToggle))
            .help(title)
            .hoverHighlight()
    }
}

// MARK: - Sketch toolbar

/// Drawing tools floating at the top of the viewport in sketch mode.
struct SketchToolbar: View {
    @Bindable var session: DesignSession
    @Binding var fingerDraws: Bool

    private let tools: [(SketchTool, String)] = [
        (.select, "cursorarrow"), (.line, "line.diagonal"), (.rectangle, "rectangle"),
        (.centerRectangle, "rectangle.center.inset.filled"), (.circle, "circle"),
        (.arc, "point.topleft.down.to.point.bottomright.curvepath"),
        (.polygon, "hexagon"), (.slot, "capsule"), (.spline, "scribble"), (.point, "smallcircle.filled.circle"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(tools, id: \.0) { tool, symbol in
                    let active = session.sketchEditor?.tool == tool
                    Button {
                        // Tool switches are frequent (and keyboard-driven too): no animation.
                        session.sketchEditor?.engine.setTool(tool)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(active ? Theme.fillet : Theme.ink)
                            .frame(width: 38, height: 34)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(active ? Theme.filletSoft : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("\(tool.title) (\(String(tool.shortcut.character).uppercased()))")
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .hoverHighlight()
                    if tool == .select { Theme.hairline.frame(width: 1, height: 22).padding(.horizontal, 3) }
                }
            }
            if session.sketchEditor?.tool == .spline || session.sketchEditor?.tool == .line {
                Button("Done") {
                    let shapes = session.sketchEditor?.engine.finish() ?? []
                    session.addSketchShapes(shapes)
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("End the line chain or spline")
            }
            #if os(iOS)
            Toggle(isOn: $fingerDraws) {
                Image(systemName: "hand.draw").frame(width: 30, height: 30)
            }
            .toggleStyle(.button)
            .tint(Theme.fillet)
            .help("Draw with finger instead of Apple Pencil")
            #endif
            Button {
                session.finishSketch()
            } label: {
                Label("Finish sketch", systemImage: "checkmark").fixedSize()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .fixedSize()
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// Plain look with the 0.97 press scale.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
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
