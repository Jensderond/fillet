#if os(iOS) || os(visionOS)
import MetalKit
import UIKit

/// MTKView with the iPad gesture set:
/// - one finger: orbit (or tool with `fingerDraws`), handles take precedence
/// - two fingers: pan; pinch: zoom towards the pinch centre; two-finger double tap: fit all
/// - tap: pick
/// - Apple Pencil: tool input when the delegate wants it, otherwise tap / orbit
/// - trackpad: two-finger scroll pans, pinch zooms, pointer hover highlights
final class ViewportUIView: MTKView, UIGestureRecognizerDelegate {
    weak var controller: ViewportController?

    private enum OneFingerMode { case orbit, tool, handle }
    private var oneFingerMode: OneFingerMode = .orbit
    private var lastPan: CGPoint = .zero
    private var lastTwoFingerPan: CGPoint = .zero
    private var lastPinchScale: CGFloat = 1

    // Pencil stroke state.
    private enum PencilMode { case pending, tool, handle, orbit }
    private var pencilTouch: UITouch?
    private var pencilMode: PencilMode = .pending
    private var pencilStart: CGPoint = .zero
    private var pencilLast: CGPoint = .zero

    init(controller: ViewportController) {
        self.controller = controller
        super.init(frame: .zero, device: controller.renderer?.device)
        isMultipleTouchEnabled = true
        controller.renderer?.configure(self)
        installGestures()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.viewSize = bounds.size
    }

    private var fingerTypes: [NSNumber] {
        [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }

    private func installGestures() {
        let oneFinger = UIPanGestureRecognizer(target: self, action: #selector(oneFingerPan(_:)))
        oneFinger.minimumNumberOfTouches = 1
        oneFinger.maximumNumberOfTouches = 1
        oneFinger.allowedTouchTypes = fingerTypes
        oneFinger.delegate = self
        addGestureRecognizer(oneFinger)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        // Trackpad / mouse scrolling: continuous = trackpad (pan), discrete = wheel (zoom).
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scrollPan.allowedScrollTypesMask = .continuous
        scrollPan.allowedTouchTypes = []
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)

        let scrollZoom = UIPanGestureRecognizer(target: self, action: #selector(scrollZoom(_:)))
        scrollZoom.allowedScrollTypesMask = .discrete
        scrollZoom.allowedTouchTypes = []
        scrollZoom.delegate = self
        addGestureRecognizer(scrollZoom)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.allowedTouchTypes = fingerTypes
        addGestureRecognizer(tap)

        let fit = UITapGestureRecognizer(target: self, action: #selector(fitAll(_:)))
        fit.numberOfTouchesRequired = 2
        fit.numberOfTapsRequired = 2
        fit.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(fit)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        addGestureRecognizer(hover)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two-finger pan and pinch run together.
        let navigation = { (r: UIGestureRecognizer) in r is UIPinchGestureRecognizer || ((r as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2) }
        return navigation(g) && navigation(other)
    }

    private func modifiers(_ g: UIGestureRecognizer) -> ViewportModifiers { Self.modifiers(g.modifierFlags) }

    static func modifiers(_ f: UIKeyModifierFlags) -> ViewportModifiers {
        var m: ViewportModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.alternate) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }

    // MARK: Gestures

    @objc private func oneFingerPan(_ g: UIPanGestureRecognizer) {
        guard let c = controller else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let start = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
            if c.beginHandleDrag(at: start, pointer: .touch) {
                oneFingerMode = .handle
                c.dragHandle(to: p)
            } else if c.options.fingerDraws && c.wantsToolInput {
                oneFingerMode = .tool
                c.toolBegan(at: start, pressure: nil, pointer: .touch, modifiers: modifiers(g))
                c.toolMoved(at: p, pressure: nil, pointer: .touch, modifiers: modifiers(g))
            } else {
                oneFingerMode = .orbit
                c.beginOrbit(at: start)
                c.orbit(by: CGSize(width: p.x - start.x, height: p.y - start.y))
            }
            lastPan = p
        case .changed:
            switch oneFingerMode {
            case .handle: c.dragHandle(to: p)
            case .tool: c.toolMoved(at: p, pressure: nil, pointer: .touch, modifiers: modifiers(g))
            case .orbit: c.orbit(by: CGSize(width: p.x - lastPan.x, height: p.y - lastPan.y))
            }
            lastPan = p
        case .ended:
            switch oneFingerMode {
            case .handle: c.endHandleDrag()
            case .tool: c.toolEnded(at: p, pressure: nil, pointer: .touch, modifiers: modifiers(g))
            case .orbit: c.endNavigation()
            }
        case .cancelled, .failed:
            switch oneFingerMode {
            case .handle: c.endHandleDrag()
            case .tool: c.toolCancelled()
            case .orbit: c.endNavigation()
            }
        default: break
        }
    }

    @objc private func twoFingerPan(_ g: UIPanGestureRecognizer) {
        guard let c = controller else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            c.beginPan(at: p)
            lastTwoFingerPan = p
        case .changed:
            c.pan(by: CGSize(width: p.x - lastTwoFingerPan.x, height: p.y - lastTwoFingerPan.y))
            lastTwoFingerPan = p
        case .ended, .cancelled, .failed:
            c.endNavigation()
        default: break
        }
    }

    @objc private func scrollPan(_ g: UIPanGestureRecognizer) {
        guard let c = controller else { return }
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            c.beginPan(at: g.location(in: self))
            g.setTranslation(.zero, in: self)
        case .changed:
            c.pan(by: CGSize(width: t.x, height: t.y))
            g.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            c.endNavigation()
        default: break
        }
    }

    @objc private func scrollZoom(_ g: UIPanGestureRecognizer) {
        guard let c = controller else { return }
        let t = g.translation(in: self)
        let p = g.location(in: self)
        switch g.state {
        case .began:
            c.beginZoom(at: p)
            g.setTranslation(.zero, in: self)
        case .changed:
            c.zoom(factor: exp(-Double(t.y) * 0.004), at: p)
            g.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            c.endNavigation()
        default: break
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let c = controller else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            c.beginZoom(at: p)
            lastPinchScale = g.scale
        case .changed:
            guard g.scale > 0, lastPinchScale > 0 else { return }
            c.zoom(factor: Double(lastPinchScale / g.scale), at: p)
            lastPinchScale = g.scale
        case .ended, .cancelled, .failed:
            c.endNavigation()
        default: break
        }
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard let c = controller, g.state == .ended else { return }
        c.tap(at: g.location(in: self), pointer: .touch, modifiers: modifiers(g))
    }

    @objc private func fitAll(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        controller?.fitAll()
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        guard let c = controller else { return }
        switch g.state {
        case .began, .changed:
            c.hover(at: g.location(in: self), pointer: .mouse, modifiers: modifiers(g))
        default:
            c.hover(at: nil, pointer: .mouse)
        }
    }

    // MARK: Apple Pencil (raw touches; gesture recognizers ignore pencil touches)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard pencilTouch == nil, let t = touches.first(where: { $0.type == .pencil }), let c = controller else { return }
        pencilTouch = t
        let p = t.location(in: self)
        pencilStart = p
        pencilLast = p
        let mods = Self.modifiers(event?.modifierFlags ?? [])
        if c.beginHandleDrag(at: p, pointer: .pencil) {
            pencilMode = .handle
        } else if c.wantsToolInput {
            pencilMode = .tool
            c.toolBegan(at: p, pressure: pressure(t), pointer: .pencil, modifiers: mods)
        } else {
            pencilMode = .pending
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let t = pencilTouch, touches.contains(t), let c = controller else { return }
        let mods = Self.modifiers(event?.modifierFlags ?? [])
        switch pencilMode {
        case .handle:
            c.dragHandle(to: t.location(in: self))
        case .tool:
            let samples = event?.coalescedTouches(for: t) ?? [t]
            for s in samples { c.toolMoved(at: s.location(in: self), pressure: pressure(s), pointer: .pencil, modifiers: mods) }
        case .pending:
            let p = t.location(in: self)
            if hypot(p.x - pencilStart.x, p.y - pencilStart.y) > 6 {
                pencilMode = .orbit
                c.beginOrbit(at: pencilStart)
                c.orbit(by: CGSize(width: p.x - pencilStart.x, height: p.y - pencilStart.y))
                pencilLast = p
            }
        case .orbit:
            let p = t.location(in: self)
            c.orbit(by: CGSize(width: p.x - pencilLast.x, height: p.y - pencilLast.y))
            pencilLast = p
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let t = pencilTouch, touches.contains(t), let c = controller else { return }
        let p = t.location(in: self)
        let mods = Self.modifiers(event?.modifierFlags ?? [])
        switch pencilMode {
        case .handle: c.endHandleDrag()
        case .tool: c.toolEnded(at: p, pressure: pressure(t), pointer: .pencil, modifiers: mods)
        case .pending: c.tap(at: p, pointer: .pencil, modifiers: mods)
        case .orbit: c.endNavigation()
        }
        pencilTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let t = pencilTouch, touches.contains(t), let c = controller else { return }
        switch pencilMode {
        case .handle: c.endHandleDrag()
        case .tool: c.toolCancelled()
        case .orbit: c.endNavigation()
        case .pending: break
        }
        pencilTouch = nil
    }

    private func pressure(_ t: UITouch) -> Double? {
        t.maximumPossibleForce > 0 ? Double(t.force / t.maximumPossibleForce) : nil
    }
}
#endif
