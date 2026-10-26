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
            AgentHub.shared.register(s)
            #if DEBUG
            SplashFrameExporter.exportIfRequested()
            #endif
        }
        .onDisappear { if let session { AgentHub.shared.unregister(session) } }
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

/// Sizes itself to the space it's offered, never to its content, and offers its content that
/// space. Content wider than its room overflows (and is clipped or folded) instead of widening
/// everything around it, so widths read from this view are the room there is, not what the
/// content asked for. Where nothing is offered (ideal-size queries) it takes the content's size.
struct OfferedSpace: Layout {
    /// Takes the content's height, for a bar that's as tall as itself but only as wide as its room.
    var fitsContentHeight = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(fitsContentHeight ? .unspecified : proposal) ?? .zero
        return CGSize(width: proposal.width ?? content.width,
                      height: fitsContentHeight ? content.height : proposal.height ?? content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offer = fitsContentHeight ? ProposedViewSize.unspecified : ProposedViewSize(bounds.size)
        for subview in subviews { subview.place(at: bounds.origin, proposal: offer) }
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
    /// The window's width, from a container that content can't widen (see `OfferedSpace`).
    @State private var width: CGFloat = 1400
    @State private var showUpdating = false
    /// An agent is designing in this window (or just was).
    @State private var agentWorking = false
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @AppStorage("fingerDraws") private var fingerDraws = false
    /// How bodies are drawn; one choice for every window, like Fusion's display settings.
    @AppStorage(VisualStyle.defaultsKey) private var visualStyle = VisualStyle.shadedWithEdges
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.touchTargets) private var touch
    @Environment(\.dynamicTypeSize) private var typeSize

    private var layout: EditorLayout { EditorLayout(width: width) }

    /// At regular width the inspector always shows, so the viewport (and the model in it)
    /// doesn't jump 320 pt as the selection changes, and the empty document gets its starter.
    private var showInspector: Bool {
        layout == .regular || session.editing != nil || session.sketchEditor != nil || !session.selection.isEmpty
            || !session.model.bodies.isEmpty
    }

    /// The browser floats over the viewport below regular width, and at accessibility text
    /// sizes, where two fixed columns would leave the viewport too little room.
    private var browserFloats: Bool { layout != .regular || typeSize.isAccessibilitySize }
    private var browserVisible: Binding<Bool> { browserFloats ? $browserOverlay : $showBrowser }
    /// The inspector widens for accessibility text sizes so rows don't wrap word by word.
    private var inspectorWidth: CGFloat { typeSize.isAccessibilitySize ? 380 : 320 }

    /// One Finish sketch at a time: on the floating bar where the inspector is a wide column,
    /// pinned in the inspector footer (next to the form) on narrower layouts. Decided by the
    /// window's width, so the bar's own contents can't move it.
    private var finishInBar: Bool { layout == .regular }

    /// What floating chrome covers of the viewport, so the camera frames content in the rest.
    private var chromeInsets: ChromeInsets {
        ChromeInsets(sketchTop: touch ? 136 : 116, hintTop: touch ? 76 : 64,
                     leading: browserFloats && browserOverlay ? 252 : 0)
    }

    /// Room the floating bars leave for the view cube column (84 pt cube, 12 pt margin, a gap).
    static let cubeClearance: CGFloat = 96

    var body: some View {
        // The editor is exactly as wide as its window: no panel or floating bar can widen it, and
        // the layout (and with it where Finish goes) follows the window, not the content.
        OfferedSpace {
            editor
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A floating browser gives way to the inspector rather than covering the viewport twice.
        .onChange(of: showInspector) { _, shown in if shown, browserFloats { browserOverlay = false } }
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
        #if os(iOS)
        .task {
            DemoDirector.controller = controller
            await DemoDirector.run(session)
        }
        #endif
        #endif
        // The agent pill stays up a moment after each step, so a run of steps reads as one stretch of work.
        .task(id: AgentHub.shared.lastActivity) {
            agentWorking = AgentHub.shared.isWorking(on: session)
            try? await Task.sleep(for: .seconds(2.6))
            agentWorking = AgentHub.shared.isWorking(on: session)
        }
        #if os(macOS)
        .onChange(of: controlActiveState, initial: true) { _, state in if state == .key { AgentHub.shared.activated(session) } }
        #else
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { AgentHub.shared.activated(session) } }
        #endif
        // Only show "Updating" when a recompute takes long enough to notice.
        .task(id: session.isRecomputing) {
            guard session.isRecomputing else { showUpdating = false; return }
            try? await Task.sleep(for: .milliseconds(180))
            if session.isRecomputing { showUpdating = true }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ToolStrip(session: session, showBrowser: browserVisible)
                .dynamicTypeSize(...Theme.TypeLimit.chrome)
                .automationFrame("tool-strip")
            HStack(spacing: 0) {
                if !browserFloats, showBrowser {
                    BrowserView(session: session)
                        .frame(width: 252)
                        .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .leading, reduceMotion: reduceMotion))
                }
                VStack(spacing: 0) {
                    viewport
                        .automationFrame("viewport")
                        .overlay(alignment: .leading) {
                            if browserFloats, browserOverlay {
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
                    InspectorView(session: session, showsSketchFooter: !finishInBar)
                        .frame(width: inspectorWidth)
                        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
                        .transition(.panel(from: .trailing, reduceMotion: reduceMotion))
                }
            }
            .animation(Theme.Motion.enter, value: showInspector)
            .animation(Theme.Motion.enter, value: showBrowser)
            .animation(Theme.Motion.enter, value: browserOverlay)
            .animation(Theme.Motion.enter, value: layout)
            TimelineView(session: session)
                .dynamicTypeSize(...Theme.TypeLimit.chrome)
                .automationFrame("timeline")
        }
        .automationFrame("editor-content")
    }

    private var viewport: some View {
        ZStack(alignment: .top) {
            ViewportView(
                scene: session.makeScene(),
                camera: $session.camera,
                filter: session.pickFilter,
                // Reduce Motion: camera moves (sketch entry, view cube, fit) cut instead of flying.
                options: ViewportOptions(fingerDraws: fingerDraws, animatesCameraChanges: !reduceMotion,
                                         cameraAnimationDuration: cameraAnimationDuration,
                                         contentInsets: session.viewInsets, accessibilitySummary: session.viewportSummary),
                visualStyle: $visualStyle,
                delegate: session,
                controller: controller)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { session.viewportGeometryChanged(size: proxy.size, chrome: chromeInsets) }
                        .onChange(of: proxy.size) { _, size in session.viewportGeometryChanged(size: size, chrome: chromeInsets) }
                        .onChange(of: chromeInsets) { _, chrome in session.viewportGeometryChanged(size: proxy.size, chrome: chrome) }
                })
                .ignoresSafeArea(.container, edges: .bottom)

            VStack(spacing: Theme.Space.m) {
                if session.sketchEditor != nil {
                    // Lead-aligned, away from the view cube in the trailing corner (84 pt + margins).
                    SketchToolbar(session: session, fingerDraws: $fingerDraws, showsFinish: finishInBar)
                        .dynamicTypeSize(...Theme.TypeLimit.chrome)
                        .padding(.trailing, Self.cubeClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                if session.pickMode == .sketchPlane {
                    SketchPlaneBar(session: session)
                        .dynamicTypeSize(...Theme.TypeLimit.chrome)
                        .padding(.trailing, Self.cubeClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                if agentWorking {
                    AgentPill(agent: AgentHub.shared.agentName, activity: AgentHub.shared.activity)
                        .dynamicTypeSize(...Theme.TypeLimit.chrome)
                        .padding(.trailing, Self.cubeClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                if let hint = currentHint {
                    // Crossfades when the kind of hint changes (sketch, picking, getting started);
                    // within one, the text swaps instantly: it changes with every click.
                    HintPill(text: hint.text, symbol: hint.symbol)
                        .dynamicTypeSize(...Theme.TypeLimit.chrome)
                        .blurCrossfade(hint.context)
                        .padding(.trailing, Self.cubeClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if session.document.activeFeatureCount < session.document.features.count {
                    // Rolled back, the viewport shows an earlier state: say so where the eye is.
                    RollbackPill(shown: session.document.activeFeatureCount, total: session.document.features.count) {
                        session.moveRollbackMarker(to: nil)
                    }
                    .dynamicTypeSize(...Theme.TypeLimit.chrome)
                    .padding(.trailing, Self.cubeClearance)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.panel(from: .top, reduceMotion: reduceMotion))
                }
                Spacer(minLength: 0)
                if let message = session.message {
                    Toast(message: message, run: run) {
                        if session.message == message { session.message = nil }
                    }
                    .transition(.panel(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            .padding(Theme.Space.l)
            .animation(Theme.Motion.enter, value: session.sketchEditor != nil)
            .animation(Theme.Motion.enter, value: session.choosingSketchPlane)
            .animation(Theme.Motion.enter, value: session.document.activeFeatureCount < session.document.features.count)
            .animation(Theme.Motion.enter, value: session.message)
            .animation(Theme.Motion.enter, value: agentWorking)

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
        // A tick when the pointer snaps to a point or lines up (not for every grid step).
        .sensoryFeedback(.alignment, trigger: snapFeedback) { _, new in new != nil }
    }

    /// Camera flights; the debug demo slows them down for recordings.
    private var cameraAnimationDuration: Double {
        #if DEBUG && os(iOS)
        DemoDirector.isEnabled ? DemoDirector.cameraDuration : 0.35
        #else
        0.35
        #endif
    }

    private var snapFeedback: SketchSnap? {
        switch session.sketchEditor?.engine.snap {
        case .point, .horizontal, .vertical: session.sketchEditor?.engine.snap
        default: nil
        }
    }

    /// Toast actions; finger drawing is the editor's setting, the rest are the session's.
    private func run(_ action: ToastMessage.Action) {
        guard action == .drawWithFinger else { return session.run(action) }
        fingerDraws = true
        // One finger now draws, so say how to get around.
        session.message = "Finger drawing is on. Drag with two fingers to pan, pinch to zoom."
    }

    /// The tool's hint; on Mac, with a shape in progress, how to type its sizes instead.
    private func sketchHint(_ editor: SketchEditor, verb: String) -> String {
        let hint = editor.engine.hint(verb: verb)
        #if os(macOS)
        let fields = editor.engine.dimensionFields()
        if let typing = editor.typing, fields.indices.contains(typing.field) {
            let next = fields.count > 1 ? ", Tab for \(fields[(typing.field + 1) % fields.count].title.lowercased())" : ""
            return "Type the \(fields[typing.field].title.lowercased())\(next), Return to place"
        }
        if !fields.isEmpty { return "\(hint), or Tab to type the size" }
        #endif
        return hint
    }

    private var currentHint: (text: String, symbol: String, context: String)? {
        let pick = Theme.Copy.pick
        if let editor = session.sketchEditor {
            // Tools are icon-only and touch has no tooltips, so the hint names the live tool.
            let title = editor.tool.title  // menu titles are Title Case; app copy is sentence case
            let name = title.prefix(1) + title.dropFirst().lowercased()
            return ("\(name) · \(sketchHint(editor, verb: pick))", editor.tool == .select ? "cursorarrow" : "pencil.tip", "sketch")
        }
        switch session.pickMode {
        case .sketchPlane: return nil  // the plane bar says what to pick
        case .regions: return ("\(pick) the profiles to use", "hand.tap", "pick")
        case .edges: return ("\(pick) edges to add or remove them", "hand.tap", "pick")
        case .faces:
            if session.editingKind == "pressPull" { return ("\(pick) faces to move, or again to drop them", "hand.tap", "pick") }
            return ("\(pick) faces to remove them", "hand.tap", "pick")
        case .singleFace: return ("\(pick) the face that should touch the bed", "hand.tap", "pick")
        case .bodies: return ("\(pick) bodies to add or remove them", "hand.tap", "pick")
        default: break
        }
        // Without the always-visible inspector (narrow layouts), the empty document still needs a first step.
        if layout != .regular, session.document.features.isEmpty, session.editing == nil {
            return ("Start with Sketch to draw a profile on the bed", "pencil.and.outline", "start")
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

/// The viewport is showing an earlier step: "Showing step 2 of 5", with the way back to the end.
/// Section hatching on the leading edge echoes the hatched steps on the timeline.
struct RollbackPill: View {
    let shown: Int
    let total: Int
    let playToEnd: () -> Void
    @Environment(\.touchTargets) private var touch
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Label("Showing step \(shown) of \(total)", systemImage: "clock.arrow.circlepath")
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.ink)
            Theme.hairlineStrong.frame(width: 1, height: 16)
            Button(action: playToEnd) {
                Label("Play to end", systemImage: "forward.end.fill")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.filletInk)
                    .frame(minHeight: touch ? 44 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .hoverHighlight()
            .help("Roll forward to the last step")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, touch ? 0 : Theme.Space.xs)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().strokeBorder(Theme.inkTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }
}

/// Status in ink, errors in red with a warning glyph; announced to VoiceOver when it appears.
/// Info dismisses itself, pausing while the pointer is over it; errors wait to be dismissed.
struct Toast: View {
    let message: ToastMessage
    var run: (ToastMessage.Action) -> Void = { _ in }
    let dismiss: () -> Void
    @State private var hovering = false
    @Environment(\.touchTargets) private var touch
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(message.kind == .error ? Theme.dangerInk : Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(message.text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            if let action = message.action {
                Button(action.title) { run(action) }
                    .buttonStyle(InlineButtonStyle())
                    .frame(minHeight: touch ? 44 : 28)
                    .padding(.leading, Theme.Space.xs)
                    .hoverHighlight()
                    .automationMarker("toast-show")
            }
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
        .frame(maxWidth: 520)
        .onAppear { AccessibilityNotification.Announcement(message.text).post() }
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard message.dismissesItself, !hovering else { return }
            try? await Task.sleep(for: .seconds(message.duration))
            if !Task.isCancelled { dismiss() }
        }
    }
}

// MARK: - Tool strip

/// Main tools, grouped into clusters by job: sketch, create, modify, print.
/// (Fit lives under the view cube and in the View menu, ⌘0.)
struct ToolStrip: View {
    @Bindable var session: DesignSession
    @Binding var showBrowser: Bool

    /// While a step is open, the other tools wait for Done or Cancel.
    private var busyReason: String? {
        guard session.isBusyEditing, let name = session.editingFeature?.name else { return nil }
        return "Finish \(name) first: Done or Cancel."
    }

    /// The long-press menu: straight to a plane without picking it in the viewport.
    @ViewBuilder private func sketchPlanes(busy: Bool, face: Bool) -> some View {
        Group {
            if face { Button("On selected face") { session.startSketch() } }
            Button("On XY (bed)") { session.startSketch(on: .xy) }
            Button("On XZ (front)") { session.startSketch(on: .xz) }
            Button("On YZ (side)") { session.startSketch(on: .yz) }
        }
        .disabled(busy)
    }

    private func sketchLabel(busy: Bool) -> some View {
        ToolLabel("Sketch", "pencil.and.outline", active: session.sketchEditor != nil || session.choosingSketchPlane, disabled: busy)
            .automationFrame("tool.Sketch")
    }

    var body: some View {
        let busy = session.isBusyEditing
        HStack(spacing: Theme.Space.s) {
            ToolButton("Browser", "sidebar.left", active: showBrowser, toggle: true) { showBrowser.toggle() }
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.s) {
                    ToolCluster {
                        // Menus aren't `.disabled` as a whole (the system dims their labels a second
                        // time); their items are, and the label draws the same disabled colour as buttons.
                        // With a planar face selected, a tap sketches on it; otherwise the viewport
                        // offers the origin planes and flat faces to pick. A long press lists the planes.
                        let onFace = session.sketchableFace != nil
                        Menu { sketchPlanes(busy: busy, face: onFace) } label: { sketchLabel(busy: busy) } primaryAction: {
                            if !busy { session.startSketch() }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .hoverHighlight(ownsPointerHover: true)
                        .help(onFace ? "New sketch on the selected face [⇧⌘K]" : "New sketch: pick a plane or a flat face [⇧⌘K]")
                    }
                    ToolCluster {
                        ToolButton("Extrude", "square.stack.3d.up", active: session.editingKind == "extrude",
                                   unavailable: session.unavailableReason(.extrude), shortcut: "E") { session.startExtrude() }
                        ToolButton("Revolve", "arrow.triangle.2.circlepath", active: session.editingKind == "revolve",
                                   unavailable: session.unavailableReason(.revolve)) { session.startRevolve() }
                        Menu {
                            ForEach(PrimitiveKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue.capitalized) { session.startPrimitive(kind) }
                                    .disabled(busy)
                            }
                        } label: {
                            ToolLabel("Primitive", "cube", active: session.editingKind == "primitive", disabled: busy)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .hoverHighlight(ownsPointerHover: true)
                        .help(busyReason ?? "Box, cylinder, sphere, cone or torus")
                        ToolButton("Import", "square.and.arrow.down", unavailable: busyReason) { session.importRequested = true }
                    }
                    ToolCluster {
                        ToolButton("Press Pull", "arrow.up.and.down.square", active: session.editingKind == "pressPull",
                                   unavailable: session.unavailableReason(.pressPull)) { session.startPressPull() }
                        ToolButton("Fillet", "rectangle.roundedtop", active: session.editingKind == "fillet",
                                   unavailable: session.unavailableReason(.fillet), shortcut: "F") { session.startEdgeFeature(fillet: true) }
                        ToolButton("Chamfer", "skew", active: session.editingKind == "chamfer",
                                   unavailable: session.unavailableReason(.chamfer)) { session.startEdgeFeature(fillet: false) }
                        ToolButton("Shell", "cube.transparent", active: session.editingKind == "shell",
                                   unavailable: session.unavailableReason(.shell)) { session.startShell() }
                        ToolButton("Hole", "smallcircle.filled.circle", active: session.editingKind == "hole",
                                   unavailable: session.unavailableReason(.hole)) { session.startHole() }
                        ToolButton("Combine", "square.on.square", active: session.editingKind == "combine",
                                   unavailable: session.unavailableReason(.combine)) { session.startCombine() }
                        ToolButton("Move", "move.3d", active: session.editingKind == "move",
                                   unavailable: session.unavailableReason(.move), shortcut: "⇧⌘M") { session.startMove() }
                        ToolButton("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", active: session.editingKind == "mirror",
                                   unavailable: session.unavailableReason(.mirror)) { session.startMirror() }
                        ToolButton("Pattern", "square.grid.3x1.below.line.grid.1x2", active: session.editingKind == "pattern",
                                   unavailable: session.unavailableReason(.pattern)) { session.startPattern() }
                    }
                    ToolCluster {
                        ToolButton("Lay flat", "arrow.down.to.line", active: session.editingKind == "layFlat",
                                   unavailable: session.unavailableReason(.layFlat)) { session.startLayFlat() }
                        ToolButton("Overhangs", "angle", active: session.showOverhangs, toggle: true,
                                   unavailable: session.showOverhangs ? nil : session.unavailableReason(.overhangs)) { session.showOverhangs.toggle() }
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
    /// Full tertiary ink (3.85:1): clearly off, without turning the strip into ghost text.
    private var dimmedInk: Color { Theme.inkTertiary }

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
                Capsule().fill(Theme.filletMark).frame(width: 18, height: 2.5).offset(y: -1)
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
    var unavailable: Bool
    func makeBody(configuration: Configuration) -> some View {
        ToolLabel(title, symbol, active: active, pressed: configuration.isPressed, isToggle: isToggle, disabled: unavailable)
    }
}

/// A tool-strip button. When the tool can't run it looks unavailable and, instead of acting,
/// explains why: as the tooltip on the Mac, as a VoiceOver hint, and in a small popover on a tap.
struct ToolButton: View {
    let title: String
    let symbol: String
    var active = false
    var isToggle = false
    var unavailable: String?
    /// Its key, shown in the tooltip: "Extrude [E]".
    var shortcut: String?
    let action: () -> Void
    @State private var explaining = false

    init(_ title: String, _ symbol: String, active: Bool = false, toggle: Bool = false, unavailable: String? = nil,
         shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.isToggle = toggle
        self.unavailable = unavailable; self.shortcut = shortcut; self.action = action
    }

    private var named: String { shortcut.map { "\(title) [\($0)]" } ?? title }

    var body: some View {
        Button(title) {
            if unavailable != nil { explaining = true } else { action() }
        }
        .buttonStyle(ToolButtonStyle(title: title, symbol: symbol, active: active, isToggle: isToggle, unavailable: unavailable != nil))
        .automationFrame("tool.\(title)")
        .help(unavailable.map { "\(named). \($0)" } ?? named)
        .accessibilityValue(unavailable == nil ? "" : "Unavailable")
        .accessibilityHint(unavailable ?? "")
        .hoverHighlight(ownsPointerHover: true)
        .popover(isPresented: $explaining, arrowEdge: .bottom) {
            ToolReason(title: title, reason: unavailable ?? "")
        }
    }
}

/// Why a tool is unavailable: a short note under the tool, gone after a few seconds.
private struct ToolReason: View {
    let title: String
    let reason: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(reason).font(Theme.body).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(width: 240, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        .task {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}

// MARK: - Sketch toolbar

extension SketchTool {
    /// Glyph on the sketch bar and in the "More shapes" menu.
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .line: "line.diagonal"
        case .arc: "circle.bottomhalf.filled"
        case .spline: "scribble"
        case .point: "smallcircle.filled.circle"
        case .rectangle: "rectangle"
        case .centerRectangle: "plus.rectangle"
        case .circle: "circle"
        case .polygon: "hexagon"
        case .slot: "capsule"
        }
    }
}

/// Drawing tools floating at the top-leading corner of the viewport in sketch mode, grouped
/// select | lines and curves | shapes. When the full bar doesn't fit (iPad portrait, landscape
/// with both panels, Split View, large text) the secondary tools fold into a "More shapes"
/// menu, so a glyph is never cut off and the bar never widens the viewport.
struct SketchToolbar: View {
    @Bindable var session: DesignSession
    @Binding var fingerDraws: Bool
    /// Finish sits here only when the inspector shows no footer (wide layouts): one primary at a time.
    var showsFinish: Bool
    @Environment(\.touchTargets) private var touch
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Every tool, in its group.
    static let fullGroups: [[SketchTool]] = [[.select], [.line, .arc, .spline, .point], [.rectangle, .centerRectangle, .circle, .polygon, .slot]]
    /// Fewer tools at each step; the rest fold into the menu. Lines and curves go last, then the
    /// everyday shapes.
    static let roomyGroups: [[SketchTool]] = [[.select], [.line, .arc, .spline, .point], [.rectangle, .circle]]
    static let compactGroups: [[SketchTool]] = [[.select], [.line, .arc], [.rectangle, .circle]]
    static let minimalGroups: [[SketchTool]] = [[.select], [.line], [.rectangle]]

    static let variants = [fullGroups, roomyGroups, compactGroups, minimalGroups]

    private var toolSize: CGSize { touch ? CGSize(width: 44, height: 44) : CGSize(width: 38, height: 34) }
    private var activeTool: SketchTool? { session.sketchEditor?.tool }

    /// Width the bar may use, and the ideal width of each variant (measured, not guessed, so
    /// Dynamic Type and the Done button are accounted for). Not `ViewThatFits`: on iPadOS 26 it
    /// sizes its children on SwiftUI's async renderer, off the main actor these views live on.
    /// `available` comes from a background spacer, not the bar, so it is the room the viewport
    /// offers whatever the bar's size.
    @State private var available: CGFloat = 0
    @State private var idealWidths: [CGFloat] = Array(repeating: 0, count: variants.count)

    private var variant: Int {
        guard available > 0 else { return 0 }
        return Self.variants.indices.first { idealWidths[$0] > 0 && idealWidths[$0] <= available } ?? Self.variants.count - 1
    }

    var body: some View {
        // As wide as offered and as tall as the bar: a bar wider than its room can't push back.
        OfferedSpace(fitsContentHeight: true) {
            bar(Self.variants[variant], measuring: false)
        }
        .background {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Self.variants.indices, id: \.self) { measured($0) }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func measured(_ i: Int) -> some View {
        bar(Self.variants[i], measuring: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { idealWidths[i] = $0 }
    }

    private func bar(_ groups: [[SketchTool]], measuring: Bool) -> some View {
        let shown = Set(groups.joined())
        let more = SketchTool.allCases.filter { !shown.contains($0) }
        return HStack(spacing: Theme.Space.s) {
            HStack(spacing: 2) {
                ForEach(groups.indices, id: \.self) { i in
                    if i > 0 { Theme.hairline.frame(width: 1, height: 24).padding(.horizontal, Theme.Space.xs) }
                    ForEach(groups[i], id: \.self) { tool in
                        toolButton(tool).automationFrame(measuring ? nil : "sketch-tool.\(tool.rawValue)")
                    }
                }
                if !more.isEmpty { moreMenu(more, measuring: measuring) }
            }
            if activeTool == .spline || activeTool == .line {
                Button("Done") {
                    let shapes = session.sketchEditor?.engine.finish() ?? []
                    session.addSketchShapes(shapes)
                }
                .buttonStyle(SecondaryButtonStyle())
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
            if showsFinish {
                Button {
                    session.finishSketch()
                } label: {
                    Label("Finish sketch", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                .automationFrame(measuring ? nil : "finish-sketch-button")
                .help("Finish the sketch [⌘↩]")
                .automationMarker(measuring ? "finish-sketch-measure" : "finish-sketch")
            }
        }
        .fixedSize()
        .padding(Theme.Space.s)
        .floatingElevation(cornerRadius: Theme.Radius.control + Theme.Space.s)
    }

    private func toolButton(_ tool: SketchTool) -> some View {
        let active = activeTool == tool
        return Button {
            // Tool switches are frequent (and keyboard-driven too): no animation.
            session.sketchEditor?.engine.setTool(tool)
        } label: {
            toolGlyph(tool.symbol, active: active)
        }
        .buttonStyle(PressableStyle())
        .help("\(tool.title) [\(String(tool.shortcut.character).uppercased())]")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .hoverHighlight()
    }

    private func toolGlyph(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(active ? Theme.filletInk : Theme.ink)
            .frame(width: toolSize.width, height: toolSize.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(active ? Theme.filletSoft : .clear))
            .contentShape(Rectangle())
    }

    /// The folded tools. Shows the active one when it's in here, so the bar still says which tool is live.
    private func moreMenu(_ tools: [SketchTool], measuring: Bool) -> some View {
        let current = activeTool.flatMap { tools.contains($0) ? $0 : nil }
        return Menu {
            ForEach(tools, id: \.self) { tool in
                Button {
                    session.sketchEditor?.engine.setTool(tool)
                } label: {
                    Label(tool.title, systemImage: tool.symbol)
                }
            }
        } label: {
            toolGlyph(current?.symbol ?? "ellipsis", active: current != nil)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(touch ? 6 : 4)
                }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("More shapes")
        .accessibilityLabel("More shapes")
        .accessibilityValue(current?.title ?? "")
        .automationFrame(measuring ? nil : "sketch-more")
        .background {
            if !measuring { ForEach(tools, id: \.self) { Color.clear.automationMarker("sketch-folded.\($0.rawValue)") } }
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
            // The session tracks the undo manager's notifications; reading `canUndo` from the
            // manager here wouldn't re-render when it changes.
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .help(session.canUndo ? "Undo \(undoManager?.undoActionName ?? "")" : "Nothing to undo")
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .help(session.canRedo ? "Redo \(undoManager?.redoActionName ?? "")" : "Nothing to redo")
            PrinterMenu(session: session)
            ExportMenu(session: session)
            AgentToolbarButton()
        }
    }
}
