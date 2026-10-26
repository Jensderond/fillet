import FilletCore
import FilletKernel
import Foundation

/// State of sketch mode: which sketch is open, the active drawing tool and
/// the shape selected for dimension editing.
struct SketchEditor {
    var sketch: UUID
    var engine = SketchToolEngine(tool: .line) {
        // Typing belongs to the shape in progress: a new tool, Escape or a finished shape ends it.
        didSet {
            if engine.isIdle, typing != nil { typing = nil }
            // Offset starts from shapes selected with Select (not a shape just drawn), and what it
            // has picked shows as selected.
            if engine.tool == .offset {
                let started = oldValue.tool != .offset
                if oldValue.tool == .select { engine.preselectOffset(selectedShapes) }
                if started || engine.offset.shapes != oldValue.offset.shapes { selectedShapes = engine.offset.shapes }
            }
        }
    }
    var selectedShapes: Set<UUID> = []
    /// Grid spacing in mm used for snapping (0 = off).
    var gridSize: Double = 1
    /// The drawing tool Apple Pencil's double tap returns to from Select.
    var lastDrawingTool: SketchTool = .line
    /// Shapes being dragged with the Select tool.
    var move: SketchMove?
    /// The size being typed for the shape in progress (Tab, then a number; Mac keyboard).
    var typing: DimensionTyping?

    init(sketch: UUID) { self.sketch = sketch }

    var tool: SketchTool { engine.tool }

    /// Which of the shape's sizes (`SketchToolEngine.dimensionFields`) is being typed, and the text so far.
    struct DimensionTyping: Equatable {
        var field: Int
        var text = ""
    }

    /// Pencil double tap / squeeze: Select and the last drawing tool, back and forth.
    mutating func switchPencilTool() {
        if tool == .select {
            engine.setTool(lastDrawingTool)
        } else {
            lastDrawingTool = tool
            engine.setTool(.select)
        }
    }
}
