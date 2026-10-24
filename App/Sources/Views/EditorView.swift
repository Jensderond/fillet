import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// One document window: owns the session and keeps it in sync with the file.
struct EditorView: View {
    @Binding var document: FilletDocument
    let fileURL: URL?

    @State private var session: DesignSession?
    @State private var showSplash = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let session {
                EditorContent(session: session, fileURL: fileURL)
            } else {
                Theme.chrome
            }
        }
        .overlay { if showSplash { SplashOverlay { showSplash = false } } }
        .onAppear {
            let s = DesignSession(document: document.model)
            s.undoManager = undoManager
            s.onDocumentChange = { [$document] model in $document.wrappedValue.model = model }
            if document.model.name == nil, let name = fileURL?.deletingPathExtension().lastPathComponent {
                s.documentName = name
            }
            session = s
            showSplash = SplashGate.claim()
        }
        .onChange(of: document.model) { _, model in session?.externalUpdate(model) }
        .onChange(of: undoManager) { _, manager in session?.undoManager = manager }
    }
}

/// How the editor arranges its panels for the width it has.
enum EditorLayout: Equatable {
    /// 1100 pt and up: browser and inspector are columns; the inspector always shows.
    case regular
    /// 760–1100 pt: the browser floats over the viewport; the inspector is a column when needed.
    case medium
    /// Under 760 pt: the browser floats; the inspector docks under the viewport.
    case compact

    init(width: CGFloat) {
        self = width >= 1100 ? .regular : width >= 760 ? .medium : .compact
    }
}

struct EditorContent: View {
    @Bindable var session: DesignSession
    let fileURL: URL?

    @State private var controller = ViewportController()
    /// The user's browser preference at regular width. Narrower widths override it
    /// with `browserOverlay` and never write to it.
    @State private var showBrowser = true
    @State private var browserOverlay = false
    @State private var width: CGFloat = 1400
    @State private var viewportWidth: CGFloat = 800
    @State private var showUpdating = false
    @AppStorage("fingerDraws") private var fingerDraws = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: EditorLayout { EditorLayout(width: width) }

    /// At regular width the inspector always shows, so the viewport (and the model in it)
    /// doesn't jump 320 pt as the selection changes, and the empty document gets its starter.
    private var showInspector: Bool {
        layout == .regular || session.editing != nil || session.sketchEditor != nil || !session.selection.isEmpty
            || !session.model.bodies.isEmpty
    }

    private var browserVisible: Binding<Bool> { layout == .regular ? $showBrowser : $browserOverlay }

    var body: some View {
        VStack(spacing: 0) {
            ToolStrip(session: session, showBrowser: browserVisible)
            HStack(spacing: 0) {
                if layout == .regular, showBrowser {
                    BrowserView(session: session)
                        .frame(width: 252)
                        .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .leading, reduceMotion: reduceMotion))
                }
                VStack(spacing: 0) {
                    viewport
                        .overlay(alignment: .leading) {
                            if layout != .regular, browserOverlay {
                                BrowserView(session: session)
                                    .frame(width: 252)
                                    .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
                                    .shadow(color: .black.opacity(0.16), radius: 16, x: 4)
                                    .transition(.panel(from: .leading, reduceMotion: reduceMotion))
                            }
                        }
                    if layout == .compact, showInspector {
                        InspectorDrawer(session: session)
                            .transition(.panel(from: .bottom, reduceMotion: reduceMotion))
                    }
                }
                if layout != .compact, showInspector {
                    InspectorView(session: session)
                        .frame(width: 320)
                        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .trailing, reduceMotion: reduceMotion))
                }
            }
            .animation(Theme.Motion.enter, value: showInspector)
            .animation(Theme.Motion.enter, value: showBrowser)
            .animation(Theme.Motion.enter, value: browserOverlay)
            .animation(Theme.Motion.enter, value: layout)
            TimelineView(session: session)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A floating browser gives way to the inspector rather than covering the viewport twice.
        .onChange(of: showInspector) { _, shown in if shown, layout != .regular { browserOverlay = false } }
        .background(Theme.chrome)
        .tint(Theme.fillet)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
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
        .onExitCommand { session.escape() }
        #endif
        .focusedSceneValue(\.session, session)
        .focusedSceneValue(\.viewport, controller)
        .fileImporter(isPresented: $session.importRequested, allowedContentTypes: [.step]) { result in
            if case .success(let url) = result { session.importSTEP(from: url) }
        }
        #if DEBUG
        .task {
            DebugAutomation.controller = controller
            await DebugAutomation.run(session)
        }
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

            VStack(spacing: Theme.Space.m) {
                if session.sketchEditor != nil {
                    // Centred, and kept clear of the view cube (84 pt + margins) on both sides.
                    SketchToolbar(session: session, fingerDraws: $fingerDraws)
                        .frame(maxWidth: max(viewportWidth - 2 * 112, 300))
                        .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                if let hint = currentHint {
                    HintPill(text: hint.text, symbol: hint.symbol)
                        .blurCrossfade(hint.text)
                }
                Spacer(minLength: 0)
                if let message = session.message {
                    Toast(message: message) { session.message = nil }
                        .transition(.panel(from: .bottom, reduceMotion: reduceMotion))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(message.duration))
                            if session.message == message { session.message = nil }
                        }
                }
            }
            .padding(Theme.Space.l)
            .animation(Theme.Motion.enter, value: session.sketchEditor != nil)
            .animation(Theme.Motion.enter, value: session.message)

            if showUpdating {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.mini)
                    Text("Updating")
                }
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
                .background(Capsule().fill(Theme.raised))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity.animation(Theme.Motion.exit))
            }
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    private var currentHint: (text: String, symbol: String)? {
        if let editor = session.sketchEditor {
            return (editor.engine.hint, editor.tool == .select ? "cursorarrow" : "pencil.tip")
        }
        let pick = Theme.Copy.pick
        switch session.pickMode {
        case .regions: return ("\(pick) the profiles to use", "hand.tap")
        case .edges: return ("\(pick) edges to add or remove them", "hand.tap")
        case .faces: return ("\(pick) faces to remove them", "hand.tap")
        case .singleFace: return ("\(pick) the face that should touch the bed", "hand.tap")
        case .bodies: return ("\(pick) bodies to add or remove them", "hand.tap")
        default: break
        }
        // Without the always-visible inspector (narrow layouts), the empty document still needs a first step.
        if layout != .regular, session.document.features.isEmpty, session.editing == nil {
            return ("Start with Sketch to draw a profile on the bed", "pencil.and.outline")
        }
        return nil
    }
}

// MARK: - Viewport overlays

/// What the viewport is waiting for, in ink on a solid pill so it reads over any geometry.
struct HintPill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Theme.body.weight(.medium))
            .foregroundStyle(Theme.raised)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(Theme.ink.opacity(0.88)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Status in ink, errors in red with a warning glyph; announced to VoiceOver when it appears.
struct Toast: View {
    let message: ToastMessage
    let dismiss: () -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(message.kind == .error ? Theme.dangerInk : Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(message.text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: touch ? 44 : 22, height: touch ? 44 : 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Space.l).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.s)
        .floatingElevation()
        .frame(maxWidth: 460)
        .onAppear { AccessibilityNotification.Announcement(message.text).post() }
    }
}

// MARK: - Tool strip

/// Main tools, grouped into clusters by job: sketch, create, modify, print.
/// (Fit lives under the view cube and in the View menu, ⌘0.)
struct ToolStrip: View {
    @Bindable var session: DesignSession
    @Binding var showBrowser: Bool

    var body: some View {
        let busy = session.isBusyEditing
        HStack(spacing: Theme.Space.s) {
            ToolButton("Browser", "sidebar.left", active: showBrowser, toggle: true) { showBrowser.toggle() }
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.s) {
                    ToolCluster {
                        // Menus aren't `.disabled` as a whole (the system dims their labels a second
                        // time); their items are, and the label draws the same disabled colour as buttons.
                        Menu {
                            Group {
                                Button("On XY (bed)") { session.startSketch(on: .xy) }
                                Button("On XZ (front)") { session.startSketch(on: .xz) }
                                Button("On YZ (side)") { session.startSketch(on: .yz) }
                            }
                            .disabled(busy)
                        } label: {
                            ToolLabel("Sketch", "pencil.and.outline", active: session.sketchEditor != nil, disabled: busy)
                        } primaryAction: {
                            if !busy { session.startSketch() }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .hoverHighlight()
                        .help("New sketch on the selected face, or on the bed (⇧⌘K)")
                    }
                    ToolCluster {
                        Group {
                            ToolButton("Extrude", "square.stack.3d.up", active: session.editingKind == "extrude") { session.startExtrude() }
                            ToolButton("Revolve", "arrow.triangle.2.circlepath", active: session.editingKind == "revolve") { session.startRevolve() }
                        }
                        .disabled(busy)
                        Menu {
                            ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue.capitalized) { session.startPrimitive(kind) }
                                    .disabled(busy)
                            }
                        } label: {
                            ToolLabel("Primitive", "cube", active: session.editingKind == "primitive", disabled: busy)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .hoverHighlight()
                        ToolButton("Import", "square.and.arrow.down") { session.importRequested = true }
                            .disabled(busy)
                    }
                    ToolCluster {
                        Group {
                            ToolButton("Fillet", "rectangle.roundedtop", active: session.editingKind == "fillet") { session.startEdgeFeature(fillet: true) }
                            ToolButton("Chamfer", "skew", active: session.editingKind == "chamfer") { session.startEdgeFeature(fillet: false) }
                            ToolButton("Shell", "cube.transparent", active: session.editingKind == "shell") { session.startShell() }
                            ToolButton("Combine", "square.on.square", active: session.editingKind == "combine") { session.startCombine() }
                            ToolButton("Move", "move.3d", active: session.editingKind == "move") { session.startMove() }
                            ToolButton("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", active: session.editingKind == "mirror") { session.startMirror() }
                            ToolButton("Pattern", "square.grid.3x1.below.line.grid.1x2", active: session.editingKind == "pattern") { session.startPattern() }
                        }
                        .disabled(busy)
                    }
                    ToolCluster {
                        Group {
                            ToolButton("Lay flat", "arrow.down.to.line", active: session.editingKind == "layFlat") { session.startLayFlat() }
                            ToolButton("Overhangs", "angle", active: session.showOverhangs, toggle: true) { session.showOverhangs.toggle() }
                        }
                        .disabled(busy)
                    }
                }
                .padding(.vertical, 1)
            }
            .overflowFade()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
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
            .padding(Theme.Space.xs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control + Theme.Space.xs, style: .continuous).fill(Theme.raised.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + Theme.Space.xs, style: .continuous).strokeBorder(Theme.hairline))
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
    /// Disabled without `.disabled` (menu labels, see `ToolStrip`).
    var disabled = false

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, _ symbol: String, active: Bool = false, pressed: Bool = false, isToggle: Bool = false, disabled: Bool = false) {
        self.title = title; self.symbol = symbol; self.active = active; self.pressed = pressed; self.isToggle = isToggle
        self.disabled = disabled
    }

    private var accent: Color { isToggle ? Theme.ink : Theme.filletInk }
    private var activeFill: Color { isToggle ? Theme.hairlineStrong : Theme.filletSoft }
    /// Disabled is shown with colour, not opacity, so it can't stack with the system Menu
    /// dimming, and the active tool keeps its accent ("you are here") while others are off.
    private var dimmed: Bool { (!isEnabled || disabled) && !active }
    private var dimmedInk: Color { Theme.inkTertiary.opacity(0.6) }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(height: 20)
                .foregroundStyle(dimmed ? dimmedInk : active ? accent : Theme.ink)
            Text(title)
                .font(active ? Theme.label.weight(.semibold) : Theme.label)
                .foregroundStyle(dimmed ? dimmedInk : active ? Theme.ink : Theme.inkSecondary)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .scaleEffect(pressed ? 0.97 : 1)
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

/// Drawing tools floating at the top of the viewport in sketch mode. When the full bar
/// doesn't fit (iPad portrait, Split View) the tools scroll and Finish stays in view.
struct SketchToolbar: View {
    @Bindable var session: DesignSession
    @Binding var fingerDraws: Bool
    @Environment(\.touchTargets) private var touch

    private let tools: [(SketchTool, String)] = [
        (.select, "cursorarrow"), (.line, "line.diagonal"), (.rectangle, "rectangle"),
        (.centerRectangle, "plus.rectangle"), (.circle, "circle"),
        (.arc, "circle.bottomhalf.filled"),
        (.polygon, "hexagon"), (.slot, "capsule"), (.spline, "scribble"), (.point, "smallcircle.filled.circle"),
    ]

    private var toolSize: CGSize { touch ? CGSize(width: 44, height: 44) : CGSize(width: 38, height: 34) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(scrolling: false).fixedSize()
            bar(scrolling: true)
        }
    }

    private func bar(scrolling: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if scrolling {
                ScrollView(.horizontal) { toolButtons }
                    .overflowFade()
            } else {
                toolButtons
            }
            if session.sketchEditor?.tool == .spline || session.sketchEditor?.tool == .line {
                Button("Done") {
                    let shapes = session.sketchEditor?.engine.finish() ?? []
                    session.addSketchShapes(shapes)
                }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
                .help("End the line chain or spline")
            }
            #if os(iOS)
            // A mode toggle, so "on" is ink on a grey plate like the other view toggles, not orange.
            Button { fingerDraws.toggle() } label: {
                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: toolSize.width, height: toolSize.height)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(fingerDraws ? Theme.hairlineStrong : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .hoverHighlight()
            .help("Draw with finger instead of Apple Pencil")
            .accessibilityLabel("Draw with finger")
            .accessibilityAddTraits(fingerDraws ? .isSelected : [])
            #endif
            Button {
                session.finishSketch()
            } label: {
                Label("Finish sketch", systemImage: "checkmark").fixedSize()
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize()
        }
        .padding(Theme.Space.s)
        .floatingElevation(cornerRadius: Theme.Radius.control + Theme.Space.s)
    }

    private var toolButtons: some View {
        HStack(spacing: 2) {
            ForEach(tools, id: \.0) { tool, symbol in
                let active = session.sketchEditor?.tool == tool
                Button {
                    // Tool switches are frequent (and keyboard-driven too): no animation.
                    session.sketchEditor?.engine.setTool(tool)
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(active ? Theme.filletInk : Theme.ink)
                        .frame(width: toolSize.width, height: toolSize.height)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(active ? Theme.filletSoft : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("\(tool.title) (\(String(tool.shortcut.character).uppercased()))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(active ? .isSelected : [])
                .hoverHighlight()
                if tool == .select { Theme.hairline.frame(width: 1, height: 24).padding(.horizontal, Theme.Space.xs) }
            }
        }
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
