import FilletKernel
import Foundation

/// Sketch Offset's state in `SketchToolEngine`, as in Fusion: pick a curve (its whole chain comes
/// along) or start with shapes selected, then the pointer sets the distance and the side, or a
/// typed distance does (negative takes the other side). A tap places the offsets.
public struct SketchOffsetTool: Sendable {
    /// The chains to offset; empty while picking.
    public internal(set) var chains: [OffsetChain] = []
    /// Shapes that were selected when the tool started, chained once the sketch is at hand.
    public internal(set) var pending: [UUID] = []
    /// The chain under the pointer while picking (previewed, so it's clear what a tap takes).
    var candidate: OffsetChain?
    /// The chain under the press, so dragging away from a curve offsets it in one stroke.
    var pressed: OffsetChain?
    /// Where the pointer sets the offset: its signed distance from the first chain (outward or
    /// to the left positive, snapped to the grid step), the nearest point there and the pointer.
    var pointer: (distance: Double, nearest: SIMD2<Double>, at: SIMD2<Double>)?
    /// The offsets at the current distance, or why there are none.
    var outcome: Result<[SketchShape], SketchError>?

    public init() {}

    /// Something is picked, or about to be.
    public var isActive: Bool { !chains.isEmpty || !pending.isEmpty }

    /// The picked shapes (shown as selected).
    public var shapes: Set<UUID> { Set(chains.flatMap(\.shapes) + pending) }

    /// Why the offset can't be placed at the current distance.
    public var failure: String? {
        if case .failure(let error)? = outcome { return error.message }
        return nil
    }

    /// The signed distance: a typed one takes the pointer's side (outward with no pointer yet).
    func distance(locked: Double?) -> Double? {
        let side: Double = (pointer?.distance ?? 1) < 0 ? -1 : 1
        if let locked { return locked * side }
        return pointer?.distance
    }

    /// Recomputes the offsets for the current distance.
    mutating func refresh(locked: Double?) {
        guard !chains.isEmpty, let d = distance(locked: locked), abs(d) > 1e-9 else {
            outcome = nil
            return
        }
        do {
            var shapes: [SketchShape] = []
            for chain in chains {
                shapes += try chain.offset(by: d).map { SketchShape(construction: chain.construction, $0) }
            }
            outcome = .success(shapes)
        } catch let error as SketchError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(SketchError("\(error)"))
        }
    }

    /// Chains the pending shapes and drops picks whose shapes are gone (an undo).
    mutating func resolve(in sketch: Sketch, using ev: Evaluator) {
        if !pending.isEmpty {
            chains = sketch.offsetChains(containing: pending, using: ev)
            pending = []
        }
        if chains.contains(where: { $0.shapes.contains { sketch.shape($0) == nil } }) {
            self = SketchOffsetTool()
        }
    }
}
