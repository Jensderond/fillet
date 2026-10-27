import SwiftUI

struct FilletApp: App {
    #if os(iOS)
    /// The launch screen's Acknowledgements action shows the sheet from its overlay: the scene draws
    /// its actions itself, so a sheet on the button would never be presented.
    @State private var showingAcknowledgements = false
    #endif

    init() {
        _ = AgentHub.shared  // listens for agents from launch when allowed
        #if DEBUG && os(macOS)
        DebugAutomation.launch()
        #endif
        #if os(iOS)
        SplashPresenter.playOnFirstScene()
        #else
        Updater.shared.start()
        #endif
    }

    var body: some Scene {
        DocumentGroup(newDocument: FilletDocument()) { file in
            EditorView(document: file.$document, fileURL: file.fileURL)
        }
        .commands { FilletCommands() }

        #if os(macOS)
        Window("Software Update", id: UpdateWindow.id) {
            UpdateWindow().windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView().frame(minWidth: 560, minHeight: 400)
        }
        .defaultSize(width: 680, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        #endif

        #if os(iOS)
        DocumentGroupLaunchScene("Fillet") {
            NewDocumentButton("New Design")
            Button("Acknowledgements") { showingAcknowledgements = true }
        } background: {
            Theme.paper.ignoresSafeArea()
        } backgroundAccessoryView: { geometry in
            DocumentLaunchSheet(layer: .paper, geometry: geometry)
        } overlayAccessoryView: { geometry in
            DocumentLaunchSheet(layer: .block, geometry: geometry)
                .sheet(isPresented: $showingAcknowledgements) { AcknowledgementsSheet() }
        }
        #endif
    }
}

#if DEBUG && os(iOS)
/// Debug iPad builds can launch straight into an editor for the automation (no document browser).
@main
enum FilletLauncher {
    @MainActor static func main() {
        if DebugAutomation.isEnabled || DemoDirector.isEnabled || DebugAutomation.opensBlankEditor {
            _ = AgentHub.shared  // FilletApp's init starts it otherwise
            AutomationApp.main()
        } else {
            FilletApp.main()
        }
    }
}
#else
@main
extension FilletApp {}
#endif
