#if os(iOS)
import SwiftUI
import UIKit

/// Plays the launch splash once per launch, over whatever the first scene
/// opens on: the document browser, or a design the system reopens. Opening or
/// creating a design later never plays it; by then the app is long loaded.
///
/// The splash gets a window of its own, above the app's, so nothing the scene
/// presents while it launches can cover it. That window takes no touches: they
/// fall through to the app underneath, which is live the whole time, and the
/// first tap, click or scroll fades the sheet out.
@MainActor
enum SplashPresenter {
    private static var observer: (any NSObjectProtocol)?
    private static var window: UIWindow?

    /// Call once at launch, before the first scene connects.
    static func playOnFirstScene() {
        observer = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { if let scene { play(in: scene) } }
        }
    }

    private static func play(in scene: UIWindowScene) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil

        let state = SplashState()
        let window = PassthroughWindow(windowScene: scene)
        window.onInput = { state.isSkipped = true }
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: SplashHost(state: state) {
            Self.window?.isHidden = true
            Self.window = nil
        })
        host.view.backgroundColor = .clear
        window.rootViewController = host
        // Visible but never key: the app's own window keeps the keyboard focus.
        window.isHidden = false
        self.window = window
    }
}

@MainActor @Observable
private final class SplashState {
    var isSkipped = false
}

private struct SplashHost: View {
    let state: SplashState
    let onFinish: () -> Void

    var body: some View {
        SplashOverlay(isSkipped: state.isSkipped, onFinish: onFinish)
    }
}

/// Notices touches (finger, Pencil, pointer clicks) and trackpad scrolls, and
/// lets every one through to the windows below.
private final class PassthroughWindow: UIWindow {
    var onInput: () -> Void = {}

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let type = event?.type, type == .touches || type == .scroll { onInput() }
        return nil
    }
}
#endif
