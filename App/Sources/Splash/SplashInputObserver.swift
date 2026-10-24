import SwiftUI

extension View {
    /// Calls `action` on any tap, click, scroll or key press in the app, without
    /// consuming it: the event still reaches whatever it was meant for. Lets the
    /// splash skip on the first input while the editor under it handles that
    /// same input.
    func onAnyInput(perform action: @escaping () -> Void) -> some View {
        modifier(AnyInputObserver(action: action))
    }
}

#if os(macOS)
import AppKit

private struct AnyInputObserver: ViewModifier {
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .magnify]
                monitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
                    action()
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#else
import UIKit
import UIKit.UIGestureRecognizerSubclass

private struct AnyInputObserver: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(WindowInputObserver(action: action))
    }
}

/// Puts a passive recognizer on the hosting window for as long as it's in the hierarchy.
private struct WindowInputObserver: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView(action: action) }
    func updateUIView(_ view: ObserverView, context: Context) { view.recognizer.onInput = action }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        let recognizer = PassiveInputRecognizer()

        init(action: @escaping () -> Void) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            recognizer.onInput = action
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(recognizer)
        }

        func detach() { recognizer.view?.removeGestureRecognizer(recognizer) }
    }
}

/// Notices touches (finger, Pencil, pointer clicks) and hardware key presses,
/// then fails at once: it never recognizes, never delays or cancels touches,
/// and never blocks another recognizer.
private final class PassiveInputRecognizer: UIGestureRecognizer {
    var onInput: () -> Void = {}

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput()
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
