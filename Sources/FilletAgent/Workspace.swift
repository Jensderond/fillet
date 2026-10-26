import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// One open design an agent works on: the app's document window (live, the user watches)
/// or an in-memory document (headless).
@MainActor
public protocol DesignWorkspace: AnyObject {
    /// Stable for the life of the workspace.
    var id: UUID { get }
    /// Window or file title.
    var title: String { get }
    var document: Document { get }
    /// Bodies hidden in the view (renders hide them too).
    var hiddenBodies: Set<BodyRef> { get }
    /// The current view of the design (live: the user's camera).
    var camera: Camera { get }
    /// Width / height of the view, for framing.
    var viewAspect: Double { get }

    /// The model for the current document, waiting for a running recompute.
    func evaluated() async -> EvaluatedModel
    /// Evaluates a candidate document without changing anything (to check a change first).
    /// With `before`, the model's `bodiesBefore` holds the bodies just before that step.
    func preview(_ candidate: Document, before: UUID?) async -> EvaluatedModel
    /// Replaces the document as one undoable step named `action` and returns the recomputed model.
    /// Must write the document before its first suspension (``Change`` relies on that).
    func commit(_ newDocument: Document, action: String) async -> EvaluatedModel
    /// What `undo()` would take back, nil when there is nothing to undo. In the app, an edit the
    /// user has open in the inspector is made a step of its own first, so this is exactly it.
    func nextUndo() -> HistoryStep?
    /// The action name of what `redo()` would bring back.
    func nextRedo() -> String?
    /// Undoes the last step; returns its name, or nil when there is nothing to undo.
    func undo() async -> String?
    func redo() async -> String?
    /// Moves the view (live: animates the user's camera).
    func show(_ camera: Camera)
}

/// One change in a design's undo history.
public struct HistoryStep: Sendable, Equatable {
    /// Its undo action name: "New Hat", "Edit Hat", "Set width", "Delete Hat"…
    public var action: String
    /// Made by an agent through these tools, not by the user (headless: always).
    public var byAgent: Bool

    public init(action: String, byAgent: Bool) {
        self.action = action
        self.byAgent = byAgent
    }
}

/// Where workspaces come from: the app's open windows, or the headless process.
@MainActor
public protocol WorkspaceHost: AnyObject {
    /// Shown to the agent: what it is connected to.
    var hostDescription: String { get }
    var workspaces: [any DesignWorkspace] { get }
    /// The design tools act on.
    var current: (any DesignWorkspace)? { get }
    func select(_ id: UUID) -> Bool
    /// Opens a new, empty design and makes it current, or returns nil when this host can only
    /// replace the current design (an iPad window).
    func openNewDesign() async throws -> (any DesignWorkspace)?
    /// Called around every tool call so the host can show what the agent is doing (nil when done).
    func agentActivity(_ text: String?)
}

extension DesignWorkspace {
    func preview(_ candidate: Document) async -> EvaluatedModel { await preview(candidate, before: nil) }
}

extension WorkspaceHost {
    func requireCurrent() throws -> any DesignWorkspace {
        guard let ws = current else {
            throw ToolError("No design is open. Open or create a design in Fillet first, or call new_design.")
        }
        return ws
    }
}

// MARK: - Headless

/// An in-memory design with its own recompute and undo history; optionally saved to a
/// `.fillet` file after every change.
@MainActor
public final class HeadlessWorkspace: DesignWorkspace {
    public let id = UUID()
    public private(set) var document: Document
    /// Saved after every change when set.
    public var fileURL: URL?
    public var hiddenBodies: Set<BodyRef> = []
    public private(set) var camera = Camera()
    public let viewAspect = 4.0 / 3.0

    private let evaluator = ModelEvaluator()
    private var model: (document: Document, model: EvaluatedModel)?
    private var undoStack: [(document: Document, action: String)] = []
    private var redoStack: [(document: Document, action: String)] = []

    public init(document: Document = Document(), fileURL: URL? = nil) {
        self.document = document
        self.fileURL = fileURL
    }

    /// Opens a `.fillet` file (a missing file starts an empty design saved there).
    public convenience init(fileURL: URL) throws {
        let doc = FileManager.default.fileExists(atPath: fileURL.path)
            ? try Document(data: Data(contentsOf: fileURL))
            : Document(name: fileURL.deletingPathExtension().lastPathComponent)
        self.init(document: doc, fileURL: fileURL)
    }

    public var title: String { fileURL?.lastPathComponent ?? document.name ?? "Untitled" }

    public func evaluated() async -> EvaluatedModel {
        if let model, model.document == document { return model.model }
        let doc = document
        let result = await evaluator.evaluate(doc)
        model = (doc, result)
        return result
    }

    public func preview(_ candidate: Document, before: UUID?) async -> EvaluatedModel {
        await evaluator.preview(candidate, before: before)
    }

    public func commit(_ newDocument: Document, action: String) async -> EvaluatedModel {
        guard newDocument != document else { return await evaluated() }
        undoStack.append((document, action))
        redoStack = []
        document = newDocument
        save()
        return await evaluated()
    }

    public func nextUndo() -> HistoryStep? { undoStack.last.map { HistoryStep(action: $0.action, byAgent: true) } }
    public func nextRedo() -> String? { redoStack.last?.action }

    public func undo() async -> String? {
        guard let last = undoStack.popLast() else { return nil }
        redoStack.append((document, last.action))
        document = last.document
        save()
        return last.action
    }

    public func redo() async -> String? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append((document, next.action))
        document = next.document
        save()
        return next.action
    }

    public func show(_ camera: Camera) { self.camera = camera }

    /// Replaces the design wholesale (open another file), without undo.
    public func load(_ doc: Document, fileURL: URL?) {
        document = doc
        self.fileURL = fileURL
        undoStack = []
        redoStack = []
        model = nil
        camera = Camera()
    }

    /// Error from the last save, if it failed.
    public private(set) var saveError: String?

    private func save() {
        guard let fileURL else { return }
        do {
            try document.encoded().write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A host with one headless workspace (the `fillet-mcp` command).
@MainActor
public final class HeadlessHost: WorkspaceHost {
    public let workspace: HeadlessWorkspace

    public init(workspace: HeadlessWorkspace) { self.workspace = workspace }

    public var hostDescription: String {
        "Headless Fillet (no window)" + (workspace.fileURL.map { ", saving to \($0.path)" } ?? ", in memory")
    }
    public var workspaces: [any DesignWorkspace] { [workspace] }
    public var current: (any DesignWorkspace)? { workspace }
    public func select(_ id: UUID) -> Bool { id == workspace.id }
    public func openNewDesign() async throws -> (any DesignWorkspace)? { nil }
    public func agentActivity(_ text: String?) {}
}
