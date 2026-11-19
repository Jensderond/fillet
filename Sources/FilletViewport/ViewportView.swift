import SwiftUI
import FilletKernel
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The 3D viewport: Metal rendering of a `ViewportScene` with CAD navigation,
/// picking, tool input and a view cube.
///
/// ```swift
/// ViewportView(scene: scene, camera: $camera, filter: [.faces, .edges], delegate: model)
/// ```
///
/// Changing `camera` from outside animates to the new camera (e.g.
/// `camera = camera.looking(at: sketchPlane)`); gestures update the binding when they end.
public struct ViewportView: View {
    private let scene: ViewportScene
    @Binding private var camera: Camera
    private let filter: PickFilter
    private let options: ViewportOptions
    private let visualStyle: Binding<VisualStyle>?
    private weak var delegate: (any ViewportDelegate)?
    @State private var controller: ViewportController
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - scene: what to draw.
    ///   - camera: the camera; external changes animate, gestures write back when they end.
    ///   - filter: what taps, hover and tool hits can pick.
    ///   - options: input/display switches.
    ///   - visualStyle: overrides `scene.visualStyle` and adds a picker for it under the view cube.
    ///   - delegate: receives taps, hover, tool strokes and handle drags.
    ///   - controller: pass your own to call `fitAll()`, `show(_:)` etc. from outside.
    public init(scene: ViewportScene, camera: Binding<Camera>, filter: PickFilter = .default,
                options: ViewportOptions = ViewportOptions(), visualStyle: Binding<VisualStyle>? = nil,
                delegate: (any ViewportDelegate)? = nil, controller: ViewportController? = nil) {
        self.scene = scene
        self._camera = camera
        self.filter = filter
        self.options = options
        self.visualStyle = visualStyle
        self.delegate = delegate
        self._controller = State(initialValue: controller ?? ViewportController())
    }

    private var appearance: ViewportAppearance {
        options.appearance ?? (colorScheme == .dark ? .dark : .light)
    }

    private var shownScene: ViewportScene {
        var s = scene
        if let visualStyle { s.visualStyle = visualStyle.wrappedValue }
        return s
    }

    public var body: some View {
        let scene = shownScene
        ZStack(alignment: .topTrailing) {
            if controller.renderer != nil {
                // Reading the camera here (not only passing its binding) makes a camera-only change
                // from outside, like framing the first body, update the view straight away.
                ViewportRepresentable(controller: controller, scene: scene, camera: $camera, requestedCamera: camera,
                                      filter: filter, options: options, delegate: delegate, appearance: appearance)
                    // One element for VoiceOver: what's modelled and picked, with the camera moves.
                    .accessibilityElement()
                    .accessibilityLabel("3D view")
                    .accessibilityValue(options.accessibilitySummary)
                    .accessibilityAddTraits(.allowsDirectInteraction)
                    .accessibilityActions {
                        Button("Fit all") { controller.fitAll() }
                        Button("Top view") { controller.show(.top) }
                        Button("Front view") { controller.show(.front) }
                        Button("Isometric view") { controller.show(.iso) }
                        Button("Home view") { controller.showHome() }
                    }
            } else {
                Rectangle().fill(.gray.opacity(0.2))
                    .overlay(Text("Metal is not available").foregroundStyle(.secondary))
            }
            if options.showsLabels {
                ViewportLabels(controller: controller, scene: scene, appearance: appearance)
                    .allowsHitTesting(false)
            }
            if let box = controller.selectionBox {
                SelectionBoxOverlay(box: box, count: controller.boxPreviewCount, appearance: appearance, viewSize: controller.viewSize)
                    .allowsHitTesting(false)
            }
            if options.showsViewCube {
                ViewCubeOverlay(controller: controller, appearance: appearance, visualStyle: visualStyle)
                    .padding(12)
            }
        }
    }
}

// MARK: - Platform view bridge

#if os(iOS) || os(visionOS)
struct ViewportRepresentable: UIViewRepresentable {
    let controller: ViewportController
    let scene: ViewportScene
    @Binding var camera: Camera
    /// The camera value this update was rendered for.
    let requestedCamera: Camera
    let filter: PickFilter
    let options: ViewportOptions
    weak var delegate: (any ViewportDelegate)?
    let appearance: ViewportAppearance

    func makeUIView(context: Context) -> ViewportUIView {
        ViewportUIView(controller: controller)
    }

    func updateUIView(_ view: ViewportUIView, context: Context) {
        controller.cameraBinding = $camera
        controller.update(scene: scene, camera: requestedCamera, filter: filter, options: options, delegate: delegate, appearance: appearance,
                          increasedContrast: context.environment.colorSchemeContrast == .increased)
    }
}
#elseif os(macOS)
struct ViewportRepresentable: NSViewRepresentable {
    let controller: ViewportController
    let scene: ViewportScene
    @Binding var camera: Camera
    /// The camera value this update was rendered for.
    let requestedCamera: Camera
    let filter: PickFilter
    let options: ViewportOptions
    weak var delegate: (any ViewportDelegate)?
    let appearance: ViewportAppearance

    func makeNSView(context: Context) -> ViewportNSView {
        ViewportNSView(controller: controller)
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        controller.cameraBinding = $camera
        controller.update(scene: scene, camera: requestedCamera, filter: filter, options: options, delegate: delegate, appearance: appearance,
                          increasedContrast: context.environment.colorSchemeContrast == .increased)
    }
}
#endif

// MARK: - Labels (measures, bed name)

struct ViewportLabels: View {
    let controller: ViewportController
    let scene: ViewportScene
    let appearance: ViewportAppearance
    @Environment(\.colorSchemeContrast) private var contrast

    /// The printer's name runs along the bed's front edge, just outside it, like a label printed
    /// on the plate's rim: never on the outline or the paper, and upright whichever way the
    /// edge slopes. Hidden when the edge is too short on screen to carry it.
    private func bedLabelPlacement(_ plate: BuildPlate, _ cam: Camera, _ size: CGSize) -> (center: CGPoint, angle: Angle)? {
        let y = plate.minXY.y, x0 = plate.minXY.x, x1 = plate.minXY.x + plate.size.x
        guard let a = cam.project(Vec3(x0, y, 0), viewSize: size), let b = cam.project(Vec3(x1, y, 0), viewSize: size),
            let outside = cam.project(Vec3((x0 + x1) / 2, y - plate.size.y * 0.1, 0), viewSize: size)
        else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
        // Room for the name plus margins (caption2 is about 6.5 pt per character).
        guard length > CGFloat(plate.name.count) * 6.5 + 32 else { return nil }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Unit normal to the edge, on the side away from the bed.
        var nx = -dy / length, ny = dx / length
        if nx * (outside.x - mid.x) + ny * (outside.y - mid.y) < 0 { nx = -nx; ny = -ny }
        let offset: CGFloat = 13  // half the text height plus a 6 pt gap from the outline
        let center = CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)
        guard center.x > -50, center.y > -20, center.x < size.width + 50, center.y < size.height + 20 else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees > 90 { degrees -= 180 } else if degrees < -90 { degrees += 180 }
        return (center, .degrees(degrees))
    }

    var body: some View {
        let cam = controller.liveCamera
        let size = controller.viewSize
        ZStack(alignment: .topLeading) {
            ForEach(scene.measures) { m in
                if let p = cam.project((m.from + m.to) * 0.5, viewSize: size) {
                    MeasureChip(label: m.label, entry: m.entry, appearance: appearance)
                        .position(x: p.x + 8, y: p.y)
                }
            }
            ForEach(scene.referencePlanes) { r in
                if let p = cam.project(r.labelAnchor, viewSize: size) {
                    ReferencePlaneLabel(text: r.label, color: appearance.palette.color(for: r).color,
                                        hovered: scene.hover == .referencePlane(r.id), appearance: appearance)
                        .position(x: p.x, y: p.y)
                }
            }
            if let plate = scene.plate, !plate.name.isEmpty, let place = bedLabelPlacement(plate, cam, size) {
                // Like lettering on a drawing, the ground's ruling breaks around the name.
                Text(plate.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(appearance.labelInk(highContrast: contrast == .increased))
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(appearance.palette.backgroundTop.color.opacity(0.9), in: Capsule())
                    .rotationEffect(place.angle)
                    .position(place.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A measure's value on the canvas. While it is typed it takes the accent outline and a caret,
/// like a field that opened on the drawing; once typed it carries a lock.
private struct MeasureChip: View {
    let label: String
    let entry: MeasureEntry
    let appearance: ViewportAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var typing: Bool { if case .typing = entry { true } else { false } }

    var body: some View {
        HStack(spacing: 3) {
            if entry == .locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(appearance.entryInk)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Text(label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(appearance.chipInk)
                // Before the first key the live value shows selected: typing replaces it.
                .background {
                    if entry == .typing(replacing: true) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(appearance.entryAccent.opacity(0.24))
                            .padding(.horizontal, -2)
                    }
                }
            if entry == .typing(replacing: false) {
                Caret(color: appearance.entryAccent, blinks: !reduceMotion)
                    .id(label)  // solid again after each key, then blinks
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, typing ? 8 : 6)  // room for the caret inside the round end
        .padding(.vertical, 2)
        .background(appearance.chipFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                typing ? appearance.entryAccent : entry == .locked ? appearance.entryAccent.opacity(0.45) : appearance.chipEdge,
                lineWidth: typing ? 1.5 : 1)
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: entry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(entry == .locked ? "Locked" : typing ? "Editing" : "")
    }
}

/// A text caret that blinks at the system's rhythm, solid when it may not blink.
private struct Caret: View {
    let color: Color
    let blinks: Bool

    var body: some View {
        let bar = RoundedRectangle(cornerRadius: 0.75).fill(color).frame(width: 1.5, height: 12)
        if blinks {
            bar.phaseAnimator([true, false]) { view, on in view.opacity(on ? 1 : 0) } animation: { _ in
                .linear(duration: 0.01).delay(0.53)
            }
        } else {
            bar
        }
    }
}

/// A reference plane's name at its far corner: a chip with a swatch in the plane's colour,
/// filled with that colour while the plane is under the pointer.
private struct ReferencePlaneLabel: View {
    let text: String
    let color: Color
    let hovered: Bool
    let appearance: ViewportAppearance

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(hovered ? appearance.chipFill : color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.weight(.semibold).width(.condensed))
                .foregroundStyle(hovered ? appearance.chipFill : appearance.chipInk)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(hovered ? color : appearance.chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(hovered ? .clear : appearance.chipEdge))
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Selection box

/// The rectangle being dragged to select, in the selection blue. A window (dragged left to right)
/// has a solid rim and takes what is wholly inside; a crossing box (right to left) a dashed rim,
/// a lighter wash, and takes whatever it touches, like Fusion. A tag on the rim says which, so the
/// convention teaches itself.
struct SelectionBoxOverlay: View {
    let box: SelectionBox
    /// What the box would take now (lit in the view); on the tag, so a box that takes nothing says so.
    let count: Int
    let appearance: ViewportAppearance
    let viewSize: CGSize

    private var window: Bool { box.mode == .window }
    private var blue: Color { appearance.palette.accent.color }

    var body: some View {
        let rect = box.rect
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(blue.opacity(window ? 0.10 : 0.06))
                .overlay(Rectangle().strokeBorder(blue, style: StrokeStyle(lineWidth: 1.5, dash: window ? [] : [6, 4])))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            anchorMarks
            tag.position(tagCenter(rect))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Crop marks at the corner the drag started from, as on a drawing sheet: they pin the box
    /// down there, so it reads which way it was dragged (and so whether it's a window or crossing).
    private var anchorMarks: some View {
        let s = box.start
        let dx: CGFloat = box.end.x >= s.x ? -1 : 1, dy: CGFloat = box.end.y >= s.y ? -1 : 1
        return Path { p in
            // Two short ticks running on from the box's edges, a little outside the corner.
            p.move(to: CGPoint(x: s.x + dx * 4, y: s.y)); p.addLine(to: CGPoint(x: s.x + dx * 12, y: s.y))
            p.move(to: CGPoint(x: s.x, y: s.y + dy * 4)); p.addLine(to: CGPoint(x: s.x, y: s.y + dy * 12))
        }
        .stroke(blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private var tag: some View {
        HStack(spacing: 4) {
            Image(systemName: window ? "rectangle.inset.filled" : "rectangle.dashed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(blue)
            Text(window ? "Inside" : "Touching")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(appearance.chipInk)
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(appearance.labelInk(highContrast: false))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(appearance.chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(appearance.chipEdge))
        .fixedSize()
        // Grows with text size up to the app's chrome limit, so it never hides what it boxes.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Above the box's top edge, at the corner the drag started from (away from the finger or
    /// pointer at the other end), kept inside the view.
    private func tagCenter(_ rect: CGRect) -> CGPoint {
        // Inward from the corner, clear of its crop marks.
        let x = window ? rect.minX + 64 : rect.maxX - 64
        let y = rect.minY > 18 ? rect.minY - 12 : rect.minY + 12
        return CGPoint(x: min(max(x, 40), max(viewSize.width - 40, 40)), y: y)
    }
}

// MARK: - View cube

extension ViewportColor {
    /// The same colour for SwiftUI drawing (view cube triad).
    var color: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a)) }
}

extension ViewportAppearance {
    // Solid chips (measure labels, cube buttons) matching the app's raised surfaces and ink,
    // rather than material, so they read the same over any geometry.
    var chipFill: Color { self == .dark ? Color(.sRGB, red: 0x21 / 255, green: 0x28 / 255, blue: 0x36 / 255) : .white }
    /// Fillet orange: the measure being typed, like the inspector's focused field.
    var entryAccent: Color { Color(.sRGB, red: 0xF2 / 255, green: 0x6B / 255, blue: 0x1D / 255) }
    /// The accent dark enough for small glyphs on a chip (the lock).
    var entryInk: Color {
        self == .dark ? Color(.sRGB, red: 0xFF / 255, green: 0x8A / 255, blue: 0x3D / 255)
            : Color(.sRGB, red: 0xC9 / 255, green: 0x4F / 255, blue: 0x0B / 255)
    }
    var chipInk: Color {
        self == .dark ? Color(.sRGB, red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xF2 / 255)
            : Color(.sRGB, red: 0x1D / 255, green: 0x2B / 255, blue: 0x45 / 255)
    }
    /// Secondary ink for text on the viewport background (the app's `inkSecondary`).
    func labelInk(highContrast: Bool) -> Color {
        let hex: UInt32 = self == .dark ? (highContrast ? 0xB8C1D0 : 0x9AA5B8) : (highContrast ? 0x48536B : 0x5A6680)
        return Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    var chipEdge: Color { self == .dark ? .white.opacity(0.11) : Color(.sRGB, red: 0x1D / 255, green: 0x2B / 255, blue: 0x45 / 255).opacity(0.11) }

    /// View-cube face fill: the app's raised surface for a face turned to the viewer, easing
    /// to the panel and chrome neutrals as it turns away (shading without grey plastic).
    func cubeFace(facing: Double) -> Color {
        let t = min(max(facing, 0), 1)
        let (near, far): ((Double, Double, Double), (Double, Double, Double)) = self == .dark
            ? ((0x2A, 0x33, 0x44), (0x1A, 0x20, 0x2C))   // raised+ … chrome
            : ((0xFF, 0xFF, 0xFF), (0xDD, 0xE3, 0xEB))   // raised … a step below chrome
        func mix(_ a: Double, _ b: Double) -> Double { (b + (a - b) * t) / 255 }
        return Color(.sRGB, red: mix(near.0, far.0), green: mix(near.1, far.1), blue: mix(near.2, far.2))
    }

    /// Cube edges in ink, like the drawing's line work.
    var cubeEdge: Color { chipInk.opacity(self == .dark ? 0.45 : 0.55) }

    /// The face under the pointer: the fillet orange wash ("this is what a click does").
    var cubeHover: Color { Color(.sRGB, red: 0xF2 / 255, green: 0x6B / 255, blue: 0x1D / 255).opacity(self == .dark ? 0.28 : 0.16) }
}

struct ViewCubeOverlay: View {
    let controller: ViewportController
    let appearance: ViewportAppearance
    var visualStyle: Binding<VisualStyle>?
    @State private var hoveringOverlay = false
    @State private var hoveringHome = false

    /// Smaller than the buttons below: a quiet corner control, as in Fusion.
    #if os(iOS) || os(visionOS)
    static let homeSide: CGFloat = 32
    #else
    static let homeSide: CGFloat = 24
    #endif
    /// How far Home reaches past the cube's frame (up and left); its other 8 pt overlap the frame's empty corner.
    static let homeInset: CGFloat = homeSide - 8

    /// On the Mac Home shows while the pointer is over the cube; touch has no hover, so it stays.
    private var showsHome: Bool {
        #if os(macOS)
        return hoveringOverlay || hoveringHome
        #else
        return true
        #endif
    }

    var body: some View {
        VStack(spacing: 8) {
            // `liveCamera` changes every animation frame, so this re-renders with the final
            // camera too, by when the renderer no longer reports an animation.
            ViewCube(camera: controller.liveCamera, appearance: appearance,
                     isAnimating: controller.renderer?.isAnimating ?? false,
                     onRegion: { controller.show(lookingFrom: $0) },
                     onHome: { controller.showHome() },
                     onRoll: { controller.roll(clockwise: $0) },
                     onOrbitBegan: { controller.beginOrbitAroundTarget() },
                     onOrbit: { controller.orbit(deltaYaw: $0, deltaPitch: $1) },
                     onOrbitEnded: { controller.endNavigation() })
                // Room above the cube for Home, always, so it appearing moves nothing.
                .padding(.top, Self.homeInset)
                // Top left of the cube, clear of it at every angle: the cube's outline stays
                // within 0.52 × size of its centre, which leaves the frame's corners free.
                .overlay(alignment: .topLeading) {
                    if showsHome {
                        CubeButton(systemName: "house", help: "Home view", appearance: appearance, size: Self.homeSide) {
                            controller.showHome()
                        }
                        .onHover { hoveringHome = $0 }
                        .offset(x: -Self.homeInset)
                        .transition(.opacity)
                    }
                }
            HStack(spacing: 6) {
                CubeButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Fit all", appearance: appearance) { controller.fitAll() }
                // Labelled by what it does; the glyph shows the projection you'd switch to.
                let perspective = controller.liveCamera.projection == .perspective
                CubeButton(systemName: perspective ? "square.grid.3x3" : "cube",
                           help: perspective ? "Switch to orthographic" : "Switch to perspective", appearance: appearance) {
                    controller.toggleProjection()
                }
                .accessibilityValue(perspective ? "Perspective" : "Orthographic")
            }
            // As wide as the two buttons above: one choice of several, so a dropdown, not a button.
            if let visualStyle {
                VisualStyleChip(style: visualStyle, appearance: appearance, width: CubeButton.side * 2 + 6, height: CubeButton.side)
            }
        }
        .onHover { hoveringOverlay = $0 }
        .animation(.easeOut(duration: 0.12), value: showsHome)
    }
}

struct CubeButton: View {
    let systemName: String
    let help: String
    let appearance: ViewportAppearance
    var size: CGFloat = CubeButton.side
    let action: () -> Void
    @State private var hovering = false

    /// 44 pt touch targets on iPad.
    #if os(iOS) || os(visionOS)
    nonisolated static let side: CGFloat = 44
    #else
    nonisolated static let side: CGFloat = 32
    #endif

    var body: some View {
        // Smaller buttons get a smaller glyph and corner, so they keep the same proportions.
        let radius = min(8, size / 4)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size < 30 ? 11 : 13, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appearance.chipInk)
        .background(appearance.chipFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(appearance.chipInk.opacity(hovering ? 0.08 : 0)).allowsHitTesting(false))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(appearance.chipEdge))
        #if os(iOS) || os(visionOS)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: radius, style: .continuous))
        .hoverEffect(.highlight)
        #endif
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small orientation cube, like Fusion's ViewCube: click a face, edge or corner to look
/// from there, drag to orbit, and when square on a face, click an arrow for the next side or
/// a curved arrow to turn the view a quarter turn.
/// Drawn with SwiftUI from the camera orientation, exactly as the camera is.
public struct ViewCube: View {
    let camera: Camera
    let appearance: ViewportAppearance
    /// The arrows hide while the camera animates: they would point from where it's passing.
    let isAnimating: Bool
    /// A click on an area: the direction to look from (components -1, 0 or 1).
    let onRegion: (Vec3) -> Void
    let onHome: () -> Void
    /// A click on a curved arrow: `true` turns the view clockwise.
    let onRoll: (Bool) -> Void
    let onOrbitBegan: () -> Void
    /// Yaw and pitch deltas in radians.
    let onOrbit: (Double, Double) -> Void
    let onOrbitEnded: () -> Void
    var size: CGFloat = ViewCube.defaultSize
    /// Where the pointer is; the area under it is worked out against the current camera.
    @State private var hoverPoint: CGPoint?
    @State private var orbiting = false
    /// Set when this press became an orbit, so its release is never taken for a click.
    @State private var orbitedThisPress = false
    @State private var lastTranslation: CGSize = .zero
    @GestureState private var pressing = false

    /// Fingers get a bigger cube rather than wider hit areas, so the areas stay where they're drawn.
    #if os(iOS) || os(visionOS)
    nonisolated static let defaultSize: CGFloat = 110
    #else
    nonisolated static let defaultSize: CGFloat = 84
    #endif

    /// Movement under this many points is a click; beyond it, a drag that orbits.
    static let clickSlop: CGFloat = 4

    public init(camera: Camera, appearance: ViewportAppearance, isAnimating: Bool = false,
                onRegion: @escaping (Vec3) -> Void, onHome: @escaping () -> Void = {},
                onRoll: @escaping (Bool) -> Void = { _ in },
                onOrbitBegan: @escaping () -> Void = {}, onOrbit: @escaping (Double, Double) -> Void = { _, _ in },
                onOrbitEnded: @escaping () -> Void = {}) {
        self.camera = camera
        self.appearance = appearance
        self.isAnimating = isAnimating
        self.onRegion = onRegion
        self.onHome = onHome
        self.onRoll = onRoll
        self.onOrbitBegan = onOrbitBegan
        self.onOrbit = onOrbit
        self.onOrbitEnded = onOrbitEnded
    }

    struct Face: Sendable {
        let normal: Vec3
        /// The face's own axes: `normal + u * axisU + v * axisV` for (u, v) in [-1, 1]² spans it.
        let axisU: Vec3
        let axisV: Vec3
        let label: String
        let view: Camera.StandardView

        var corners: [Vec3] { [normal - axisU - axisV, normal + axisU - axisV, normal + axisU + axisV, normal - axisU + axisV] }
    }

    nonisolated static let faces: [Face] = [
        Face(normal: .unitZ, axisU: .unitX, axisV: .unitY, label: "TOP", view: .top),
        Face(normal: -Vec3.unitZ, axisU: .unitX, axisV: -Vec3.unitY, label: "BOTTOM", view: .bottom),
        Face(normal: -Vec3.unitY, axisU: .unitX, axisV: .unitZ, label: "FRONT", view: .front),
        Face(normal: .unitY, axisU: -Vec3.unitX, axisV: .unitZ, label: "BACK", view: .back),
        Face(normal: .unitX, axisU: .unitY, axisV: .unitZ, label: "RIGHT", view: .right),
        Face(normal: -Vec3.unitX, axisU: -Vec3.unitY, axisV: .unitZ, label: "LEFT", view: .left),
    ]

    /// Beyond this in a face's u or v, the point is on an edge or corner area rather than the centre.
    nonisolated static let edgeSplit = 0.6

    /// Cube-space point → canvas point (orthographic, camera orientation only).
    nonisolated static func project(_ p: Vec3, camera: Camera, size: CGFloat) -> CGPoint {
        let s = Double(size) * 0.3
        return CGPoint(x: Double(size) / 2 + p.dot(camera.right) * s, y: Double(size) / 2 - p.dot(camera.up) * s)
    }

    nonisolated static func path(_ points: [Vec3], camera: Camera, size: CGFloat) -> Path {
        var path = Path()
        path.addLines(points.map { project($0, camera: camera, size: size) })
        path.closeSubpath()
        return path
    }

    /// Faces turned towards the viewer, front-most first.
    nonisolated static func visibleFaces(_ camera: Camera) -> [Face] {
        let back = camera.back
        return faces.filter { $0.normal.dot(back) > 0.02 }.sorted { $0.normal.dot(back) > $1.normal.dot(back) }
    }

    /// The face the camera looks straight at, if any.
    nonisolated static func squareFace(_ camera: Camera) -> Face? {
        faces.first { $0.normal.dot(camera.back) > 0.999 }
    }

    /// A canvas point in `face`'s own (u, v), each in [-1, 1], or nil when it misses the face.
    nonisolated static func faceCoordinates(of point: CGPoint, on face: Face, camera: Camera, size: CGFloat) -> (u: Double, v: Double)? {
        let s = Double(size) * 0.3
        let right = camera.right, up = camera.up
        // Canvas offsets of one unit along each face axis (canvas y grows downwards).
        let ax = face.axisU.dot(right) * s, ay = -face.axisU.dot(up) * s
        let bx = face.axisV.dot(right) * s, by = -face.axisV.dot(up) * s
        let det = ax * by - ay * bx
        // Edge-on, the face has no area to hit.
        guard abs(det) > 1e-6 * s * s else { return nil }
        let c = project(face.normal, camera: camera, size: size)
        let dx = Double(point.x - c.x), dy = Double(point.y - c.y)
        let u = (dx * by - dy * bx) / det
        let v = (ax * dy - ay * dx) / det
        guard abs(u) <= 1, abs(v) <= 1 else { return nil }
        return (u, v)
    }

    /// The area under a canvas point, as the direction to look from (6 face centres, 12 edges,
    /// 8 corners, components -1, 0 or 1), an arrow's face when `showsArrows`, or nil outside.
    nonisolated static func region(at point: CGPoint, camera: Camera, size: CGFloat, showsArrows: Bool) -> Vec3? {
        for face in visibleFaces(camera) {
            guard let c = faceCoordinates(of: point, on: face, camera: camera, size: size) else { continue }
            var d = face.normal
            if abs(c.u) > edgeSplit { d = d + face.axisU * (c.u > 0 ? 1 : -1) }
            if abs(c.v) > edgeSplit { d = d + face.axisV * (c.v > 0 ? 1 : -1) }
            return d
        }
        if showsArrows, let arrow = arrows(camera: camera, size: size).first(where: { $0.hitArea.contains(point) }) {
            return arrow.direction
        }
        return nil
    }

    /// The part of `face` that belongs to `region`, as cube-space corners, or nil when the region
    /// doesn't touch the face. A corner touches three faces, an edge two, a centre one.
    nonisolated static func patch(_ region: Vec3, on face: Face) -> [Vec3]? {
        guard region.dot(face.normal) > 0.5 else { return nil }
        func span(_ k: Double) -> (Double, Double) {
            k > 0.5 ? (edgeSplit, 1) : k < -0.5 ? (-1, -edgeSplit) : (-edgeSplit, edgeSplit)
        }
        let (u0, u1) = span(region.dot(face.axisU)), (v0, v1) = span(region.dot(face.axisV))
        func point(_ u: Double, _ v: Double) -> Vec3 { face.normal + face.axisU * u + face.axisV * v }
        return [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)]
    }

    /// A triangle beside the square face that turns the view to the neighbouring side.
    struct Arrow: Sendable {
        /// The face it turns to (its normal).
        let direction: Vec3
        let triangle: [CGPoint]
        /// Wider than the triangle, so it's easy to hit.
        let hitArea: CGRect
    }

    /// Left, right, up and down arrows when the camera is square on a face, else none. The square
    /// reaches 0.3 × size from the centre; the arrows sit in the band beyond it.
    nonisolated static func arrows(camera: Camera, size: CGFloat) -> [Arrow] {
        guard squareFace(camera) != nil else { return [] }
        let c = size / 2
        let base = size * 0.33, tip = size * 0.42, half = size * 0.07, reach = size * 0.15
        // Screen direction (canvas y down) and the world direction it shows.
        let sides: [(x: CGFloat, y: CGFloat, world: Vec3)] = [
            (-1, 0, -camera.right), (1, 0, camera.right), (0, -1, camera.up), (0, 1, -camera.up),
        ]
        var arrows: [Arrow] = []
        for side in sides {
            // `along` points out from the centre, `across` at right angles to it.
            func at(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                CGPoint(x: c + side.x * along - side.y * across, y: c + side.y * along + side.x * across)
            }
            var best = faces[0]
            for face in faces where face.normal.dot(side.world) > best.normal.dot(side.world) { best = face }
            let a = at(size * 0.3, -reach), b = at(size * 0.5, reach)
            arrows.append(Arrow(direction: best.normal,
                                triangle: [at(tip, 0), at(base, -half), at(base, half)],
                                hitArea: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))))
        }
        return arrows
    }

    /// A curved arrow in the frame's top-right corner, beside the square face, that turns the view
    /// a quarter turn. Clockwise is the lower one, its head pointing down; anticlockwise the upper.
    struct RollArrow: Sendable {
        let clockwise: Bool
        let outline: [CGPoint]
    }

    /// The arrows lie along an arc around the centre; angles in degrees from screen-right
    /// towards screen-up. Each one: tail, neck (where the head starts), tip.
    nonisolated private static let rollAngles: [(clockwise: Bool, tail: Double, neck: Double, tip: Double)] = [
        (true, 41, 30, 21), (false, 49, 60, 69),
    ]
    /// Their hit band: radius (× size) and angles (degrees). Beyond the square's corners
    /// (0.42 × size) and clear of the up and right triangles' hit areas.
    nonisolated static let rollHitRadius: ClosedRange<Double> = 0.44...0.7
    nonisolated static let rollHitAngles: ClosedRange<Double> = 21...69

    /// The two curved arrows when the camera is square on a face, else none. They don't depend on
    /// the roll: they turn the picture, whichever way it is turned already.
    nonisolated static func rollArrows(camera: Camera, size: CGFloat) -> [RollArrow] {
        guard squareFace(camera) != nil else { return [] }
        let s = Double(size), c = s / 2
        let mid = 0.5 * s, half = 0.026 * s, head = 0.065 * s
        func at(_ r: Double, _ degrees: Double) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: c + r * cos(a), y: c - r * sin(a))
        }
        return rollAngles.map { arrow in
            let steps = 8
            let arc = (0...steps).map { arrow.tail + (arrow.neck - arrow.tail) * Double($0) / Double(steps) }
            var outline = arc.map { at(mid + half, $0) }
            outline += [at(mid + head, arrow.neck), at(mid, arrow.tip), at(mid - head, arrow.neck)]
            outline += arc.reversed().map { at(mid - half, $0) }
            return RollArrow(clockwise: arrow.clockwise, outline: outline)
        }
    }

    /// The curved arrow under a canvas point (`true` = clockwise), or nil. Only when square on a face.
    nonisolated static func rollArrow(at point: CGPoint, camera: Camera, size: CGFloat) -> Bool? {
        guard squareFace(camera) != nil else { return nil }
        let s = Double(size)
        let dx = Double(point.x) - s / 2, dy = s / 2 - Double(point.y)
        let r = hypot(dx, dy) / s, degrees = atan2(dy, dx) * 180 / .pi
        guard rollHitRadius.contains(r), rollHitAngles.contains(degrees) else { return nil }
        return degrees < 45
    }

    /// What a click at a canvas point does: a cube area or triangle first, else a curved arrow.
    enum Target: Equatable {
        case look(Vec3)
        case roll(clockwise: Bool)
    }

    nonisolated static func target(at point: CGPoint, camera: Camera, size: CGFloat, showsArrows: Bool) -> Target? {
        if let d = region(at: point, camera: camera, size: size, showsArrows: showsArrows) { return .look(d) }
        guard showsArrows, let clockwise = rollArrow(at: point, camera: camera, size: size) else { return nil }
        return .roll(clockwise: clockwise)
    }

    /// What's under the pointer, against the camera as it is now (it may move under a still pointer).
    private var hoveredTarget: Target? {
        guard !orbiting, let p = hoverPoint else { return nil }
        return Self.target(at: p, camera: camera, size: size, showsArrows: !isAnimating)
    }

    public var body: some View {
        let cam = camera
        let look = appearance
        let hoveredTarget = hoveredTarget
        let hovered: Vec3? = if case .look(let d) = hoveredTarget { d } else { nil }
        let arrows = isAnimating ? [] : Self.arrows(camera: cam, size: size)
        let rollArrows = isAnimating ? [] : Self.rollArrows(camera: cam, size: size)
        let size = size
        // A corner pointing straight up or sideways reaches 0.52 × size from the centre, past the
        // frame: the canvas overhangs it by `bleed` so the corner isn't cut flat. Layout, hover and
        // hits stay in the `size` square.
        let bleed = (size * 0.04).rounded(.up)
        Canvas { ctx, _ in
            ctx.translateBy(x: bleed, y: bleed)
            let back = cam.back
            // Back to front, so nearer faces paint over the ones behind.
            for face in Self.visibleFaces(cam).reversed() {
                let outline = Self.path(face.corners, camera: cam, size: size)
                let facing = face.normal.dot(back)
                ctx.fill(outline, with: .color(look.cubeFace(facing: facing)))
                if let hovered, let patch = Self.patch(hovered, on: face) {
                    ctx.fill(Self.path(patch, camera: cam, size: size), with: .color(look.cubeHover))
                }
                ctx.stroke(outline, with: .color(look.cubeEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                if facing > 0.3 {
                    let c = Self.project(face.normal, camera: cam, size: size)
                    // Labels turn with a roll, so the cube shows it (canvas angles run clockwise).
                    var label = ctx
                    label.translateBy(x: c.x, y: c.y)
                    label.rotate(by: .radians(-cam.roll))
                    label.opacity = min(1, (facing - 0.3) * 2.5)
                    label.draw(Text(face.label).font(.system(size: 10, weight: .semibold).width(.condensed))
                                .foregroundStyle(look.chipInk),
                               at: .zero)
                }
            }
            for arrow in arrows {
                var p = Path()
                p.addLines(arrow.triangle)
                p.closeSubpath()
                ctx.fill(p, with: .color(look.cubeFace(facing: 1)))
                if arrow.direction == hovered { ctx.fill(p, with: .color(look.cubeHover)) }
                ctx.stroke(p, with: .color(look.cubeEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
            for arrow in rollArrows {
                var p = Path()
                p.addLines(arrow.outline)
                p.closeSubpath()
                ctx.fill(p, with: .color(look.cubeFace(facing: 1)))
                if hoveredTarget == .roll(clockwise: arrow.clockwise) { ctx.fill(p, with: .color(look.cubeHover)) }
                ctx.stroke(p, with: .color(look.cubeEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
            // Axis triad in the bottom-left corner.
            let o = CGPoint(x: 10, y: size - 10)
            let pal = look.palette
            for (axis, color) in [(Vec3.unitX, pal.axisX.color), (Vec3.unitY, pal.axisY.color), (Vec3.unitZ, pal.axisZ.color)] {
                var p = Path()
                p.move(to: o)
                p.addLine(to: CGPoint(x: o.x + axis.dot(cam.right) * 13, y: o.y - axis.dot(cam.up) * 13))
                ctx.stroke(p, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: size + 2 * bleed, height: size + 2 * bleed)
        .padding(-bleed)
        // The whole frame, arrows included: a drag here never reaches the viewport underneath.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($pressing) { _, state, _ in state = true }
                .onChanged { value in dragChanged(value) }
                .onEnded { value in dragEnded(value) }
        )
        .onChange(of: pressing) { _, now in
            // A drag the system cancels never reaches `onEnded`; still end its orbit.
            if now { orbitedThisPress = false } else if orbiting { endOrbit() }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hoverPoint = p
            case .ended: hoverPoint = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel("View cube")
        .accessibilityValue(Self.accessibilityValue(camera))
        .accessibilityActions {
            ForEach(Self.faces.sorted { Self.order($0.view) < Self.order($1.view) }, id: \.label) { face in
                Button(face.view.rawValue.capitalized) { onRegion(face.normal) }
            }
            if Self.squareFace(camera) != nil {
                Button("Roll clockwise") { onRoll(true) }
                Button("Roll anticlockwise") { onRoll(false) }
            }
            Button("Home view") { onHome() }
        }
    }

    /// Where the view looks from, and how far it's rolled: "Looking from front, turned 90° clockwise".
    nonisolated static func accessibilityValue(_ camera: Camera) -> String {
        guard let face = faces.first(where: { $0.normal.dot(camera.back) > 0.9 }) else { return "Angled view" }
        let degrees = Int((Camera.wrapAngle(camera.roll) * 180 / .pi).rounded())
        let turn = switch degrees {
        case 0: ""
        case 180, -180: ", upside down"
        case ..<0: ", turned \(-degrees)° clockwise"
        default: ", turned \(degrees)° anticlockwise"
        }
        return "Looking from \(face.view.rawValue)\(turn)"
    }

    /// Front, back, left, right, top, bottom: the order of `Camera.StandardView`.
    private static func order(_ view: Camera.StandardView) -> Int {
        Camera.StandardView.allCases.firstIndex(of: view) ?? 0
    }

    private func dragChanged(_ value: DragGesture.Value) {
        let t = value.translation
        var last = lastTranslation
        if !orbiting {
            // Until it moves past the slop it may still be a click (and mustn't stop an animation).
            guard hypot(t.width, t.height) >= Self.clickSlop else { return }
            orbiting = true
            orbitedThisPress = true
            hoverPoint = nil
            last = .zero
            onOrbitBegan()
        }
        lastTranslation = t
        // Like the viewport: a cube's width of drag turns about three radians, read in screen
        // directions when the view is rolled.
        let scale = Double(size) * 0.3
        let d = camera.unrolled(CGSize(width: t.width - last.width, height: t.height - last.height))
        onOrbit(-Double(d.width) / scale, Double(d.height) / scale)
    }

    private func dragEnded(_ value: DragGesture.Value) {
        let t = value.translation
        if orbiting {
            endOrbit()
        } else if !orbitedThisPress, hypot(t.width, t.height) < Self.clickSlop,
                  let target = Self.target(at: value.startLocation, camera: camera, size: size, showsArrows: !isAnimating) {
            switch target {
            case .look(let d): onRegion(d)
            case .roll(let clockwise): onRoll(clockwise)
            }
        }
        orbitedThisPress = false
    }

    private func endOrbit() {
        orbiting = false
        lastTranslation = .zero
        onOrbitEnded()
    }
}
