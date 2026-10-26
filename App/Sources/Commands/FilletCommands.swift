import FilletCore
import FilletViewport
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var session: DesignSession?
    @Entry var viewport: ViewportController?
    /// True while a text field has focus, so bare-letter tool shortcuts stay out of its way.
    /// (Sizes typed on the canvas while drawing withdraw them too: `DesignSession.isTypingDimension`.)
    @Entry var isEditingText: Bool?
}

/// Menu bar commands (Mac) and hardware-keyboard shortcuts (iPad).
struct FilletCommands: Commands {
    @FocusedValue(\.session) private var session
    @FocusedValue(\.viewport) private var viewport
    @FocusedValue(\.isEditingText) private var isEditingText
    @AppStorage(VisualStyle.defaultsKey) private var visualStyle = VisualStyle.shadedWithEdges

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Zoom to Fit") { viewport?.fitAll() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(viewport == nil)
            Picker("Visual Style", selection: $visualStyle) {
                ForEach(VisualStyle.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            Divider()
        }

        CommandMenu("Design") {
            // ⇧⌘S is File > Duplicate in document apps, so New Sketch is ⇧⌘K (sKetch).
            Button("New Sketch") { session?.startSketch() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            // Bare letters for the common tools, as in Fusion: E, F, and R, C… in the Sketch menu.
            Button("Extrude") { session?.startIfAvailable(.extrude) { session?.startExtrude() } }
                .keyboardShortcut(bare("e"))
            Button("Revolve") { session?.startIfAvailable(.revolve) { session?.startRevolve() } }
            Divider()
            Button("Press Pull") { session?.startIfAvailable(.pressPull) { session?.startPressPull() } }
                .keyboardShortcut(bare("q"))
            Button("Fillet") { session?.startIfAvailable(.fillet) { session?.startEdgeFeature(fillet: true) } }
                .keyboardShortcut(bare("f"))
            Button("Chamfer") { session?.startIfAvailable(.chamfer) { session?.startEdgeFeature(fillet: false) } }
            Button("Shell") { session?.startIfAvailable(.shell) { session?.startShell() } }
            Button("Hole") { session?.startIfAvailable(.hole) { session?.startHole() } }
                .keyboardShortcut(bare("h"))
            Button("Combine") { session?.startIfAvailable(.combine) { session?.startCombine() } }
            Button("Move") { session?.startIfAvailable(.move) { session?.startMove() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Mirror") { session?.startIfAvailable(.mirror) { session?.startMirror() } }
            Button("Pattern") { session?.startIfAvailable(.pattern) { session?.startPattern() } }
            Divider()
            Button("Lay Flat on Face") { session?.startIfAvailable(.layFlat) { session?.startLayFlat() } }
            Button(session?.showOverhangs == true ? "Hide Overhangs" : "Show Overhangs") { session?.showOverhangs.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Measure") { session?.startMeasure() }
            Divider()
            Button("Import STEP…") { session?.importRequested = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Toggle("Allow Agent Connections", isOn: Bindable(AgentHub.shared).isEnabled)
            Button("Copy Agent Setup Command") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AgentHub.shared.claudeCodeCommand, forType: .string)
                #else
                UIPasteboard.general.string = AgentHub.shared.claudeCodeCommand
                #endif
            }
            .disabled(!AgentHub.shared.isEnabled)
        }

        CommandMenu("Sketch") {
            ForEach(SketchTool.allCases, id: \.self) { tool in
                // Outside sketch mode a drawing tool's key starts a sketch with that tool.
                Button(tool.title) { session?.startSketchTool(tool) }
                    .keyboardShortcut(bare(tool.shortcut))
            }
            Divider()
            Button("Toggle Construction") { session?.toggleConstructionOfSelection() }
                .keyboardShortcut(bare("x"))
            Button("Finish Sketch") { session?.finishSketch() }
                .keyboardShortcut(.return, modifiers: [.command])
            #if os(iOS)
            // `onKeyPress` needs focus the editor never has on iPad; a key command always reaches it.
            // (Mac uses onExitCommand, which follows the responder chain.)
            Divider()
            Button("Cancel") { session?.escape() }
                .keyboardShortcut(.escape, modifiers: [])
            #endif
        }
    }

    /// A single-key shortcut, withdrawn while typing so it can never take a keystroke from a field.
    private func bare(_ key: KeyEquivalent) -> KeyboardShortcut? {
        isEditingText == true || session?.isTypingDimension == true ? nil : KeyboardShortcut(key, modifiers: [])
    }
}

extension VisualStyle {
    static let defaultsKey = "visualStyle"

    /// Title Case for the menu bar (the viewport's picker uses the sentence-case `title`).
    var menuTitle: String {
        switch self {
        case .shaded: "Shaded"
        case .shadedWithEdges: "Shaded with Edges"
        case .shadedWithHiddenEdges: "Shaded with Hidden Edges"
        case .xray: "X-Ray"
        case .wireframe: "Wireframe"
        case .hiddenLine: "Hidden Line"
        }
    }
}

extension SketchTool {
    var shortcut: KeyEquivalent {
        switch self {
        case .select: "v"
        case .line: "l"
        case .rectangle: "r"
        case .centerRectangle: "t"
        case .circle: "c"
        case .arc: "a"
        case .polygon: "p"
        case .slot: "o"
        case .spline: "b"
        case .point: "."
        }
    }
}
