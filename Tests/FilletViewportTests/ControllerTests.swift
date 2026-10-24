import CoreGraphics
import Foundation
import SwiftUI
import Testing
import FilletKernel
@testable import FilletViewport

@MainActor
final class Recorder: ViewportDelegate {
    var wantsToolInput = false
    var taps: [PickTarget?] = []
    var hovers: [PickTarget?] = []
    var handleValues: [Double] = []
    var handleEnded: Double?
    var toolEvents: [(String, ViewportToolEvent)] = []
    var cameras: [Camera] = []

    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers) {
        taps.append(target)
    }
    func viewportHoverChanged(target: PickTarget?) { hovers.append(target) }
    func viewportHandleDragged(id: String, value: Double) { handleValues.append(value) }
    func viewportHandleDragEnded(id: String, value: Double) { handleEnded = value }
    func viewportToolBegan(_ event: ViewportToolEvent) { toolEvents.append(("began", event)) }
    func viewportToolMoved(_ event: ViewportToolEvent) { toolEvents.append(("moved", event)) }
    func viewportToolEnded(_ event: ViewportToolEvent) { toolEvents.append(("ended", event)) }
    func viewportCameraChanged(_ camera: Camera) { cameras.append(camera) }
}

@MainActor
final class CameraBox {
    var camera: Camera
    init(_ c: Camera) { camera = c }
    var binding: Binding<Camera> { Binding(get: { self.camera }, set: { self.camera = $0 }) }
}

@MainActor
@Suite("Controller", .serialized)
struct ControllerTests {
    let cubeID = UUID()
    let size = CGSize(width: 800, height: 600)

    func make(handles: [Handle] = [], animate: Bool = false) -> (ViewportController, Recorder, CameraBox) {
        let c = ViewportController()
        let r = Recorder()
        let box = CameraBox(Camera(target: .zero, distance: 120).viewing(.front))
        c.viewSize = size
        c.cameraBinding = box.binding
        let scene = ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20))], handles: handles)
        c.update(scene: scene, camera: box.camera, filter: .default, options: ViewportOptions(animatesCameraChanges: animate),
                 delegate: r, appearance: .light)
        return (c, r, box)
    }

    @Test func tapPicksFaceAndEmptySpace() {
        let (c, r, _) = make()
        c.tap(at: CGPoint(x: 400, y: 300), pointer: .mouse, modifiers: [])
        c.tap(at: CGPoint(x: 20, y: 20), pointer: .mouse, modifiers: [.shift])
        #expect(r.taps.count == 2)
        #expect(r.taps[0] == .face(body: cubeID, index: 2))
        #expect(r.taps[1] == nil)
    }

    @Test func hoverReportsChangesOnly() {
        let (c, r, _) = make()
        c.hover(at: CGPoint(x: 400, y: 300), pointer: .mouse)
        c.hover(at: CGPoint(x: 401, y: 300), pointer: .mouse)
        c.hover(at: nil, pointer: .mouse)
        #expect(r.hovers == [.face(body: cubeID, index: 2), nil])
        #expect(c.renderer?.pointerHover == nil)
    }

    @Test func handleDragReportsAxisValue() throws {
        let h = Handle(id: "distance", origin: Vec3(0, 0, 10), direction: .unitZ, value: 5, range: 0...40)
        let (c, r, _) = make(handles: [h])
        let g = try #require(ViewportPicker.handleScreenGeometry(h, camera: c.liveCamera, viewSize: size))
        let grab = CGPoint(x: (g.start.x + g.tip.x) / 2, y: (g.start.y + g.tip.y) / 2)
        #expect(c.beginHandleDrag(at: grab, pointer: .touch))
        let wpp = c.liveCamera.worldUnitsPerPoint(viewSize: size)
        c.dragHandle(to: CGPoint(x: grab.x, y: grab.y - 50))
        let v = try #require(r.handleValues.last)
        #expect(abs(v - (5 + 50 * wpp)) < 0.05)
        c.dragHandle(to: CGPoint(x: grab.x, y: grab.y - 5000))
        #expect(r.handleValues.last == 40)  // clamped
        c.endHandleDrag()
        #expect(r.handleEnded == 40)
        #expect(!c.isDraggingHandle)
    }

    @Test func toolEventsCarryRayAndHit() throws {
        let (c, r, _) = make()
        r.wantsToolInput = true
        c.toolBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5, pointer: .pencil, modifiers: [])
        c.toolMoved(at: CGPoint(x: 410, y: 300), pressure: 0.6, pointer: .pencil, modifiers: [])
        c.toolEnded(at: CGPoint(x: 420, y: 300), pressure: nil, pointer: .pencil, modifiers: [])
        #expect(r.toolEvents.map(\.0) == ["began", "moved", "ended"])
        let first = r.toolEvents[0].1
        #expect(first.pressure == 0.5)
        #expect(first.hit?.target == .face(body: cubeID, index: 2))
        #expect(first.ray.direction.distance(to: Vec3(0, 1, 0)) < 1e-9)
    }

    @Test func gesturesWriteCameraBackWhenTheyEnd() {
        let (c, r, box) = make()
        let before = box.camera
        c.beginOrbit(at: CGPoint(x: 400, y: 300))
        c.orbit(by: CGSize(width: 30, height: 10))
        #expect(box.camera == before)          // binding untouched mid-gesture
        #expect(c.liveCamera != before)
        c.endNavigation()
        #expect(box.camera == c.liveCamera)
        #expect(r.cameras.last == c.liveCamera)
        // Zoom at a point.
        c.beginZoom(at: CGPoint(x: 400, y: 300))
        c.zoom(factor: 0.5, at: CGPoint(x: 400, y: 300))
        c.endNavigation()
        #expect(abs(box.camera.distance - before.distance * 0.5) < 1e-9)
    }

    @Test func externalCameraChangesApplyOrAnimate() {
        let (c, r, box) = make()
        var next = box.camera
        next.setView(.top)
        c.update(scene: ViewportScene(), camera: next, filter: .default, options: ViewportOptions(animatesCameraChanges: false),
                 delegate: r, appearance: .dark)
        #expect(c.liveCamera == next)
        var third = next
        third.distance = 50
        c.update(scene: ViewportScene(), camera: third, filter: .default, options: ViewportOptions(animatesCameraChanges: true),
                 delegate: r, appearance: .dark)
        #expect(c.renderer?.isAnimating == true)
        c.renderer?.cancelAnimation()
    }

    @Test func fitAllFramesScene() throws {
        let (c, _, box) = make()
        c.options.animatesCameraChanges = false
        c.animate(to: box.camera.fitted(to: Bounds3(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1))), animated: false)
        c.fitAll(animated: false)
        for p in [Vec3(-10, -10, -10), Vec3(10, 10, 10)] {
            let s = try #require(c.liveCamera.project(p, viewSize: size))
            #expect(s.x >= 0 && s.x <= size.width && s.y >= 0 && s.y <= size.height)
        }
        #expect(box.camera == c.liveCamera)
    }
}
