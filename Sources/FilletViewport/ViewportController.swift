import CoreGraphics
import Foundation
import Observation
import SwiftUI
import FilletKernel

/// Platform-independent interaction state behind `ViewportView`: owns the renderer and
/// picker, the live camera (which may run ahead of the SwiftUI binding during
/// gestures and animations) and translates input into camera moves, picks and
/// delegate callbacks.
@MainActor
@Observable
public final class ViewportController {
    /// The camera currently drawn (updates every frame while orbiting or animating).
    public private(set) var liveCamera: Camera = .default
    /// View size in points.
    public internal(set) var viewSize: CGSize = .zero

    @ObservationIgnored public let renderer: ViewportRenderer?
    @ObservationIgnored let picker = ViewportPicker()
    @ObservationIgnored private(set) var scene = ViewportScene()
    @ObservationIgnored var filter: PickFilter = .default
    @ObservationIgnored var options = ViewportOptions()
    @ObservationIgnored weak var delegate: (any ViewportDelegate)?
    @ObservationIgnored var cameraBinding: Binding<Camera>?
    @ObservationIgnored private var lastSyncedCamera: Camera?
    @ObservationIgnored private var lastHover: PickTarget?

    // Gesture state.
    @ObservationIgnored private var orbitPivot: Vec3?
    @ObservationIgnored private var zoomAnchor: Vec3?
    @ObservationIgnored private var panDepthPoint: Vec3?
    @ObservationIgnored private var dragHandle: (handle: Handle, offset: Double, value: Double)?

    public init() {
        renderer = try? ViewportRenderer()
        renderer?.onCameraAnimation = { [weak self] cam, finished in
            guard let self else { return }
            self.liveCamera = cam
            if finished { self.pushCamera() }
        }
    }

    // MARK: Sync from SwiftUI

    func update(scene: ViewportScene, camera: Camera, filter: PickFilter, options: ViewportOptions,
                delegate: (any ViewportDelegate)?, appearance: ViewportAppearance) {
        self.scene = scene
        self.filter = filter
        self.options = options
        self.delegate = delegate
        picker.prune(keeping: Set(scene.bodies.map(\.id)))
        renderer?.update(scene: scene)
        renderer?.palette = appearance.palette
        if lastSyncedCamera == nil {
            lastSyncedCamera = camera
            setLive(camera)
        } else if camera != lastSyncedCamera {
            lastSyncedCamera = camera
            if options.animatesCameraChanges, let r = renderer, !viewSize.width.isZero {
                r.camera = liveCamera
                r.animateCamera(to: camera, duration: options.cameraAnimationDuration)
                // Land the camera even if the view isn't drawing (occluded window).
                let deadline = options.cameraAnimationDuration + 0.05
                Task { @MainActor [weak r] in
                    try? await Task.sleep(for: .seconds(deadline))
                    r?.advanceAnimationWithoutDrawing()
                }
            } else {
                setLive(camera)
            }
        }
        redraw()
    }

    private func setLive(_ c: Camera) {
        liveCamera = c
        renderer?.camera = c
    }

    /// Writes the live camera back to the binding (end of a gesture / animation).
    func pushCamera() {
        lastSyncedCamera = liveCamera
        if let b = cameraBinding, b.wrappedValue != liveCamera { b.wrappedValue = liveCamera }
        delegate?.viewportCameraChanged(liveCamera)
    }

    func redraw() { renderer?.setNeedsDisplay() }

    private func moveCamera(_ change: (inout Camera) -> Void) {
        renderer?.cancelAnimation()
        var c = liveCamera
        change(&c)
        setLive(c)
        redraw()
    }

    // MARK: Picking helpers

    /// Picks under a view location with the current filter (handles always included).
    public func pick(at p: CGPoint, pointer: PointerKind, filter f: PickFilter? = nil) -> PickHit? {
        picker.pick(scene: scene, camera: liveCamera, at: p, viewSize: viewSize, filter: f ?? filter.union(.handles),
                    tolerance: pointer.tolerance)
    }

    func ray(at p: CGPoint) -> Ray { liveCamera.ray(at: p, viewSize: viewSize) }

    private func surfacePoint(at p: CGPoint) -> Vec3? {
        picker.raycast(ray(at: p), bodies: scene.bodies)?.point
    }

    // MARK: Navigation

    func beginOrbit(at p: CGPoint) {
        renderer?.cancelAnimation()
        orbitPivot = surfacePoint(at: p)
    }

    func orbit(by delta: CGSize) {
        moveCamera { $0.orbit(drag: delta, pivot: orbitPivot) }
    }

    func beginPan(at p: CGPoint) {
        renderer?.cancelAnimation()
        panDepthPoint = surfacePoint(at: p)
    }

    func pan(by delta: CGSize) {
        let size = viewSize
        moveCamera { $0.pan(translation: delta, viewSize: size, depthPoint: panDepthPoint) }
    }

    func beginZoom(at p: CGPoint) {
        renderer?.cancelAnimation()
        zoomAnchor = surfacePoint(at: p)
    }

    /// `factor` < 1 zooms in.
    func zoom(factor: Double, at p: CGPoint, anchorFromGesture: Bool = true) {
        let size = viewSize
        let anchor = anchorFromGesture ? zoomAnchor : surfacePoint(at: p)
        moveCamera { $0.zoom(factor: factor, at: p, viewSize: size, anchor: anchor) }
    }

    func endNavigation() {
        orbitPivot = nil
        zoomAnchor = nil
        panDepthPoint = nil
        pushCamera()
    }

    /// Frames all bodies (or the bed) with an animation.
    public func fitAll(animated: Bool = true) {
        guard let b = scene.fitBounds else { return }
        let aspect = viewSize.height > 0 ? Double(viewSize.width / viewSize.height) : 1
        animate(to: liveCamera.fitted(to: b, aspect: aspect), animated: animated)
    }

    /// Switches to a standard view, keeping target and distance.
    public func show(_ view: Camera.StandardView, animated: Bool = true) {
        animate(to: liveCamera.viewing(view), animated: animated)
    }

    /// Looks from a direction given by yaw/pitch (view cube corners).
    public func show(yaw: Double, pitch: Double, animated: Bool = true) {
        var c = liveCamera
        c.yaw = yaw
        c.pitch = pitch
        animate(to: c, animated: animated)
    }

    /// Toggles perspective / orthographic.
    public func toggleProjection() {
        var c = liveCamera
        c.projection = c.projection == .perspective ? .orthographic : .perspective
        setLive(c)
        pushCamera()
        redraw()
    }

    /// Animates the live camera and writes the result to the binding when done.
    public func animate(to camera: Camera, animated: Bool = true) {
        // `animatesCameraChanges` off (Reduce Motion) cuts straight to the new view.
        if animated, options.animatesCameraChanges, let r = renderer {
            r.camera = liveCamera
            r.animateCamera(to: camera, duration: options.cameraAnimationDuration)
        } else {
            setLive(camera)
            pushCamera()
            redraw()
        }
    }

    // MARK: Picking / hover

    func tap(at p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers) {
        let hit = pick(at: p, pointer: pointer, filter: filter)
        delegate?.viewportDidTap(target: hit?.target, hit: hit, ray: ray(at: p), location: p, modifiers: modifiers)
    }

    func hover(at p: CGPoint?, pointer: PointerKind, modifiers: ViewportModifiers = []) {
        var target: PickTarget?
        var hit: PickHit?
        if let p {
            hit = pick(at: p, pointer: pointer)
            target = hit?.target
            if delegate?.wantsToolInput == true {
                delegate?.viewportToolHover(toolEvent(at: p, pressure: nil, pointer: pointer, modifiers: modifiers, hit: hit))
            }
        }
        setHover(target)
    }

    private func setHover(_ target: PickTarget?) {
        guard target != lastHover else { return }
        lastHover = target
        renderer?.pointerHover = target
        delegate?.viewportHoverChanged(target: target)
        redraw()
    }

    // MARK: Tools

    var wantsToolInput: Bool { delegate?.wantsToolInput ?? false }

    func toolEvent(at p: CGPoint, pressure: Double?, pointer: PointerKind, modifiers: ViewportModifiers,
                   hit: PickHit?? = nil) -> ViewportToolEvent {
        let h = hit ?? pick(at: p, pointer: pointer, filter: filter)
        return ViewportToolEvent(ray: ray(at: p), location: p, pressure: pressure, modifiers: modifiers, pointer: pointer, hit: h)
    }

    func toolBegan(at p: CGPoint, pressure: Double?, pointer: PointerKind, modifiers: ViewportModifiers) {
        delegate?.viewportToolBegan(toolEvent(at: p, pressure: pressure, pointer: pointer, modifiers: modifiers))
    }

    func toolMoved(at p: CGPoint, pressure: Double?, pointer: PointerKind, modifiers: ViewportModifiers) {
        let e = toolEvent(at: p, pressure: pressure, pointer: pointer, modifiers: modifiers)
        setHover(e.hit?.target)
        delegate?.viewportToolMoved(e)
    }

    func toolEnded(at p: CGPoint, pressure: Double?, pointer: PointerKind, modifiers: ViewportModifiers) {
        delegate?.viewportToolEnded(toolEvent(at: p, pressure: pressure, pointer: pointer, modifiers: modifiers))
    }

    func toolCancelled() { delegate?.viewportToolCancelled() }

    // MARK: Handles

    /// Starts dragging the handle under `p`, if any. Returns whether a drag began.
    func beginHandleDrag(at p: CGPoint, pointer: PointerKind) -> Bool {
        guard filter.contains(.handles) || !scene.handles.isEmpty,
              let hit = picker.pickHandle(scene.handles, camera: liveCamera, location: SIMD2(Double(p.x), Double(p.y)),
                                          viewSize: viewSize, tolerance: max(pointer.tolerance, 12) + 4),
              case .handle(let id) = hit.target,
              let h = scene.handles.first(where: { $0.id == id }) else { return false }
        renderer?.cancelAnimation()
        let s = ViewportPicker.handleAxisParameter(h, ray: ray(at: p)) ?? h.value
        dragHandle = (h, h.value - s, h.value)
        renderer?.activeHandleID = id
        redraw()
        return true
    }

    var isDraggingHandle: Bool { dragHandle != nil }

    func dragHandle(to p: CGPoint) {
        guard var d = dragHandle, let s = ViewportPicker.handleAxisParameter(d.handle, ray: ray(at: p)) else { return }
        var v = s + d.offset
        if let r = d.handle.range { v = min(max(v, r.lowerBound), r.upperBound) }
        d.value = v
        dragHandle = d
        delegate?.viewportHandleDragged(id: d.handle.id, value: v)
    }

    func endHandleDrag() {
        guard let d = dragHandle else { return }
        dragHandle = nil
        renderer?.activeHandleID = nil
        delegate?.viewportHandleDragEnded(id: d.handle.id, value: d.value)
        redraw()
    }
}
