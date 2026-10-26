import CoreGraphics
import Foundation
import simd
import FilletKernel

// MARK: - Selection rules

/// How a pick changes a selection.
public enum SelectionUpdate: Hashable, Sendable {
    /// The picked items become the selection.
    case replace
    /// The picked items join the selection.
    case add
    /// The picked items leave the selection if they were all in it, otherwise they join it.
    case toggle
}

/// Fillet's selection conventions, in one place so taps, clicks and boxes agree.
///
/// - A mouse or trackpad click replaces the selection, like Fusion and the Finder; Shift or ⌘
///   toggles what was clicked in or out. Clicking empty space clears (with a modifier, nothing).
/// - A finger or Apple Pencil tap toggles: touch has no modifier keys, so it keeps adding (the
///   touch-CAD convention of Shapr3D). A tap on empty space clears. A hardware keyboard's Shift
///   or ⌘ toggles too, so they mean the same on every input.
/// - A box replaces with the mouse, adds with Shift and toggles with ⌘; a touch or Pencil box adds.
/// - While a step picks its edges, faces or bodies (Fillet, Shell…), taps toggle and boxes add
///   whatever the input, as in a Fusion command.
public enum SelectionRules {
    /// What a tap or click on something does to the selection outside a step.
    public static func tap(modifiers: ViewportModifiers, pointer: PointerKind) -> SelectionUpdate {
        if !modifiers.isDisjoint(with: [.shift, .command]) { return .toggle }
        return pointer == .mouse ? .replace : .toggle
    }

    /// Whether a tap on empty space clears the selection outside a step.
    public static func tapOnNothingClears(modifiers: ViewportModifiers) -> Bool {
        modifiers.isDisjoint(with: [.shift, .command])
    }

    /// What a selection box does to the selection outside a step.
    public static func box(modifiers: ViewportModifiers, pointer: PointerKind) -> SelectionUpdate {
        if modifiers.contains(.command) { return .toggle }
        if modifiers.contains(.shift) { return .add }
        return pointer == .mouse ? .replace : .add
    }

    /// `selection` after picking `items` (a single item, a chain, a loop, a box's contents).
    /// Order is kept: what stays keeps its place, what joins goes at the end.
    public static func apply<T: Equatable>(_ update: SelectionUpdate, _ items: [T], to selection: [T]) -> [T] {
        var unique: [T] = []
        for item in items where !unique.contains(item) { unique.append(item) }
        switch update {
        case .replace:
            return unique
        case .add:
            return selection + unique.filter { !selection.contains($0) }
        case .toggle:
            if !unique.isEmpty, unique.allSatisfy(selection.contains) {
                return selection.filter { !unique.contains($0) }
            }
            return selection + unique.filter { !selection.contains($0) }
        }
    }
}

// MARK: - Selection box

/// Which elements a selection box takes, by the way it was dragged (Fusion's convention).
public enum BoxSelectMode: Hashable, Sendable {
    /// Dragged left to right: only what lies wholly inside the box.
    case window
    /// Dragged right to left: anything the box touches.
    case crossing
}

/// A rectangle being dragged across the viewport to select, in view points.
public struct SelectionBox: Hashable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    /// What a box made with this input does (see ``SelectionRules/box(modifiers:pointer:)``).
    public var update: SelectionUpdate

    public init(start: CGPoint, end: CGPoint, update: SelectionUpdate = .replace) {
        self.start = start; self.end = end; self.update = update
    }

    public var mode: BoxSelectMode { end.x >= start.x ? .window : .crossing }
    public var rect: CGRect { CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized }
}

extension ViewportPicker {
    /// Everything a selection box over `rect` (view points) selects, of the kinds in `filter`
    /// (`.edges`, `.faces`, `.bodies`), in body and index order.
    ///
    /// Only what can be seen is selected, as with a single pick: hidden bodies and anything behind
    /// another face are left out. A window (`.window`) takes elements whose whole outline projects
    /// inside the box and some of which is visible there; a crossing box takes elements of which
    /// any visible part is inside it.
    public func boxSelect(scene: ViewportScene, camera: Camera, rect: CGRect, viewSize: CGSize,
                          filter: PickFilter, mode: BoxSelectMode) -> [PickTarget] {
        guard rect.width >= 1, rect.height >= 1 else { return [] }
        let bodies = scene.bodies.filter { $0.visible && $0.pickable && !$0.mesh.indices.isEmpty }
        var result: [PickTarget] = []
        if filter.contains(.edges) {
            result += boxEdges(bodies, camera: camera, rect: rect, viewSize: viewSize, mode: mode)
        }
        if !filter.isDisjoint(with: [.faces, .bodies]) {
            let seen = visibleFaces(in: rect, bodies: bodies, camera: camera, viewSize: viewSize)
            if filter.contains(.faces) {
                result += boxFaces(bodies, scene: scene, seen: seen, camera: camera, rect: rect, viewSize: viewSize, mode: mode)
            }
            if filter.contains(.bodies) {
                result += boxBodies(bodies, seen: seen, camera: camera, rect: rect, viewSize: viewSize, mode: mode)
            }
        }
        return result
    }

    /// Screen position of a world point, or nil behind the camera.
    private func screen(_ p: Vec3, _ camera: Camera, _ viewSize: CGSize) -> CGPoint? {
        camera.project(p, viewSize: viewSize)
    }

    // MARK: Edges

    private func boxEdges(_ bodies: [SceneBody], camera: Camera, rect: CGRect, viewSize: CGSize, mode: BoxSelectMode) -> [PickTarget] {
        var result: [PickTarget] = []
        for body in bodies where body.showsEdges {
            for (index, poly) in body.mesh.edges.enumerated() where poly.count >= 2 {
                if edgeSelected(poly.map { Vec3($0) }, bodies: bodies, camera: camera, rect: rect, viewSize: viewSize, mode: mode) {
                    result.append(.edge(body: body.id, index: index))
                }
            }
        }
        return result
    }

    /// Samples along an edge no more than about 4 pt apart on screen, so a box can't slip between
    /// two of them, then decides window or crossing on those samples.
    private func edgeSelected(_ points: [Vec3], bodies: [SceneBody], camera: Camera, rect: CGRect, viewSize: CGSize,
                              mode: BoxSelectMode) -> Bool {
        // Samples inside the box, with how far along the edge (on screen) each one is.
        var inside: [(point: Vec3, along: Double)] = []
        var allInside = true
        var length = 0.0
        for k in 0..<(points.count - 1) {
            let a = points[k], b = points[k + 1]
            guard let sa = screen(a, camera, viewSize), let sb = screen(b, camera, viewSize) else {
                allInside = false
                continue
            }
            let segment = Double(hypot(sb.x - sa.x, sb.y - sa.y))
            let steps = min(64, max(1, Int((segment / 4).rounded(.up))))
            for s in 0...steps where k == 0 || s > 0 {
                let t = Double(s) / Double(steps)
                let sp = CGPoint(x: sa.x + (sb.x - sa.x) * t, y: sa.y + (sb.y - sa.y) * t)
                if rect.contains(sp) { inside.append((a + (b - a) * t, length + segment * t)) } else { allInside = false }
            }
            length += segment
            if mode == .window, !allInside { return false }
        }
        guard !inside.isEmpty, mode == .crossing || allInside else { return false }
        // Visible somewhere in the box. An edge's ends sit on corners that may be in view while
        // the edge itself is hidden behind a face, so look along its inside first (8–92 % of its
        // length), and at the ends only when the box holds nothing else of it.
        let margin = length * 0.08
        let middle = inside.filter { $0.along >= margin && $0.along <= length - margin }
        let candidates = middle.isEmpty ? inside : middle
        // Up to 24 samples spread along what's inside.
        let stride = max(1, candidates.count / 24)
        for i in Swift.stride(from: 0, to: candidates.count, by: stride)
        where isVisible(candidates[i].point, bodies: bodies, camera: camera, viewSize: viewSize) {
            return true
        }
        return false
    }

    // MARK: Faces and bodies

    /// Faces seen through a grid of rays across the box (an ID buffer on the CPU): what is in
    /// front at each sample, so a face behind another is never in it. About 4000 rays at most.
    private func visibleFaces(in rect: CGRect, bodies: [SceneBody], camera: Camera, viewSize: CGSize) -> Set<FaceKey> {
        let step = max(3, (Double(rect.width * rect.height) / 4000).squareRoot())
        var seen = Set<FaceKey>()
        var y = Double(rect.minY) + step / 2
        while y < Double(rect.maxY) {
            var x = Double(rect.minX) + step / 2
            while x < Double(rect.maxX) {
                if let hit = raycast(camera.ray(at: CGPoint(x: x, y: y), viewSize: viewSize), bodies: bodies) {
                    seen.insert(FaceKey(body: hit.body, face: hit.face))
                }
                x += step
            }
            y += step
        }
        return seen
    }

    struct FaceKey: Hashable { var body: UUID; var face: Int }

    /// Per face of a body: its triangles' corner indices.
    private func faceTriangles(_ mesh: Mesh) -> [Int: [Int]] {
        var faces: [Int: [Int]] = [:]
        for t in 0..<(mesh.indices.count / 3) {
            let face = t < mesh.triangleFaces.count ? Int(mesh.triangleFaces[t]) : 0
            faces[face, default: []].append(t)
        }
        return faces
    }

    /// Whether a ray through the projection of `p` lands on this face first.
    private func faceVisible(at p: Vec3, _ key: FaceKey, bodies: [SceneBody], camera: Camera, viewSize: CGSize) -> Bool {
        guard let s = screen(p, camera, viewSize), let hit = raycast(camera.ray(at: s, viewSize: viewSize), bodies: bodies) else { return false }
        return FaceKey(body: hit.body, face: hit.face) == key
    }

    private func boxFaces(_ bodies: [SceneBody], scene: ViewportScene, seen: Set<FaceKey>, camera: Camera, rect: CGRect,
                          viewSize: CGSize, mode: BoxSelectMode) -> [PickTarget] {
        var result: [PickTarget] = []
        for body in bodies {
            let mesh = body.mesh
            for (face, triangles) in faceTriangles(mesh).sorted(by: { $0.key < $1.key }) where scene.canPick(face: face, of: body.id) {
                let key = FaceKey(body: body.id, face: face)
                switch mode {
                case .crossing:
                    if seen.contains(key) { result.append(.face(body: body.id, index: face)) }
                case .window:
                    guard allCorners(of: triangles, mesh, inside: rect, camera, viewSize) else { continue }
                    // Small faces can slip between grid rays: try their triangles' centres too.
                    if seen.contains(key) || triangles.prefix(32).contains(where: { t in
                        faceVisible(at: centre(of: t, mesh), key, bodies: bodies, camera: camera, viewSize: viewSize)
                    }) {
                        result.append(.face(body: body.id, index: face))
                    }
                }
            }
        }
        return result
    }

    private func boxBodies(_ bodies: [SceneBody], seen: Set<FaceKey>, camera: Camera, rect: CGRect, viewSize: CGSize,
                           mode: BoxSelectMode) -> [PickTarget] {
        bodies.compactMap { body in
            let visible = seen.contains { $0.body == body.id }
            switch mode {
            case .crossing:
                return visible ? .body(body.id) : nil
            case .window:
                let corners = body.mesh.positions.allSatisfy { p in screen(Vec3(p), camera, viewSize).map(rect.contains) ?? false }
                guard corners else { return nil }
                if visible { return .body(body.id) }
                let mesh = body.mesh
                let shown = (0..<min(mesh.indices.count / 3, 64)).contains { t in
                    let face = t < mesh.triangleFaces.count ? Int(mesh.triangleFaces[t]) : 0
                    return faceVisible(at: centre(of: t, mesh), FaceKey(body: body.id, face: face), bodies: bodies,
                                       camera: camera, viewSize: viewSize)
                }
                return shown ? .body(body.id) : nil
            }
        }
    }

    private func centre(of triangle: Int, _ mesh: Mesh) -> Vec3 {
        let i = 3 * triangle
        let a = Vec3(mesh.positions[Int(mesh.indices[i])]), b = Vec3(mesh.positions[Int(mesh.indices[i + 1])]),
            c = Vec3(mesh.positions[Int(mesh.indices[i + 2])])
        return (a + b + c) / 3
    }

    private func allCorners(of triangles: [Int], _ mesh: Mesh, inside rect: CGRect, _ camera: Camera, _ viewSize: CGSize) -> Bool {
        triangles.allSatisfy { t in
            (0..<3).allSatisfy { k in
                screen(Vec3(mesh.positions[Int(mesh.indices[3 * t + k])]), camera, viewSize).map(rect.contains) ?? false
            }
        }
    }
}
