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
    @ObservationIgnored private(set) var isDraggingTarget = false

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
                delegate: (any ViewportDelegate)?, appearance: ViewportAppearance, increasedContrast: Bool = false) {
        self.scene = scene
        self.filter = filter
        self.options = options
        self.delegate = delegate
        picker.prune(keeping: Set(scene.bodies.map(\.id)))
        renderer?.update(scene: scene)
        renderer?.palette = increasedContrast ? appearance.palette.increasedContrast : appearance.palette
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
        animate(to: liveCamera.framing(b, viewSize: viewSize, insets: options.contentInsets, margin: 1.35), animated: animated)
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

    /// A tap or click. `clickCount` comes from the system where it counts clicks (the Mac);
    /// otherwise a second tap on the same element within `doubleTapInterval` counts as a double tap.
    func tap(at p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers, clickCount: Int? = nil,
             time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let hit = pick(at: p, pointer: pointer, filter: filter)
        var count = clickCount ?? tapCount(at: p, target: hit?.target, pointer: pointer, time: time)
        // A double click that lands on another element than the first click is two clicks.
        if clickCount != nil, count > 1, !Self.sameElement(lastTap?.target, hit?.target) { count = 1 }
        lastTap = (p, hit?.target, pointer, time, count)
        if count == 2 {
            // The face beside the edge, for its loop: whichever one is under the pointer.
            let face = pick(at: p, pointer: pointer, filter: .faces)?.target
            if delegate?.viewportDidDoubleTap(target: hit?.target, face: face, location: p, modifiers: modifiers, pointer: pointer) == true {
                return
            }
            // Nothing to do with a double tap there: it's a second tap.
            lastTap?.count = 1
        } else if count > 2 {
            return
        }
        delegate?.viewportDidTap(target: hit?.target, hit: hit, ray: ray(at: p), location: p, modifiers: modifiers, pointer: pointer)
    }

    /// Longest gap between the taps of a double tap.
    static let doubleTapInterval: TimeInterval = 0.35

    @ObservationIgnored private var lastTap: (location: CGPoint, target: PickTarget?, pointer: PointerKind, time: TimeInterval, count: Int)?

    /// 1 for a first tap, 2 for a second one on the same element close by and soon after, 3 for
    /// a third (ignored, like a triple click).
    func tapCount(at p: CGPoint, target: PickTarget?, pointer: PointerKind, time: TimeInterval) -> Int {
        guard let last = lastTap, last.pointer == pointer, Self.sameElement(last.target, target),
            time - last.time <= Self.doubleTapInterval
        else { return 1 }
        // The very same element may be a fingertip away; another one of the same body (the first
        // tap renumbered it) only right on the same spot, so quick taps on two neighbouring
        // edges stay two taps.
        let distance = hypot(p.x - last.location.x, p.y - last.location.y)
        let reach = last.target == target ? max(pointer.tolerance * 2, 12) : max(pointer.tolerance, 6)
        return distance <= reach ? last.count + 1 : 1
    }

    /// Two taps landed on the same element: the same target, or (as the first tap may have
    /// changed the model, renumbering its edges and faces) the same kind of element of the same
    /// body. Taps on nothing are never the same.
    static func sameElement(_ a: PickTarget?, _ b: PickTarget?) -> Bool {
        guard let a, let b else { return false }
        switch (a, b) {
        case (.edge(let x, _), .edge(let y, _)), (.face(let x, _), .face(let y, _)), (.vertex(let x, _), .vertex(let y, _)):
            return x == y
        default:
            return a == b
        }
    }

    // MARK: Selection box

    /// The selection box being dragged, drawn over the view (nil when there is none).
    public private(set) var selectionBox: SelectionBox?
    /// How many elements the box being dragged would take right now (shown on its tag).
    public private(set) var boxPreviewCount = 0
    @ObservationIgnored private var lastBoxPreview: TimeInterval = 0
    @ObservationIgnored private var boxPreviewTask: Task<Void, Never>?

    /// Whether a drag from here draws a selection box: box mode is on, the Pencil draws it, or
    /// Shift or ⌘ is held. Never while there is nothing a box could select.
    func wantsBox(pointer: PointerKind, modifiers: ViewportModifiers) -> Bool {
        guard !options.boxFilter.isEmpty else { return false }
        return options.boxSelects || pointer == .pencil || !modifiers.isDisjoint(with: [.shift, .command])
    }

    public func beginBox(at p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers) {
        renderer?.cancelAnimation()
        selectionBox = SelectionBox(start: p, end: p, update: SelectionRules.box(modifiers: modifiers, pointer: pointer), pointer: pointer)
        boxPreviewCount = 0
        setHover(nil)
    }

    /// Moves the box's free corner. What it would take lights up as it goes (worked out at most
    /// every 80 ms, and once more when the pointer rests, so a big scene can't stall the drag).
    public func dragBox(to p: CGPoint) {
        selectionBox?.end = p
        let now = ProcessInfo.processInfo.systemUptime
        boxPreviewTask?.cancel()
        if now - lastBoxPreview >= 0.08 {
            updateBoxPreview()
        } else {
            boxPreviewTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                self?.updateBoxPreview()
            }
        }
    }

    private func boxTargets(_ box: SelectionBox) -> [PickTarget] {
        let rect = box.rect
        guard rect.width >= 4 || rect.height >= 4 else { return [] }
        return picker.boxSelect(scene: scene, camera: liveCamera, rect: rect, viewSize: viewSize,
                                filter: options.boxFilter, mode: box.mode)
    }

    private func updateBoxPreview() {
        lastBoxPreview = ProcessInfo.processInfo.systemUptime
        guard let box = selectionBox else { return }
        let targets = boxTargets(box)
        boxPreviewCount = targets.count
        renderer?.boxPreview = targets
        redraw()
    }

    /// Lets go of the box: what it selects goes to the delegate. A box too small to mean
    /// anything (a slip of the finger) selects nothing.
    public func endBox(at p: CGPoint) {
        guard var box = selectionBox else { return }
        box.end = p
        clearBox()
        let rect = box.rect
        guard rect.width >= 4 || rect.height >= 4 else { return }
        delegate?.viewportDidBoxSelect(boxTargets(box), box: box)
    }

    public func cancelBox() {
        clearBox()
    }

    private func clearBox() {
        boxPreviewTask?.cancel()
        selectionBox = nil
        boxPreviewCount = 0
        renderer?.boxPreview = []
        redraw()
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

    func keyDown(_ key: ViewportKey) -> Bool { delegate?.viewportKeyDown(key) ?? false }

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

    // MARK: Dragging picked elements

    /// Starts dragging the element under `p` (the press point of a gesture that has started to
    /// move) if the delegate wants to. Returns whether a drag began; otherwise the gesture navigates.
    func beginTargetDrag(at p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers) -> Bool {
        guard let delegate, let hit = pick(at: p, pointer: pointer, filter: filter) else { return false }
        let event = toolEvent(at: p, pressure: nil, pointer: pointer, modifiers: modifiers, hit: hit)
        guard delegate.viewportShouldBeginDrag(target: hit.target, event: event) else { return false }
        renderer?.cancelAnimation()
        isDraggingTarget = true
        return true
    }

    func dragTarget(to p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers) {
        guard isDraggingTarget else { return }
        // What lies under the pointer doesn't matter mid-drag: skip the pick.
        delegate?.viewportDragMoved(toolEvent(at: p, pressure: nil, pointer: pointer, modifiers: modifiers, hit: .some(nil)))
    }

    func endTargetDrag(at p: CGPoint, pointer: PointerKind, modifiers: ViewportModifiers) {
        guard isDraggingTarget else { return }
        isDraggingTarget = false
        delegate?.viewportDragEnded(toolEvent(at: p, pressure: nil, pointer: pointer, modifiers: modifiers, hit: .some(nil)))
    }

    func cancelTargetDrag() {
        guard isDraggingTarget else { return }
        isDraggingTarget = false
        delegate?.viewportDragCancelled()
    }

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
