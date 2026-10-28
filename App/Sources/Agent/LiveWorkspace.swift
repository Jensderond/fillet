import FilletAgent
import FilletCore
import FilletViewport
import Foundation

/// An open document window as an agent workspace: changes go through the session (so the
/// window shows them and they undo like the user's own), recompute is the session's.
@MainActor
final class LiveWorkspace: DesignWorkspace {
    let id = UUID()
    weak var session: DesignSession?

    init(session: DesignSession) { self.session = session }

    private var s: DesignSession {
        get throws {
            guard let session else { throw ToolError("This design's window was closed") }
            return session
        }
    }

    var title: String { session?.title ?? "Closed" }
    var document: Document { session?.document ?? Document() }
    var hiddenBodies: Set<BodyRef> { session?.hiddenBodies ?? [] }
    var camera: Camera { session?.camera ?? Camera() }

    var viewAspect: Double {
        guard let size = session?.viewSize, size.height > 0 else { return 4 / 3 }
        return size.width / size.height
    }

    func evaluated() async -> EvaluatedModel {
        guard let session else { return EvaluatedModel(parameters: Document().parameterTable) }
        return await session.settledModel()
    }

    /// Checks a change on the session's own evaluator, so the recompute after `commit` is all
    /// cache hits (each step is evaluated once, not twice).
    func preview(_ candidate: Document, before: UUID?) async -> EvaluatedModel {
        guard let session else { return await ModelEvaluator().preview(candidate, before: before) }
        return await session.preview(candidate, before: before)
    }

    /// The documents agents' changes produced, with their action names: when undo would go back
    /// from one of them, the change it takes back is an agent's (the undo stack is the user's too).
    private var agentResults: Set<AgentResult> = []

    private struct AgentResult: Hashable {
        var document: Int
        var action: String
    }

    func commit(_ newDocument: Document, action: String) async -> EvaluatedModel {
        guard let session else { return await evaluated() }
        // An agent's step replaces whatever the user had open in the inspector (like starting a tool does).
        session.commitEdit()
        session.perform(action) { $0 = newDocument }
        agentResults.insert(AgentResult(document: session.document.hashValue, action: action))
        let model = await session.settledModel()
        session.keepModelInView()
        return model
    }

    func nextUndo() -> HistoryStep? {
        guard let session, let manager = session.undoManager else { return nil }
        session.commitEdit()
        guard manager.canUndo else { return nil }
        let name = manager.undoActionName.isEmpty ? "last step" : manager.undoActionName
        return HistoryStep(action: name, byAgent: agentResults.contains(AgentResult(document: session.document.hashValue, action: manager.undoActionName)))
    }

    func nextRedo() -> String? {
        guard let session, let manager = session.undoManager else { return nil }
        session.commitEdit()
        guard manager.canRedo else { return nil }
        return manager.redoActionName.isEmpty ? "last step" : manager.redoActionName
    }

    func undo() async -> String? {
        guard let session, let manager = session.undoManager, manager.canUndo else { return nil }
        session.commitEdit()
        let name = manager.undoActionName
        manager.undo()
        _ = await session.settledModel()
        return name.isEmpty ? "last step" : name
    }

    func redo() async -> String? {
        guard let session, let manager = session.undoManager, manager.canRedo else { return nil }
        session.commitEdit()
        let name = manager.redoActionName
        manager.redo()
        _ = await session.settledModel()
        return name.isEmpty ? "last step" : name
    }

    func show(_ camera: Camera) {
        session?.camera = camera
    }

    /// Through the session's eye toggles: the browser updates, and it isn't an undo step.
    func setHiddenBodies(_ hidden: Set<BodyRef>) {
        session?.hiddenBodies = hidden
    }

    func nameFile(_ name: String) async -> FileNaming {
        guard let session else { return .kept("this design's window was closed") }
        return await DocumentNaming.name(session, name)
    }
}

extension DesignSession {
    /// The model once any running recompute has caught up with the document.
    func settledModel() async -> EvaluatedModel {
        while isRecomputePending {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model
    }

    /// After an agent's step: reframe when the design grew out of the visible part of the viewport.
    func keepModelInView() {
        guard hasFramedInitialView, sketchEditor == nil, let bounds = visibleBodyBounds else { return }
        let visible = viewInsets.rect(in: viewSize).insetBy(dx: -1, dy: -1)
        if let box = camera.screenRect(of: bounds, viewSize: viewSize), visible.contains(box) { return }
        frameBodies()
    }
}
