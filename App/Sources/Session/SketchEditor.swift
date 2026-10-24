import FilletCore
import FilletKernel
import Foundation

/// State of sketch mode: which sketch is open, the active drawing tool and
/// the shape selected for dimension editing.
struct SketchEditor {
    var sketch: UUID
    var engine = SketchToolEngine(tool: .line)
    var selectedShapes: Set<UUID> = []
    /// Grid spacing in mm used for snapping (0 = off).
    var gridSize: Double = 1

    init(sketch: UUID) { self.sketch = sketch }

    var tool: SketchTool { engine.tool }
}
