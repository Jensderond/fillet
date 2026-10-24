import FilletCore
import FilletViewport
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var session: DesignSession?
    @Entry var viewport: ViewportController?
    /// True while a text field has focus, so bare-letter tool shortcuts stay out of its way.
    @Entry var isEditingText: Bool?
}

/// Menu bar commands (Mac) and hardware-keyboard shortcuts (iPad).
struct FilletCommands: Commands {
    @FocusedValue(\.session) private var session
    @FocusedValue(\.viewport) private var viewport
    @FocusedValue(\.isEditingText) private var isEditingText

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Zoom to Fit") { viewport?.fitAll() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(viewport == nil)
            Divider()
        }

        CommandMenu("Design") {
            // ⇧⌘S is File > Duplicate in document apps, so New Sketch is ⇧⌘K (sKetch).
            Button("New Sketch") { session?.startSketch() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Extrude") { session?.startExtrude() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Revolve") { session?.startRevolve() }
            Divider()
            Button("Fillet") { session?.startEdgeFeature(fillet: true) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Chamfer") { session?.startEdgeFeature(fillet: false) }
            Button("Shell") { session?.startShell() }
            Button("Combine") { session?.startCombine() }
            Button("Move") { session?.startMove() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Mirror") { session?.startMirror() }
            Button("Pattern") { session?.startPattern() }
            Divider()
            Button("Lay Flat on Face") { session?.startLayFlat() }
            Button(session?.showOverhangs == true ? "Hide Overhangs" : "Show Overhangs") { session?.showOverhangs.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Import STEP…") { session?.importRequested = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu("Sketch") {
            ForEach(SketchTool.allCases, id: \.self) { tool in
                Button(tool.title) { session?.sketchEditor?.engine.setTool(tool) }
                    .keyboardShortcut(bare(tool.shortcut))
            }
            Divider()
            Button("Toggle Construction") { session?.toggleConstructionOfSelection() }
                .keyboardShortcut(bare("x"))
            Button("Finish Sketch") { session?.finishSketch() }
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    /// A single-key shortcut, withdrawn while typing so it can never take a keystroke from a field.
    private func bare(_ key: KeyEquivalent) -> KeyboardShortcut? {
        isEditingText == true ? nil : KeyboardShortcut(key, modifiers: [])
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
