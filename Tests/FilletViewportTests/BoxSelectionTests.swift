import CoreGraphics
import Foundation
import Testing
import FilletKernel
@testable import FilletViewport

private let viewSize = CGSize(width: 800, height: 600)
private let cubeID = UUID()

/// 20 mm cube centred on the origin, seen from the front-right-top: the top, front and right faces
/// show, and the three edges at the bottom-back-left corner are hidden.
private func cubeScene() -> ViewportScene {
    ViewportScene(bodies: [SceneBody(id: cubeID, mesh: DemoMeshes.cube(size: 20))])
}

private let camera = Camera(target: .zero, distance: 120, yaw: 0.5, pitch: 0.45)

private func screen(_ p: Vec3) -> CGPoint { camera.project(p, viewSize: viewSize)! }

/// A box from `a` to `b` (view points): left to right is a window, right to left a crossing box.
private func box(_ a: CGPoint, _ b: CGPoint) -> SelectionBox { SelectionBox(start: a, end: b) }

private func select(_ scene: ViewportScene, _ b: SelectionBox, _ filter: PickFilter) -> [PickTarget] {
    ViewportPicker().boxSelect(scene: scene, camera: camera, rect: b.rect, viewSize: viewSize, filter: filter, mode: b.mode)
}

@Suite("Selection rules")
struct SelectionRulesTests {
    @Test func clickReplacesModifiersToggleTouchAdds() {
        #expect(SelectionRules.tap(modifiers: [], pointer: .mouse) == .replace)
        #expect(SelectionRules.tap(modifiers: .shift, pointer: .mouse) == .toggle)
        #expect(SelectionRules.tap(modifiers: .command, pointer: .mouse) == .toggle)
        // ⌥ and ⌃ aren't selection modifiers.
        #expect(SelectionRules.tap(modifiers: .option, pointer: .mouse) == .replace)
        #expect(SelectionRules.tap(modifiers: [], pointer: .touch) == .toggle)
        #expect(SelectionRules.tap(modifiers: [], pointer: .pencil) == .toggle)
        #expect(SelectionRules.tap(modifiers: .shift, pointer: .touch) == .toggle)
        #expect(SelectionRules.tapOnNothingClears(modifiers: []))
        #expect(!SelectionRules.tapOnNothingClears(modifiers: .shift))
    }

    @Test func boxReplacesAddsOrToggles() {
        #expect(SelectionRules.box(modifiers: [], pointer: .mouse) == .replace)
        #expect(SelectionRules.box(modifiers: .shift, pointer: .mouse) == .add)
        #expect(SelectionRules.box(modifiers: .command, pointer: .mouse) == .toggle)
        #expect(SelectionRules.box(modifiers: [], pointer: .touch) == .add)
        #expect(SelectionRules.box(modifiers: [], pointer: .pencil) == .add)
    }

    @Test func applyKeepsOrderAndToggleTakesGroupsOut() {
        let selection = [1, 2, 3]
        #expect(SelectionRules.apply(.replace, [5, 5, 4], to: selection) == [5, 4])
        #expect(SelectionRules.apply(.add, [3, 4], to: selection) == [1, 2, 3, 4])
        // A group partly in the selection joins; wholly in, it leaves.
        #expect(SelectionRules.apply(.toggle, [3, 4], to: selection) == [1, 2, 3, 4])
        #expect(SelectionRules.apply(.toggle, [3, 1], to: selection) == [2])
        #expect(SelectionRules.apply(.toggle, [2], to: selection) == [1, 3])
        // Nothing picked: replace clears, add and toggle leave it be.
        #expect(SelectionRules.apply(.replace, [Int](), to: selection).isEmpty)
        #expect(SelectionRules.apply(.add, [Int](), to: selection) == selection)
        #expect(SelectionRules.apply(.toggle, [Int](), to: selection) == selection)
    }

    @Test func dragDirectionSetsTheMode() {
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 300, y: 50)
        #expect(box(a, b).mode == .window)
        #expect(box(b, a).mode == .crossing)
        #expect(box(b, a).rect == CGRect(x: 100, y: 50, width: 200, height: 50))
    }
}

@Suite("Box select")
struct BoxSelectTests {
    /// Edges whose middle can be seen: what a window over the whole cube should take.
    private func visibleEdges() -> Set<PickTarget> {
        let picker = ViewportPicker()
        let mesh = cubeScene().bodies[0].mesh
        return Set(mesh.edges.indices.filter { i in
            let poly = mesh.edges[i]
            let mid = (Vec3(poly.first!) + Vec3(poly.last!)) / 2
            return picker.isVisible(mid, bodies: cubeScene().bodies, camera: camera, viewSize: viewSize)
        }.map { PickTarget.edge(body: cubeID, index: $0) })
    }

    @Test func windowOverEverythingTakesOnlyVisibleEdges() {
        let all = box(CGPoint(x: 10, y: 10), CGPoint(x: 790, y: 590))
        let edges = select(cubeScene(), all, .edges)
        #expect(edges.count == 9)
        #expect(Set(edges) == visibleEdges())
        // Hidden geometry is left out: the vertical edge at the back-left corner (index 11).
        #expect(!edges.contains(.edge(body: cubeID, index: 11)))
        // Crossing over everything takes the same: nothing more is visible.
        #expect(Set(select(cubeScene(), box(all.end, all.start), .edges)) == visibleEdges())
    }

    @Test func windowNeedsAllOfAnEdgeCrossingAnyOfIt() {
        // Top-front edge (index 4): from (-10, -10, 10) to (10, -10, 10). A box around its right half.
        let mid = screen(Vec3(0, -10, 10)), right = screen(Vec3(10, -10, 10))
        let a = CGPoint(x: mid.x - 2, y: min(mid.y, right.y) - 6), b = CGPoint(x: right.x + 6, y: max(mid.y, right.y) + 6)
        let window = select(cubeScene(), box(a, b), .edges)
        let crossing = select(cubeScene(), box(b, a), .edges)
        #expect(!window.contains(.edge(body: cubeID, index: 4)))
        #expect(crossing.contains(.edge(body: cubeID, index: 4)))
        // A window around the whole edge takes it.
        let left = screen(Vec3(-10, -10, 10))
        let whole = box(CGPoint(x: min(left.x, right.x) - 6, y: min(left.y, right.y) - 6),
                        CGPoint(x: max(left.x, right.x) + 6, y: max(left.y, right.y) + 6))
        #expect(select(cubeScene(), whole, .edges).contains(.edge(body: cubeID, index: 4)))
    }

    @Test func facesWindowAndCrossing() {
        // Over everything: the three faces in view (top, front, right), not the three behind.
        let all = box(CGPoint(x: 10, y: 10), CGPoint(x: 790, y: 590))
        let faces = select(cubeScene(), all, .faces)
        #expect(faces.count == 3)
        #expect(faces.contains(.face(body: cubeID, index: 2)))  // front (-Y)
        // A small box in the middle of the front face: crossing takes it, a window doesn't.
        let c = screen(Vec3(0, -10, 0))
        let a = CGPoint(x: c.x - 5, y: c.y - 5), b = CGPoint(x: c.x + 5, y: c.y + 5)
        #expect(select(cubeScene(), box(b, a), .faces) == [.face(body: cubeID, index: 2)])
        #expect(select(cubeScene(), box(a, b), .faces).isEmpty)
    }

    @Test func faceFilterLimitsBoxedFaces() {
        var scene = cubeScene()
        scene.pickableFaces = [cubeID: [2]]
        let all = box(CGPoint(x: 10, y: 10), CGPoint(x: 790, y: 590))
        #expect(select(scene, all, .faces) == [.face(body: cubeID, index: 2)])
    }

    @Test func bodiesBehindOthersAndHiddenBodiesAreLeftOut() {
        let front = UUID(), behind = UUID(), hidden = UUID()
        let scene = ViewportScene(bodies: [
            SceneBody(id: front, mesh: DemoMeshes.cube(size: 20)),
            // Small and straight behind the first cube, seen from the front: covered.
            SceneBody(id: behind, mesh: DemoMeshes.cube(size: 6, center: [0, 30, 0])),
            SceneBody(id: hidden, mesh: DemoMeshes.cube(size: 6, center: [40, 0, 0]), visible: false),
        ])
        let cam = Camera(target: .zero, distance: 150).viewing(.front)
        func pick(_ a: CGPoint, _ b: CGPoint) -> [PickTarget] {
            let r = box(a, b)
            return ViewportPicker().boxSelect(scene: scene, camera: cam, rect: r.rect, viewSize: viewSize, filter: .bodies, mode: r.mode)
        }
        let all = (CGPoint(x: 5, y: 5), CGPoint(x: 795, y: 595))
        #expect(pick(all.0, all.1) == [.body(front)])
        #expect(pick(all.1, all.0) == [.body(front)])
        // A crossing box over the middle touches the front cube only.
        #expect(pick(CGPoint(x: 410, y: 310), CGPoint(x: 390, y: 290)) == [.body(front)])
        // A window around part of the cube takes nothing: the body isn't wholly inside.
        #expect(pick(CGPoint(x: 390, y: 290), CGPoint(x: 410, y: 310)).isEmpty)
    }

    @Test func tinyOrEmptyBoxesSelectNothing() {
        #expect(select(cubeScene(), box(CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 300)), [.edges, .faces, .bodies]).isEmpty)
        #expect(select(cubeScene(), box(CGPoint(x: 10, y: 10), CGPoint(x: 790, y: 590)), []).isEmpty)
    }
}

/// Records what the controller tells its delegate.
@MainActor
private final class SelectionRecorder: ViewportDelegate {
    var taps: [(PickTarget?, PointerKind)] = []
    var doubles: [(PickTarget?, PickTarget?)] = []
    var boxes: [([PickTarget], SelectionBox)] = []

    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers,
                        pointer: PointerKind) {
        taps.append((target, pointer))
    }

    func viewportDidDoubleTap(target: PickTarget?, face: PickTarget?, location: CGPoint, modifiers: ViewportModifiers,
                              pointer: PointerKind) {
        doubles.append((target, face))
    }

    func viewportDidBoxSelect(_ targets: [PickTarget], box: SelectionBox) { boxes.append((targets, box)) }
}

@Suite("Viewport taps and boxes")
@MainActor
struct ControllerSelectionTests {
    private func controller(_ delegate: SelectionRecorder, options: ViewportOptions = ViewportOptions()) -> ViewportController {
        let c = ViewportController()
        c.viewSize = viewSize
        c.update(scene: cubeScene(), camera: camera, filter: [.faces, .edges], options: options, delegate: delegate, appearance: .light)
        return c
    }

    @Test func secondTapOnTheSameEdgeIsADoubleTap() {
        let r = SelectionRecorder()
        let c = controller(r)
        let edge = screen(Vec3(0, -10, 10))
        c.tap(at: edge, pointer: .touch, modifiers: [], time: 100)
        c.tap(at: CGPoint(x: edge.x + 3, y: edge.y), pointer: .touch, modifiers: [], time: 100.2)
        #expect(r.taps.count == 1)
        #expect(r.doubles.count == 1)
        #expect(r.doubles.first?.0 == .edge(body: cubeID, index: 4))
        // The face under the finger comes along, for the loop.
        if case .face(let body, _)? = r.doubles.first?.1 { #expect(body == cubeID) } else { Issue.record("expected a face") }
        // Too slow: two taps.
        c.tap(at: edge, pointer: .touch, modifiers: [], time: 101)
        c.tap(at: edge, pointer: .touch, modifiers: [], time: 101.6)
        #expect(r.taps.count == 3 && r.doubles.count == 1)
    }

    @Test func quickTapsOnDifferentThingsStayTaps() {
        let r = SelectionRecorder()
        let c = controller(r)
        c.tap(at: screen(Vec3(0, -10, 10)), pointer: .touch, modifiers: [], time: 100)
        c.tap(at: screen(Vec3(0, -10, 0)), pointer: .touch, modifiers: [], time: 100.1)
        #expect(r.taps.count == 2 && r.doubles.isEmpty)
        // A Mac double click that lands somewhere else is a click too.
        c.tap(at: screen(Vec3(0, -10, 10)), pointer: .mouse, modifiers: [], clickCount: 2, time: 100.2)
        #expect(r.taps.count == 3 && r.doubles.isEmpty)
        #expect(r.taps.last?.1 == .mouse)
    }

    @Test func boxNeedsAFilterAndAModeModifierOrPencil() {
        let r = SelectionRecorder()
        #expect(!controller(r).wantsBox(pointer: .pencil, modifiers: []))
        let c = controller(r, options: ViewportOptions(boxFilter: .edges))
        #expect(!c.wantsBox(pointer: .mouse, modifiers: []))
        #expect(!c.wantsBox(pointer: .touch, modifiers: .option))
        #expect(c.wantsBox(pointer: .mouse, modifiers: .shift))
        #expect(c.wantsBox(pointer: .mouse, modifiers: .command))
        #expect(c.wantsBox(pointer: .pencil, modifiers: []))
        #expect(controller(r, options: ViewportOptions(boxFilter: .edges, boxSelects: true)).wantsBox(pointer: .touch, modifiers: []))
    }

    @Test func boxGoesToTheDelegateWhenLetGo() {
        let r = SelectionRecorder()
        let c = controller(r, options: ViewportOptions(boxFilter: .edges, boxSelects: true))
        c.beginBox(at: CGPoint(x: 790, y: 590), pointer: .touch, modifiers: [])
        c.dragBox(to: CGPoint(x: 400, y: 300))
        #expect(c.selectionBox?.mode == .crossing)
        c.endBox(at: CGPoint(x: 10, y: 10))
        #expect(c.selectionBox == nil)
        #expect(r.boxes.count == 1)
        #expect(r.boxes.first?.1.update == .add)
        #expect(r.boxes.first?.0.count == 9)
        // A slip of the finger is no box.
        c.beginBox(at: CGPoint(x: 100, y: 100), pointer: .touch, modifiers: [])
        c.endBox(at: CGPoint(x: 102, y: 101))
        #expect(r.boxes.count == 1)
    }
}
