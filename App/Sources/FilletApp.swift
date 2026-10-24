import SwiftUI

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

#if DEBUG && os(iOS)
/// Debug iPad builds can launch straight into an editor for the automation (no document browser).
@main
enum FilletLauncher {
    @MainActor static func main() {
        if DebugAutomation.isEnabled || DemoDirector.isEnabled { AutomationApp.main() } else { FilletApp.main() }
    }
}
#else
@main
extension FilletApp {}
#endif
