import Foundation
import Testing
@testable import FilletCore

/// Registers its own inverse on undo, like the session does, so redo becomes possible.
@MainActor
private final class Target {
    func change(_ manager: UndoManager) {
        manager.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.change(manager) } }
    }
}

@Suite("Undo state")
@MainActor
struct UndoStateObserverTests {
    private func register(_ manager: UndoManager, _ target: Target) {
        manager.beginUndoGrouping()
        target.change(manager)
        manager.endUndoGrouping()
    }

    @Test func followsRegistrationUndoAndRedo() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let target = Target()
        let observer = UndoStateObserver(undoManager: manager)
        var changes: [(Bool, Bool)] = []
        observer.onChange = { changes.append(($0, $1)) }
        #expect(!observer.canUndo && !observer.canRedo)

        register(manager, target)
        #expect(observer.canUndo && !observer.canRedo)

        manager.undo()
        #expect(!observer.canUndo && observer.canRedo)

        manager.redo()
        #expect(observer.canUndo && !observer.canRedo)
        #expect(changes.count == 3)
    }

    @Test func reportsOnlyRealChanges() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let target = Target()
        let observer = UndoStateObserver(undoManager: manager)
        var count = 0
        observer.onChange = { _, _ in count += 1 }
        register(manager, target)
        register(manager, target)
        register(manager, target)
        #expect(count == 1)
        manager.removeAllActions()
        observer.refresh()
        #expect(!observer.canUndo && count == 2)
    }

    @Test func noManagerMeansNothingToUndo() {
        let observer = UndoStateObserver(undoManager: nil)
        observer.refresh()
        #expect(!observer.canUndo && !observer.canRedo)
    }
}
