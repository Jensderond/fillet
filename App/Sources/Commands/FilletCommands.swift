import FilletCore
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var session: DesignSession?
}

/// Menu bar commands (Mac) and hardware-keyboard shortcuts (iPad).
struct FilletCommands: Commands {
    @FocusedValue(\.session) private var session

    var body: some Commands {
        CommandMenu("Design") {
            Button("New Sketch") { session?.startSketch() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
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
                    .keyboardShortcut(tool.shortcut, modifiers: [])
            }
            Divider()
            Button("Toggle Construction") { session?.toggleConstructionOfSelection() }
                .keyboardShortcut("x", modifiers: [])
            Button("Finish Sketch") { session?.finishSketch() }
                .keyboardShortcut(.return, modifiers: [.command])
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
