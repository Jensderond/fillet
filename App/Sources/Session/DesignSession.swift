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
}

/// A feature being created or edited in the inspector. The feature lives in
/// the document while editing (so the viewport shows a live result); commit
/// records one undo step, cancel restores the snapshot.
struct FeatureEdit: Equatable {
    var feature: UUID
    var isNew: Bool
    var snapshot: Document
}

/// A transient banner. Errors get their own icon and colour, and longer text stays up longer.
struct ToastMessage: Equatable, ExpressibleByStringInterpolation {
    enum Kind { case info, error }
    var text: String
    var kind: Kind = .info
    /// Each post is distinct, so the same text shown twice restarts its timer.
    let id = UUID()

    init(_ text: String, kind: Kind = .info) { self.text = text; self.kind = kind }
    init(stringLiteral value: String) { self.init(value) }

    static func error(_ text: String) -> ToastMessage { ToastMessage(text, kind: .error) }

    /// Seconds on screen: at least 4, longer for long text (about 15 characters a second).
    var duration: Double { max(4, Double(text.count) / 15) }
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
    var hiddenBodies: Set<BodyRef> = []
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
    /// Shown as a transient banner (e.g. export finished / failed).
    var message: ToastMessage?

    @ObservationIgnored var undoManager: UndoManager?
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
        var after = document
        change(&after)
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
        document = newDocument
        onDocumentChange?(newDocument)
        recompute()
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
        guard let edit = editing else { return }
        editing = nil
        sketchEditor = nil
        guard document != edit.snapshot else { return }
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
    }

    /// Creates a sketch on a plane and enters sketch mode.
    func newSketch(on plane: SketchPlaneRef) {
        commitEdit()
        let feature = Feature(name: nextName("Sketch"), .sketch(Sketch(plane: plane)))
        perform("New Sketch") { _ = $0.addFeature(feature) }
        editing = FeatureEdit(feature: feature.id, isNew: false, snapshot: document)
        enterSketch(feature.id)
    }

    // MARK: Recompute

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
                self.model = result
                self.reframeAfterRecompute(previousBodyCount: previousBodies)
            }
            self?.isRecomputing = false
            self?.recomputeTask = nil
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
