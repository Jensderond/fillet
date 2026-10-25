import SwiftUI

/// When everything in the launch splash happens. Every value is a pure function
/// of time, so any frame can be rendered on its own (see `SplashFrameExporter`).
///
/// The story, in 2.63 s: a beat of blank paper, then graph paper rules
/// itself, a pen plotter draws a sharp block, a fillet runs along its
/// top-front edge, the wordmark settles, and the whole sheet lifts away to
/// the app.
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
    static let duration = 2.63

    /// Blank paper before anything draws, so the drawing starts once the
    /// launch has settled rather than mid-transition.
    static let lead = 0.15

    /// Grid lines draw outward from the drawing's centre lines. Each line takes
    /// `grid.duration`; lines further out start up to `gridSpread` later.
    static let grid = Beat(start: lead, duration: 0.49, curve: Theme.Motion.Curve.easeOut)
    static let gridSpread = 0.22

    /// The pen traces the block's visible outline (two pens, one per loop).
    static let outline = Beat(start: lead + 0.11, duration: 0.65, curve: Theme.Motion.Curve.drawer)
    /// …then the sharp top-front edge, the one about to be filleted.
    static let crease = Beat(start: lead + 0.49, duration: 0.32, curve: Theme.Motion.Curve.drawer)
    /// Hidden edges come in dashed, traced outward from the hidden corner.
    static let hidden = Beat(start: lead + 0.38, duration: 0.49, curve: Theme.Motion.Curve.easeOut)

    /// The hero: a fillet runs along the edge like a tool pass. Each
    /// cross-section rounds over on its own spring; the pass reaches the far
    /// end `filletTravel` after it starts at the near end (constant feed, so
    /// linear in x).
    static let filletStart = lead + 0.84
    static let filletTravel = 0.37
    static let filletSpring = Spring(duration: 0.45, bounce: 0.3)

    /// The wordmark settles in under the drawing.
    static let wordmark = Beat(start: lead + 1.17, duration: 0.45, curve: Theme.Motion.Curve.easeOut)

    /// The sheet lifts away to the app: faster than anything that came in.
    static let exit = Beat(start: lead + 2.07, duration: 0.41, curve: Theme.Motion.Curve.easeOut)

    /// The settled, fully drawn frame, held about 0.4 s before the exit so it
    /// can be read. Reduce Motion shows only this.
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
