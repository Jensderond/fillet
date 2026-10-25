#if os(macOS)
import AppKit
import MetalKit

/// MTKView with Mac mouse/trackpad handling:
/// - left click: pick; left drag with a tool: tool; left drag on an element the delegate lets
///   you drag (`viewportShouldBeginDrag`): drag it; left drag otherwise: orbit
/// - right drag or option-left drag: orbit; middle drag or shift-right drag: pan
/// - scroll wheel: zoom at the cursor; trackpad two-finger scroll: pan
///   (⌘/⌥ + scroll zooms); pinch: zoom; rotate: spin around Z
/// - mouse moved: hover highlighting
final class ViewportNSView: MTKView {
    weak var controller: ViewportController?

    private enum DragMode { case none, pendingClick, orbit, pan, tool, handle, target }
    private var mode: DragMode = .none
    private var downPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var scrolling = false
    private var tracking: NSTrackingArea?

    init(controller: ViewportController) {
        self.controller = controller
        super.init(frame: .zero, device: controller.renderer?.device)
        controller.renderer?.configure(self)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        controller?.viewSize = bounds.size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.viewSize = newSize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// Event location in top-left-origin view points.
    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func modifiers(_ e: NSEvent) -> ViewportModifiers {
        var m: ViewportModifiers = []
        let f = e.modifierFlags
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }

    private func delta(_ p: CGPoint) -> CGSize {
        defer { lastPoint = p }
        return CGSize(width: p.x - lastPoint.x, height: p.y - lastPoint.y)
    }

    // MARK: Left button

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        window?.makeFirstResponder(self)
        let p = point(e)
        downPoint = p
        lastPoint = p
        if e.modifierFlags.contains(.option) {
            mode = .orbit
            c.beginOrbit(at: p)
        } else if c.beginHandleDrag(at: p, pointer: .mouse) {
            mode = .handle
        } else if c.wantsToolInput {
            mode = .tool
            c.toolBegan(at: p, pressure: nil, pointer: .mouse, modifiers: modifiers(e))
        } else {
            mode = .pendingClick
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        switch mode {
        case .pendingClick:
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 {
                if c.beginTargetDrag(at: downPoint, pointer: .mouse, modifiers: modifiers(e)) {
                    mode = .target
                    c.dragTarget(to: p, pointer: .mouse, modifiers: modifiers(e))
                } else {
                    mode = .orbit
                    c.beginOrbit(at: downPoint)
                    lastPoint = downPoint
                    c.orbit(by: delta(p))
                }
            }
        case .orbit: c.orbit(by: delta(p))
        case .pan: c.pan(by: delta(p))
        case .tool: c.toolMoved(at: p, pressure: nil, pointer: .mouse, modifiers: modifiers(e))
        case .handle: c.dragHandle(to: p)
        case .target: c.dragTarget(to: p, pointer: .mouse, modifiers: modifiers(e))
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        finishDrag(e)
    }

    private func finishDrag(_ e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        switch mode {
        case .pendingClick: c.tap(at: p, pointer: .mouse, modifiers: modifiers(e))
        case .orbit, .pan: c.endNavigation()
        case .tool: c.toolEnded(at: p, pressure: nil, pointer: .mouse, modifiers: modifiers(e))
        case .handle: c.endHandleDrag()
        case .target: c.endTargetDrag(at: p, pointer: .mouse, modifiers: modifiers(e))
        case .none: break
        }
        mode = .none
        c.hover(at: p, pointer: .mouse, modifiers: modifiers(e))
    }

    // MARK: Right / middle buttons

    override func rightMouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        downPoint = p
        lastPoint = p
        if e.modifierFlags.contains(.shift) {
            mode = .pan
            c.beginPan(at: p)
        } else {
            mode = .orbit
            c.beginOrbit(at: p)
        }
    }

    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func rightMouseUp(with e: NSEvent) { finishDrag(e) }

    override func otherMouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        downPoint = p
        lastPoint = p
        mode = .pan
        c.beginPan(at: p)
    }

    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { finishDrag(e) }

    // MARK: Hover

    override func mouseMoved(with e: NSEvent) {
        controller?.hover(at: point(e), pointer: .mouse, modifiers: modifiers(e))
    }

    override func mouseExited(with e: NSEvent) {
        controller?.hover(at: nil, pointer: .mouse)
    }

    // MARK: Scroll / trackpad gestures

    override func scrollWheel(with e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        let zoomModifier = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        if e.hasPreciseScrollingDeltas && !zoomModifier {
            // Trackpad: pan with the fingers.
            if !scrolling { c.beginPan(at: p); scrolling = true }
            c.pan(by: CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
        } else {
            if !scrolling { c.beginZoom(at: p); scrolling = true }
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            c.zoom(factor: exp(-Double(dy)), at: p)
        }
        let ended = e.phase == .ended || e.phase == .cancelled || e.momentumPhase == .ended
        let discrete = e.phase.isEmpty && e.momentumPhase.isEmpty
        if ended || discrete {
            scrolling = false
            c.endNavigation()
        }
    }

    override func magnify(with e: NSEvent) {
        guard let c = controller else { return }
        let p = point(e)
        if e.phase == .began { c.beginZoom(at: p) }
        c.zoom(factor: 1 / max(1 + Double(e.magnification), 0.05), at: p)
        if e.phase == .ended || e.phase == .cancelled { c.endNavigation() }
    }

    override func rotate(with e: NSEvent) {
        guard let c = controller else { return }
        if e.phase == .began { c.beginOrbit(at: point(e)) }
        c.orbit(by: CGSize(width: -Double(e.rotation) / 0.3, height: 0))
        if e.phase == .ended || e.phase == .cancelled { c.endNavigation() }
    }

    override func smartMagnify(with e: NSEvent) {
        controller?.fitAll()
    }
}
#endif
