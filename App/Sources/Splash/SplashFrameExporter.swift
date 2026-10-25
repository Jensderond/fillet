#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only: renders splash frames offscreen with `ImageRenderer`, so the
/// motion can be reviewed frame by frame without screen recording.
///
/// Launch with `FILLET_SPLASH_FRAMES=1` and the first editor window writes
/// PNGs for a sweep of `progress` values (light and dark, iPad and Mac sizes)
/// plus `frames.png`, a contact sheet, to `$TMPDIR/fillet-splash/` (inside the
/// sandbox container; the path is printed). Combine with `FILLET_AUTOMATION=1`
/// to get a window without clicking:
///
///     FILLET_AUTOMATION=1 FILLET_SPLASH_FRAMES=1 \
///       build/dd/Build/Products/Debug/Fillet.app/Contents/MacOS/Fillet
///     cp ~/Library/Containers/app.fillet.Fillet/Data/tmp/fillet-splash/frames.png docs/splash/
@MainActor
enum SplashFrameExporter {
    /// The sweep: every 0.05 of progress (about 0.13 s).
    static let sweep: [Double] = (0...20).map { Double($0) / 20 }
    /// Extra frames through the hero, in seconds: the pass and its spring.
    static let heroTimes: [Double] = [1.01, 1.08, 1.14, 1.21, 1.27, 1.34, 1.4, 1.49, 1.6, 1.73]

    static let iPadLandscape = CGSize(width: 1366, height: 1024)
    static let iPadPortrait = CGSize(width: 1024, height: 1366)
    static let macSmall = CGSize(width: 900, height: 548)
    static let macLarge = CGSize(width: 1728, height: 1050)

    private static var exported = false

    /// Exports once per launch, when `FILLET_SPLASH_FRAMES` is set.
    static func exportIfRequested() {
        guard !exported, ProcessInfo.processInfo.environment["FILLET_SPLASH_FRAMES"] != nil else { return }
        exported = true
        exportToTemporaryDirectory()
    }

    static func exportToTemporaryDirectory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fillet-splash", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        export(to: directory)
        print("[splash] frames: \(directory.path)")
    }

    static func export(to directory: URL) {
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        func render(_ progress: Double, _ size: CGSize, _ scheme: ColorScheme, _ name: String) -> CGImage? {
            let image = frame(progress: progress, size: size, colorScheme: scheme)
            if let image { write(image, to: frames.appendingPathComponent(name + ".png")) }
            return image
        }
        func label(_ progress: Double) -> String {
            String(format: "t %.2f · %.2f s", progress, progress * SplashTimeline.duration)
        }

        var sweep: [(String, CGImage)] = []
        for p in Self.sweep {
            if let image = render(p, iPadLandscape, .light, String(format: "light-%.2f", p)) { sweep.append((label(p), image)) }
        }
        var hero: [(String, CGImage)] = []
        for s in heroTimes {
            let p = s / SplashTimeline.duration
            if let image = render(p, iPadLandscape, .light, String(format: "hero-%.2fs", s)) { hero.append((label(p), image)) }
        }
        var dark: [(String, CGImage)] = []
        for p in [0.1, 0.25, 0.4, 0.5, 0.65, 0.83, 0.9] {
            if let image = render(p, iPadLandscape, .dark, String(format: "dark-%.2f", p)) { dark.append((label(p), image)) }
        }
        let rest = SplashTimeline.restingTime / SplashTimeline.duration
        var sizes: [(String, CGImage)] = []
        for (name, size) in [("iPad portrait", iPadPortrait), ("Mac 900×548", macSmall), ("Mac full screen", macLarge)] {
            for scheme in [ColorScheme.light, .dark] {
                let file = "\(name)-\(scheme == .dark ? "dark" : "light")".replacingOccurrences(of: " ", with: "-")
                if let image = render(rest, size, scheme, file) { sizes.append(("\(name) · \(scheme == .dark ? "dark" : "light")", image)) }
            }
        }

        let sheet = ContactSheet(sections: [
            ("Light, every 0.05 of progress (iPad landscape)", sweep),
            ("The hero: the fillet pass and its spring", hero),
            ("Dark", dark),
            ("Resting frame at other sizes", sizes),
        ])
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        if let image = renderer.cgImage { write(image, to: directory.appendingPathComponent("frames.png")) }
    }

    /// One frame over the editor's chrome colour, so the exit reads as a reveal.
    static func frame(progress: Double, size: CGSize, colorScheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: SplashArtwork(progress: progress)
            .frame(width: size.width, height: size.height)
            .background(Theme.chrome)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = 1
        return renderer.cgImage
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Thumbnails in labelled rows.
private struct ContactSheet: View {
    let sections: [(String, [(String, CGImage)])]
    private let thumbWidth: CGFloat = 300
    private let columns = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Fillet launch splash · \(String(format: "%.1f", SplashTimeline.duration)) s")
                .font(.system(size: 26, weight: .semibold))
            ForEach(sections.indices, id: \.self) { s in
                let (title, frames) = sections[s]
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(Theme.condensed(17, .semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                        ForEach(0..<((frames.count + columns - 1) / columns), id: \.self) { row in
                            GridRow {
                                ForEach(row * columns..<min(frames.count, (row + 1) * columns), id: \.self) { i in
                                    thumbnail(frames[i])
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(32)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func thumbnail(_ frame: (String, CGImage)) -> some View {
        let aspect = CGFloat(frame.1.height) / CGFloat(frame.1.width)
        let width = aspect > 1 ? thumbWidth * 0.75 : thumbWidth
        return VStack(alignment: .leading, spacing: 5) {
            Image(decorative: frame.1, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width * aspect)
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
            Text(frame.0).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
#endif
