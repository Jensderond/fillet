import SwiftUI

@main
struct FilletApp: App {
    init() {
        #if DEBUG && os(macOS)
        DebugAutomation.launch()
        #endif
    }

    var body: some Scene {
        DocumentGroup(newDocument: FilletDocument()) { file in
            EditorView(document: file.$document, fileURL: file.fileURL)
        }
        .commands { FilletCommands() }
    }
}
