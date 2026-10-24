#if os(macOS)
import AppKit
import SwiftUI
import Testing
import FilletKernel
@testable import FilletViewport

@MainActor
@Suite("Hosting")
struct HostingTests {
    /// Hosts the SwiftUI view in a window, lets it lay out and draw, then picks
    /// through the controller to make sure the bridge is wired.
    @Test func viewportViewHostsAndPicks() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let controller = ViewportController()
        let scene = ViewportScene(bodies: [SceneBody(id: UUID(), mesh: DemoMeshes.cube(size: 20))])
        let box = CameraBox(Camera(target: .zero, distance: 120).viewing(.front))
        let view = ViewportView(scene: scene, camera: box.binding, delegate: recorder, controller: controller)
        let host = NSHostingView(rootView: view.frame(width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func find(_ v: NSView) -> ViewportNSView? {
            if let m = v as? ViewportNSView { return m }
            for s in v.subviews { if let m = find(s) { return m } }
            return nil
        }
        let mtk = try #require(find(host))
        #expect(mtk.controller === controller)
        #expect(controller.viewSize.width > 0)
        controller.tap(at: CGPoint(x: controller.viewSize.width / 2, y: controller.viewSize.height / 2), pointer: .mouse, modifiers: [])
        #expect(recorder.taps.count == 1)
        if case .face = recorder.taps.first ?? nil {} else { Issue.record("expected a face tap") }
        window.close()
    }
}
#endif
