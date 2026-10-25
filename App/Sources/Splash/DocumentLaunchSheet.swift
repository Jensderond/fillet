#if os(iOS)
import SwiftUI

/// The iPad document browser's launch scene, dressed as the splash: the
/// icon's engineering paper behind the system's title card, and the icon's
/// filleted block drawn on the card above the title, as the splash draws it
/// above the wordmark. At launch the splash plays over it and lifts away onto
/// the same paper.
///
/// `layer` picks the half: the scene draws its background accessory under the
/// title card and its overlay accessory over the card (and over the title and
/// button too, so the block has to stay clear of them).
struct DocumentLaunchSheet: View {
    enum Layer { case paper, block }

    let layer: Layer
    let geometry: DocumentLaunchGeometryProxy

    @Environment(\.colorScheme) private var colorScheme

    /// Long after every beat has played and every section's spring has
    /// settled (the splash's resting frame still carries a little overshoot).
    private static let settledTime = 10.0

    var body: some View {
        Canvas { context, size in
            let renderer = SplashRenderer(time: Self.settledTime, layout: layout(in: size), isDark: colorScheme == .dark)
            switch layer {
            case .paper:
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper))
                renderer.drawGrid(in: context)
            case .block:
                renderer.drawBlock(in: context)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The block centred in the band between the card's top and the title.
    /// The card runs on under the browser sheet, which covers the lower half
    /// of the screen in either orientation; the system centres the title and
    /// button (~180 pt together) in the part of the card above it. The grid
    /// rules from the same centre, so a major line runs through the drawing.
    private func layout(in size: CGSize) -> SplashLayout {
        let card = geometry.titleViewFrame
        let titleTop = (card.minY + geometry.frame.midY) / 2 - 88
        let room = max(titleTop - card.minY, 0)
        let band = room * 0.66
        let width = min(band / SplashBlock.aspect(), card.width * 0.4, 240)
        let center = CGPoint(x: card.midX.rounded(), y: (card.minY + room * 0.14 + band / 2).rounded())
        return SplashLayout(size: size, drawingWidth: width, drawingCenter: center)
    }
}
#endif
