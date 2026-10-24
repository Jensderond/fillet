import SwiftUI

/// When everything in the launch splash happens. Every value is a pure function
/// of time, so any frame can be rendered on its own (see `SplashFrameExporter`).
///
/// The story, in 1.6 s: graph paper rules itself, a pen plotter draws a sharp
/// block, a fillet runs along its top-front edge, the wordmark settles, and
/// the whole sheet lifts away to the editor.
enum SplashTimeline {
    /// One beat: a start, a duration and the curve it eases along.
    struct Beat {
        let start: Double
        let duration: Double
        let curve: UnitCurve

        var end: Double { start + duration }

        /// Eased progress, 0 before the beat and 1 after it.
        func value(at time: Double) -> Double {
            curve.value(at: min(max((time - start) / duration, 0), 1))
        }
    }

    /// Full length, exit included.
    static let duration = 1.6

    /// Grid lines draw outward from the drawing's centre lines. Each line takes
    /// `grid.duration`; lines further out start up to `gridSpread` later.
    static let grid = Beat(start: 0, duration: 0.34, curve: Theme.Motion.Curve.easeOut)
    static let gridSpread = 0.14

    /// The pen traces the block's visible outline (two pens, one per loop).
    static let outline = Beat(start: 0.08, duration: 0.46, curve: Theme.Motion.Curve.drawer)
    /// …then the sharp top-front edge, the one about to be filleted.
    static let crease = Beat(start: 0.3, duration: 0.24, curve: Theme.Motion.Curve.drawer)
    /// Hidden edges come in dashed, traced outward from the hidden corner.
    static let hidden = Beat(start: 0.26, duration: 0.36, curve: Theme.Motion.Curve.easeOut)

    /// The hero: a fillet runs along the edge like a tool pass. Each
    /// cross-section rounds over on its own spring; the pass reaches the far
    /// end `filletTravel` after it starts at the near end (constant feed, so
    /// linear in x).
    static let filletStart = 0.54
    static let filletTravel = 0.26
    static let filletSpring = Spring(duration: 0.36, bounce: 0.3)

    /// The wordmark settles in under the drawing.
    static let wordmark = Beat(start: 0.86, duration: 0.36, curve: Theme.Motion.Curve.easeOut)

    /// The sheet lifts away to the editor: faster than anything that came in.
    static let exit = Beat(start: 1.34, duration: 0.26, curve: Theme.Motion.Curve.easeOut)

    /// The settled, fully drawn frame, held before the exit. Reduce Motion shows only this.
    static let restingTime = exit.start

    // MARK: Skip and Reduce Motion

    /// A tap, click or key press fades the sheet out from wherever it is.
    static let skip = Beat(start: 0, duration: 0.15, curve: Theme.Motion.Curve.easeOut)
    /// Reduce Motion: the resting frame, held, then a crossfade. No drawing, no movement.
    static let reducedHold = 0.5
    static let reducedFade = Beat(start: reducedHold, duration: 0.4, curve: Theme.Motion.Curve.easeOut)

    // MARK: Derived values

    /// Fillet radius of section `i` (of `SplashBlock.sections + 1`), as a
    /// fraction of the final radius. Overshoots slightly on the spring.
    static func filletRadius(section i: Int, at time: Double) -> Double {
        let delay = filletTravel * Double(i) / Double(SplashBlock.sections)
        let t = time - filletStart - delay
        guard t > 0 else { return 0 }
        return filletSpring.value(target: 1.0, time: t)
    }
}
