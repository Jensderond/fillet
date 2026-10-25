import SwiftUI

/// The launch splash, laid over the app as it opens (see `SplashPresenter`).
///
/// Driven by the clock: a `TimelineView` feeds elapsed time into the pure
/// `SplashArtwork(progress:)`. It never blocks the app: the overlay takes no
/// hits, so whatever is underneath is live, and the first input (which still
/// reaches the app) sets `isSkipped`, fading the sheet out in 0.15 s from
/// wherever it is. With Reduce Motion it shows the finished drawing, still,
/// and crossfades to the app.
struct SplashOverlay: View {
    /// Set on the first input: fades the sheet out from wherever it is.
    let isSkipped: Bool
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
        .onChange(of: isSkipped) { _, skipped in
            if skipped, skippedAt == nil { skippedAt = .now }
        }
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
}
