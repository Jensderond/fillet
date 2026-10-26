import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// One thing picked with Measure. It keeps the body's shape as it was picked, so a pick from
/// before an undo or an agent's edit is dropped instead of being read off a different shape.
struct MeasurePick: Equatable {
    var body: BodyRef
    var element: MeasureElement
    var shape: Shape

    static func == (a: MeasurePick, b: MeasurePick) -> Bool {
        a.body == b.body && a.element == b.element && a.shape === b.shape
    }

    /// A face, edge, vertex or body of a body that's shown; nil for anything else.
    init?(_ target: PickTarget, in model: EvaluatedModel) {
        let element: MeasureElement
        switch target {
        case .body: element = .body
        case .face(_, let i): element = .face(i)
        case .edge(_, let i): element = .edge(i)
        case .vertex(_, let i): element = .vertex(i)
        default: return nil
        }
        guard let id = target.bodyID, let body = model.body(BodyRef(id)) else { return nil }
        self.body = body.ref
        self.element = element
        self.shape = body.shape
    }

    var target: PickTarget {
        switch element {
        case .body: .body(body.feature)
        case .face(let i): .face(body: body.feature, index: i)
        case .edge(let i): .edge(body: body.feature, index: i)
        case .vertex(let i): .vertex(body: body.feature, index: i)
        }
    }
}

/// Inspect > Measure, like Fusion's: pick up to two things and read off their sizes, and between
/// two the minimum distance and the angle. A third pick starts over. Transient: no feature, no
/// document change, no undo step. The results are computed once per pick, not per frame.
struct MeasureState: Equatable {
    private(set) var picks: [MeasurePick] = []
    /// Fusion's selection filter: whole bodies instead of faces, edges and vertices.
    var picksBodies = false
    /// One per pick, in order; nil where the kernel couldn't measure it.
    private(set) var items: [ItemMeasurement?] = []
    private(set) var pair: PairMeasurement?

    /// Adds a pick, takes back one picked again, or starts over when two are already picked.
    mutating func toggle(_ pick: MeasurePick) {
        if let i = picks.firstIndex(of: pick) {
            picks.remove(at: i)
        } else if picks.count >= 2 {
            picks = [pick]
        } else {
            picks.append(pick)
        }
        measure()
    }

    mutating func clear() {
        picks = []
        measure()
    }

    /// Drops picks whose body is gone or was rebuilt (undo, redo, an agent's step).
    mutating func dropStale(in model: EvaluatedModel) {
        let fresh = picks.filter { model.body($0.body)?.shape === $0.shape }
        guard fresh.count != picks.count else { return }
        picks = fresh
        measure()
    }

    private mutating func measure() {
        items = picks.map { Measure.item($0.shape, $0.element) }
        pair = picks.count == 2 ? Measure.pair((picks[0].shape, picks[0].element), (picks[1].shape, picks[1].element)) : nil
    }
}

extension DesignSession {
    /// Why Measure can't start right now, or nil when it can.
    var measureUnavailableReason: String? {
        if isBusyEditing, let name = editingFeature?.name { return "Finish \(name) first: Done or Cancel." }
        if model.bodies.isEmpty { return "Needs a body. Extrude a sketch first." }
        return nil
    }

    /// Turns Measure on or off. An open sketch is finished first; picked faces, edges and bodies
    /// carry over, so picking two faces and then Measure measures between them.
    func startMeasure() {
        if measure != nil { return endMeasure() }
        if let reason = measureUnavailableReason { message = ToastMessage(reason); return }
        if sketchEditor != nil { finishSketch() }
        if choosingSketchPlane { cancelChoosingSketchPlane() }
        var state = MeasureState()
        for s in selection.prefix(2) {
            if let target = s.pickTarget, let pick = MeasurePick(target, in: model) { state.toggle(pick) }
        }
        measure = state
        selection = []
        hover = nil
    }

    func endMeasure() {
        measure = nil
        hover = nil
    }

    /// Escape clears the picks first, then leaves Measure.
    func escapeMeasure() {
        if measure?.picks.isEmpty == false { measure?.clear() } else { endMeasure() }
    }

    func measureTapped(_ target: PickTarget?) {
        guard let target, let pick = MeasurePick(target, in: model) else { return }
        measure?.toggle(pick)
    }

    func setMeasurePicksBodies(_ bodies: Bool) {
        guard measure?.picksBodies != bodies else { return }
        measure?.picksBodies = bodies
        measure?.clear()
        hover = nil
    }

    /// Measure's picks on the canvas: picked like a selection (picked edges thick and haloed,
    /// vertices as dots), and the shortest distance drawn as a dimension line between the closest points.
    func applyMeasure(to scene: inout ViewportScene) {
        guard let state = measure else { return }
        let picks = state.picks.filter { model.body($0.body)?.shape === $0.shape }
        scene.selection = Set(picks.map(\.target))
        for pick in picks {
            guard case .edge(let i) = pick.element, let edges = model.meshes[pick.body]?.edges,
                edges.indices.contains(i), edges[i].count >= 2
            else { continue }
            scene.edgeHighlights.append(EdgeHighlight(points: edges[i].map { Vec3($0) }))
        }
        if let pair = state.pair, picks.count == 2, pair.distance > 1e-6 {
            scene.measures.append(MeasureAnnotation(id: "measure-distance", from: pair.pointA, to: pair.pointB,
                                                    label: "\(Self.measureFormat(pair.distance)) mm"))
        }
    }

    /// What the hint over the viewport says while measuring.
    var measureHint: String {
        let pick = Theme.Copy.pick
        switch measure?.picks.count ?? 0 {
        case 0: return measure?.picksBodies == true ? "\(pick) bodies to measure" : "\(pick) faces, edges or vertices to measure"
        case 1: return "\(pick) another to measure between them"
        default: return "\(pick) again to start over"
        }
    }

    /// Two decimals at most, like the rest of the app's sizes.
    static func measureFormat(_ v: Double) -> String { ExprField.format((v * 100).rounded() / 100) }
}
