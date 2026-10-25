import FilletCore
import FilletViewport
import Foundation

/// Typing sizes while drawing, as in Fusion: with a shape in progress, Tab opens its first size
/// on the canvas (or a digit starts it), Tab locks what was typed and moves to the next size,
/// Return locks it and places the point, Delete edits or unlocks, Escape stops typing. Locked
/// sizes hold while the pointer still picks the free ones and the direction.
extension DesignSession {
    /// True while a size is being typed, so bare-letter tool shortcuts stay out of its way.
    var isTypingDimension: Bool { sketchEditor?.typing != nil }

    func handleDimensionKey(_ key: ViewportKey) -> Bool {
        guard var editor = sketchEditor else { return false }
        let fields = editor.engine.dimensionFields()
        guard !fields.isEmpty else {
            editor.typing = nil
            sketchEditor = editor
            return false
        }
        // The first size not yet typed, or the first.
        let firstOpen = fields.firstIndex { !$0.locked } ?? 0
        defer { sketchEditor = editor }
        switch key {
        case .tab(let backward):
            guard let typing = editor.typing else {
                editor.typing = .init(field: backward ? fields.count - 1 : firstOpen)
                return true
            }
            guard lockTyped(typing, in: &editor) else { return true }
            editor.typing?.text = ""
            let step = backward ? -1 : 1
            editor.typing = .init(field: (typing.field + step + fields.count) % fields.count)
        case .returnKey:
            let wasTyping = editor.typing != nil
            if let typing = editor.typing, !lockTyped(typing, in: &editor) { return true }
            guard !editor.engine.locks.isEmpty else { return wasTyping }
            let shapes = editor.engine.placeTyped()
            // Placing a point clears the locks; still locked means a free size is still 0.
            guard editor.engine.locks.isEmpty else {
                message = "Move the pointer to set the other size, or Tab to type it."
                return true
            }
            sketchEditor = editor
            addSketchShapes(shapes)
            editor = sketchEditor ?? editor
            // A line goes on from the new point: keep typing, so "40 Tab 90 Return 25 Return" draws an L.
            if !editor.engine.dimensionKinds.isEmpty { editor.typing = .init(field: 0) }
        case .deleteBackward:
            guard var typing = editor.typing else { return false }
            if typing.text.isEmpty {
                editor.engine.unlock(typing.field)
            } else {
                typing.text.removeLast()
                editor.typing = typing
            }
        case .text(let text):
            if var typing = editor.typing {
                typing.text += text
                editor.typing = typing
            } else if text.first.map({ $0.isNumber || $0 == "." || $0 == "," }) == true {
                // A number typed straight away goes to the first open size.
                editor.typing = .init(field: firstOpen, text: text)
            } else {
                return false
            }
        }
        return true
    }

    /// Locks the typed text as the size; false (with a message) when it isn't a usable size.
    /// Nothing typed leaves the size as it is.
    private func lockTyped(_ typing: SketchEditor.DimensionTyping, in editor: inout SketchEditor) -> Bool {
        // A decimal comma reads as a point (25,5 → 25.5); parameters and units work as in the inspector.
        let source = typing.text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return true }
        let fields = editor.engine.dimensionFields()
        guard fields.indices.contains(typing.field) else { return true }
        let field = fields[typing.field]
        let evaluator = model.parameters.evaluator
        do {
            let value = field.kind == .angle ? try evaluator.angleDegrees(Expr(source)) : try evaluator.length(Expr(source))
            guard editor.engine.lock(typing.field, to: value) else {
                message = .error("\(field.title) must be more than 0.")
                return false
            }
            return true
        } catch {
            message = .error("\(field.title): \(error.message)")
            return false
        }
    }

    /// A click places the point: what was typed for it counts, as if Tab had been pressed.
    /// False when it isn't a usable size (the click is then ignored).
    func lockTypedBeforePlacing() -> Bool {
        guard var editor = sketchEditor, let typing = editor.typing, !typing.text.isEmpty else { return true }
        let ok = lockTyped(typing, in: &editor)
        if ok { editor.typing?.text = "" }
        sketchEditor = editor
        return ok
    }

    /// Escape while typing drops the text and stops typing; the typed sizes stay locked.
    func stopTypingDimension() -> Bool {
        guard sketchEditor?.typing != nil else { return false }
        sketchEditor?.typing = nil
        return true
    }
}
