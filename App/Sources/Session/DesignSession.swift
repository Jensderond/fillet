import FilletCore
import FilletKernel
import FilletViewport
import Observation
import SwiftUI

/// Something the user has picked in the viewport or the browser.
enum Selection: Hashable {
    case body(BodyRef)
    case face(BodyRef, Int)
    case edge(BodyRef, Int)
    case region(sketch: UUID, index: Int)
    case sketchShape(sketch: UUID, shape: UUID)
    /// An origin plane (only ever hovered, while choosing where to sketch).
    case originPlane(StandardPlane)
}

/// A feature being created or edited in the inspector. The feature lives in
/// the document while editing (so the viewport shows a live result); commit
/// records one undo step, cancel restores the snapshot.
struct FeatureEdit: Equatable {
    var feature: UUID
    var isNew: Bool
    var snapshot: Document
}

/// A banner over the viewport. Info dismisses itself (the timer pauses under the pointer);
/// errors stay until dismissed or the next edit; a failed-step banner stays until the step
/// works again, and its Show button opens the step.
struct ToastMessage: Equatable, ExpressibleByStringInterpolation {
    enum Kind { case info, error }
    enum Action: Equatable {
        /// Open this step in the inspector and bring it into view on the timeline.
        case showFeature(UUID)
        /// Turn on finger drawing (the editor owns that setting).
        case drawWithFinger

        var title: String {
            switch self {
            case .showFeature: "Show"
            case .drawWithFinger: "Draw with finger"
            }
        }
    }
    var text: String
    var kind: Kind = .info
    var action: Action?
    /// Each post is distinct, so the same text shown twice restarts its timer.
    let id = UUID()

    init(_ text: String, kind: Kind = .info, action: Action? = nil) { self.text = text; self.kind = kind; self.action = action }
    init(stringLiteral value: String) { self.init(value) }

    static func error(_ text: String) -> ToastMessage { ToastMessage(text, kind: .error) }

    /// Only info dismisses itself.
    var dismissesItself: Bool { kind == .info }

    /// Seconds on screen: at least 4, longer for long text (about 15 characters a second).
    var duration: Double { max(4, Double(text.count) / 15) }

    /// The step a failed-step banner is about.
    var failedFeature: UUID? { if case .showFeature(let id)? = action { id } else { nil } }
}

/// All editing state of one open document window.
@MainActor @Observable
final class DesignSession {
    private(set) var document: Document
    private(set) var model: EvaluatedModel
    private(set) var isRecomputing = false

    var selection: [Selection] = []
    var hover: Selection?
    var editing: FeatureEdit?
    var sketchEditor: SketchEditor?
    /// Sketch was asked for with no flat face picked: the origin planes show in the viewport
    /// and the next tap on one of them, or on a flat face, opens the new sketch there.
    var choosingSketchPlane = false
    /// A drawing tool's shortcut was pressed outside sketch mode: the sketch it starts opens with it.
    var pendingSketchTool: SketchTool?
    /// Measure is on (see `MeasureState`); nil otherwise.
    var measure: MeasureState?
    /// Bodies hidden in the viewport (and left out of exports). Saved with the document so they
    /// stay hidden on reopen, but not an undo step (like Fusion's eye toggles); see `setDocument`.
    var hiddenBodies: Set<BodyRef> {
        get { document.hiddenBodies }
        set {
            guard newValue != document.hiddenBodies else { return }
            document.hiddenBodies = newValue
            // Marks the file dirty so it saves; visibility doesn't change the model, so no recompute.
            onDocumentChange?(document)
        }
    }
    var camera = Camera(target: Vec3(0, 0, 10), distance: 260)
    /// Size of the viewport in points (for converting screen tolerances to mm).
    @ObservationIgnored var viewSize = CGSize(width: 1000, height: 800)
    /// What the editor's floating chrome covers of the viewport (see `CameraFraming`).
    @ObservationIgnored var chromeInsets = ChromeInsets()
    /// The first real viewport size frames the bed or the design once.
    @ObservationIgnored var hasFramedInitialView = false
    /// Set when a shape lands in the open sketch; the next recompute checks it's still in view.
    @ObservationIgnored var revealSketchAfterRecompute = false
    var showOverhangs = false
    var overhangAngle = 45.0
    /// Window title when the document has no explicit name.
    var documentName: String?
    /// Set by the menu command; the editor presents the file importer.
    var importRequested = false
    /// Shown as a banner over the viewport (export finished, a step failed…).
    var message: ToastMessage?
    /// Finger orbits and taps while a drawing tool waited (see `viewportFingerMissedTool`).
    @ObservationIgnored var fingerMissedToolCount = 0
    /// Apple Pencil has drawn in this window, so fingers navigating is on purpose.
    @ObservationIgnored var pencilHasDrawn = false
    /// The finger drawing hint shows once per window.
    @ObservationIgnored var offeredFingerDrawing = false
    /// The flat faces of each body, kept while the body's shape stays the same (see `planarFaces`).
    @ObservationIgnored var planarFaceCache: [BodyRef: (shape: Shape, faces: Set<Int>)] = [:]
    /// Live undo state for the toolbar (`UndoManager` itself isn't observable).
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            undoState = UndoStateObserver(undoManager: undoManager)
            undoState?.onChange = { [weak self] undo, redo in
                self?.canUndo = undo
                self?.canRedo = redo
            }
            canUndo = undoState?.canUndo ?? false
            canRedo = undoState?.canRedo ?? false
        }
    }
    @ObservationIgnored private var undoState: UndoStateObserver?
    /// Writes changes back to the file document (marks it dirty, triggers autosave).
    @ObservationIgnored var onDocumentChange: ((Document) -> Void)?

    @ObservationIgnored private let evaluator = ModelEvaluator()
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRecompute = false

    init(document: Document) {
        self.document = document
        self.model = EvaluatedModel(parameters: document.parameterTable)
        recompute()
    }

    // MARK: Document changes

    /// Applies a change as one undoable step.
    func perform(_ actionName: String, _ change: (inout Document) -> Void) {
        let before = document
        var changed = document
        change(&changed)
        // Visibility isn't a step: an agent's change made from an older copy may differ only there.
        let after = keepingVisibility(changed)
        guard after != before else { return }
        setDocument(after)
        registerUndo(from: before, to: after, actionName: actionName)
    }

    /// Replaces the document when the file changed underneath (e.g. revert).
    func externalUpdate(_ newDocument: Document) {
        guard newDocument != document else { return }
        document = newDocument
        recompute()
    }

    private func setDocument(_ newDocument: Document) {
        document = keepingVisibility(newDocument)
        // An error is about the last action; the next edit moves on from it.
        if message?.kind == .error, message?.failedFeature == nil { message = nil }
        onDocumentChange?(document)
        recompute()
    }

    /// `newDocument` with today's hidden bodies. Visibility isn't an undo step, so a snapshot coming
    /// back (undo, redo, cancel, an agent's change made from an older copy) mustn't undo a toggle
    /// made since; only bodies whose step the snapshot brings back take the snapshot's visibility.
    private func keepingVisibility(_ newDocument: Document) -> Document {
        var doc = newDocument
        let returning = newDocument.hiddenBodies.filter { !document.hasStep(for: $0) }
        doc.hiddenBodies = document.hiddenBodies.union(returning)
        doc.pruneHiddenBodies()
        return doc
    }

    private func registerUndo(from before: Document, to after: Document, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                // Undo inside sketch mode stays in the sketch; anything else leaves edit mode.
                let keepSketch = session.sketchEditor.map { before.feature($0.sketch) != nil } ?? false
                if !keepSketch { session.cancelEditSilently() }
                session.setDocument(before)
                if keepSketch { session.editing?.snapshot = before }
                session.registerUndo(from: after, to: before, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        undoState?.refresh()
    }

    // MARK: Feature editing

    /// Adds a feature at the rollback marker and opens it for editing.
    func beginNewFeature(_ feature: Feature) {
        commitEdit()
        let snapshot = document
        var doc = document
        _ = doc.addFeature(feature)
        editing = FeatureEdit(feature: feature.id, isNew: true, snapshot: snapshot)
        setDocument(doc)
    }

    /// Opens an existing feature in the inspector.
    func beginEdit(_ id: UUID) {
        guard editing?.feature != id, document.feature(id) != nil else { return }
        commitEdit()
        editing = FeatureEdit(feature: id, isNew: false, snapshot: document)
        if case .sketch = document.feature(id)?.kind { enterSketch(id) }
        // Picks map onto the bodies just before this step; the evaluator returns those for the
        // step being edited (cached, so nothing is recomputed).
        recompute()
    }

    /// Live update of the feature being edited (no undo step until commit).
    func updateEditing(_ change: (inout Feature) -> Void) {
        guard let edit = editing, let i = document.index(of: edit.feature) else { return }
        var doc = document
        change(&doc.features[i])
        guard doc != document else { return }
        setDocument(doc)
    }

    var editingFeature: Feature? { editing.flatMap { document.feature($0.feature) } }

    func commitEdit() {
        // Whatever starts next (a feature, a sketch, editing a step) replaces choosing a plane.
        choosingSketchPlane = false
        pendingSketchTool = nil
        measure = nil
        guard let edit = editing else { return }
        editing = nil
        sketchEditor = nil
        // Showing or hiding a body while the step was open isn't a change to it.
        guard document != keepingVisibility(edit.snapshot) else { return }
        let name = document.feature(edit.feature)?.name ?? "Edit"
        registerUndo(from: edit.snapshot, to: document, actionName: edit.isNew ? "New \(name)" : "Edit \(name)")
    }

    func cancelEdit() {
        guard let edit = editing else { return }
        editing = nil
        sketchEditor = nil
        setDocument(edit.snapshot)
    }

    private func cancelEditSilently() {
        editing = nil
        sketchEditor = nil
    }

    // MARK: Sketch mode

    func enterSketch(_ id: UUID) {
        sketchEditor = SketchEditor(sketch: id)
        selection = []
        hover = nil  // the plane or face picked to sketch on
    }

    /// Creates a sketch on a plane and enters sketch mode.
    func newSketch(on plane: SketchPlaneRef) {
        let tool = pendingSketchTool
        commitEdit()
        let feature = Feature(name: nextName("Sketch"), .sketch(Sketch(plane: plane)))
        perform("New Sketch") { _ = $0.addFeature(feature) }
        editing = FeatureEdit(feature: feature.id, isNew: false, snapshot: document)
        enterSketch(feature.id)
        if let tool { sketchEditor?.engine.setTool(tool) }
    }

    // MARK: Recompute

    /// A recompute is running or queued, so `model` may not match `document` yet.
    var isRecomputePending: Bool { recomputeTask != nil || pendingRecompute }

    func recompute() {
        pendingRecompute = true
        guard recomputeTask == nil else { return }
        recomputeTask = Task { [weak self] in
            while let self, self.pendingRecompute {
                self.pendingRecompute = false
                self.isRecomputing = true
                let doc = self.document
                let result = await self.evaluator.evaluate(doc, before: self.editing?.feature)
                let previousBodies = self.model.bodies.count
                let previousStatus = self.model.status
                self.model = result
                self.measure?.dropStale(in: result)
                self.reframeAfterRecompute(previousBodyCount: previousBodies)
                self.announceFailures(previous: previousStatus)
            }
            self?.isRecomputing = false
            self?.recomputeTask = nil
        }
    }

    /// Evaluates a candidate document (an agent's step, checked before it is made) on this
    /// window's evaluator without showing it. Its steps stay cached, so committing it doesn't
    /// recompute them, and the window's own cached steps survive when it is refused.
    func preview(_ candidate: Document, before: UUID? = nil) async -> EvaluatedModel {
        await evaluator.preview(candidate, before: before)
    }

    // MARK: Failures

    /// Steps that failed in the latest recompute, in timeline order.
    var failedFeatures: [(feature: Feature, reason: String)] {
        document.features.compactMap { f in model.error(for: f.id).map { (f, $0) } }
    }

    /// A step that stopped working after a change gets a banner until it works again (the step
    /// being edited already shows its error in the inspector).
    private func announceFailures(previous: [UUID: FeatureStatus]) {
        if let id = message?.failedFeature, model.error(for: id) == nil { message = nil }
        let fresh = failedFeatures.filter { f in
            guard f.feature.id != editing?.feature else { return false }
            if case .failed = previous[f.feature.id] { return false }
            return true
        }
        guard let first = fresh.first else { return }
        let others = failedFeatures.count - 1
        let more = others > 0 ? " (\(others) more \(others == 1 ? "step" : "steps") failed)" : ""
        message = ToastMessage("\(first.feature.name) failed: \(first.reason)\(more)", kind: .error,
                               action: .showFeature(first.feature.id))
    }

    /// Runs a banner's button.
    func run(_ action: ToastMessage.Action) {
        switch action {
        case .showFeature(let id):
            guard let feature = document.feature(id) else { return }
            message = nil  // the inspector takes over showing the error
            if case .sketch = feature.kind { editSketch(id) } else { beginEdit(id) }
        case .drawWithFinger:
            break  // handled by the editor, which owns the setting
        }
    }

    // MARK: Helpers

    /// "Extrude 3" style name unique within the document.
    func nextName(_ base: String) -> String {
        let names = Set(document.features.map(\.name))
        var n = 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    var selectedBodies: [BodyRef] {
        var result: [BodyRef] = []
        for s in selection {
            switch s {
            case .body(let b), .face(let b, _), .edge(let b, _):
                if !result.contains(b) { result.append(b) }
            default: break
            }
        }
        return result
    }

    var selectedEdges: [(BodyRef, Int)] {
        selection.compactMap { if case .edge(let b, let i) = $0 { (b, i) } else { nil } }
    }

    var selectedFaces: [(BodyRef, Int)] {
        selection.compactMap { if case .face(let b, let i) = $0 { (b, i) } else { nil } }
    }

    func toggleSelection(_ s: Selection, additive: Bool) {
        if let i = selection.firstIndex(of: s) {
            selection.remove(at: i)
        } else if additive {
            selection.append(s)
        } else {
            selection = [s]
        }
    }
}
