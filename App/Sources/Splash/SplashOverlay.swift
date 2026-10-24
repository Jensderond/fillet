import SwiftUI

/// The launch splash, laid over the first editor window of each launch.
///
/// Driven by the clock: a `TimelineView` feeds elapsed time into the pure
/// `SplashArtwork(progress:)`. It never blocks the editor: the overlay takes
/// no hits, so the editor underneath is live, and any tap, click, scroll or
/// key press (which still reaches the editor) fades the sheet out in 0.15 s
/// from wherever it is. With Reduce Motion it shows the finished drawing,
/// still, and crossfades to the editor.
struct SplashOverlay: View {
    /// Called once the splash has fully faded, so the owner can remove it.
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var skippedAt: Date?

    var body: some View {
        SwiftUI.TimelineView(.animation) { timeline in
            let now = timeline.date
            let elapsed = start.map { now.timeIntervalSince($0) } ?? 0
            let skipped = skippedAt.map { SplashTimeline.skip.value(at: now.timeIntervalSince($0)) } ?? 0
            if reduceMotion {
                SplashArtwork(progress: SplashTimeline.restingTime / SplashTimeline.duration)
                    .opacity((1 - SplashTimeline.reducedFade.value(at: elapsed)) * (1 - skipped))
            } else {
                SplashArtwork(progress: min(elapsed / SplashTimeline.duration, 1))
                    .opacity(1 - skipped)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAnyInput(perform: skip)
        .onAppear { start = .now }
        .task(id: skippedAt) {
            // Remove the overlay when the current ending (natural, reduced or skipped) has played.
            let end: Date
            if let skippedAt {
                end = skippedAt.addingTimeInterval(SplashTimeline.skip.end)
            } else {
                end = (start ?? .now).addingTimeInterval(reduceMotion ? SplashTimeline.reducedFade.end : SplashTimeline.duration)
            }
            try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    private func skip() {
        if skippedAt == nil { skippedAt = .now }
    }
}

/// Shows the splash once per launch, never under the debug automation harness.
@MainActor
enum SplashGate {
    private static var claimed = false

    /// True for the first editor window of this launch only.
    static func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        if environment["FILLET_SPLASH_FRAMES"] != nil {
            SplashFrameExporter.exportToTemporaryDirectory()
        }
        #endif
        // Automation window snapshots must stay clean.
        return environment["FILLET_AUTOMATION"] == nil
    }
}
