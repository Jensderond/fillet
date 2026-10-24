import Foundation

/// Whether an `UndoManager` can undo or redo, kept current from its notifications.
///
/// `UndoManager` isn't observable, so a toolbar that reads `canUndo` directly is only
/// re-evaluated by accident. This posts a change whenever a group closes or an undo or
/// redo runs, which is exactly when the answer can change.
@MainActor
public final class UndoStateObserver {
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Called with the new state whenever it changes.
    public var onChange: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)?
    public private(set) weak var undoManager: UndoManager?

    private let observers = ObserverTokens()

    public init(undoManager: UndoManager?) {
        self.undoManager = undoManager
        guard let undoManager else { return }
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerCheckpoint, .NSUndoManagerWillCloseUndoGroup,
        ]
        for name in names {
            observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// Re-reads the undo manager (also after registering an action directly).
    public func refresh() {
        let undo = undoManager?.canUndo ?? false
        let redo = undoManager?.canRedo ?? false
        guard undo != canUndo || redo != canRedo else { return }
        canUndo = undo
        canRedo = redo
        onChange?(undo, redo)
    }
}

/// Notification tokens, removed when the observer goes away. Only touched on the main
/// actor (and in `deinit`, when nothing else can reach it).
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
