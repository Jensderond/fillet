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
        controller.update(scene: scene, camera: requestedCamera, filter: filter, options: options, delegate: delegate, appearance: appearance)
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
        controller.update(scene: scene, camera: requestedCamera, filter: filter, options: options, delegate: delegate, appearance: appearance)
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

    var body: some View {
        VStack(spacing: 8) {
            ViewCube(camera: controller.liveCamera, appearance: appearance,
                     onFace: { controller.show($0) },
                     onCorner: { controller.show(yaw: $0, pitch: $1) })
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
    }
}

struct CubeButton: View {
    let systemName: String
    let help: String
    let appearance: ViewportAppearance
    let action: () -> Void
    @State private var hovering = false

    /// 44 pt touch targets on iPad.
    #if os(iOS) || os(visionOS)
    static let side: CGFloat = 44
    #else
    static let side: CGFloat = 32
    #endif

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Self.side, height: Self.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appearance.chipInk)
        .background(appearance.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(appearance.chipInk.opacity(hovering ? 0.08 : 0)).allowsHitTesting(false))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(appearance.chipEdge))
        #if os(iOS) || os(visionOS)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .hoverEffect(.highlight)
        #endif
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small orientation cube: tap a face for a standard view, a corner for an
/// isometric view from that corner. Drawn with SwiftUI from the camera orientation.
public struct ViewCube: View {
    let camera: Camera
    let appearance: ViewportAppearance
    let onFace: (Camera.StandardView) -> Void
    let onCorner: (Double, Double) -> Void
    var size: CGFloat = 84
    @State private var hoveredFace: Camera.StandardView?

    public init(camera: Camera, appearance: ViewportAppearance, onFace: @escaping (Camera.StandardView) -> Void,
                onCorner: @escaping (Double, Double) -> Void) {
        self.camera = camera
        self.appearance = appearance
        self.onFace = onFace
        self.onCorner = onCorner
    }

    struct Face {
        let normal: Vec3
        let corners: [Vec3]
        let label: String
        let view: Camera.StandardView
    }

    static let faces: [Face] = {
        func f(_ n: Vec3, _ u: Vec3, _ v: Vec3, _ label: String, _ view: Camera.StandardView) -> Face {
            Face(normal: n, corners: [n - u - v, n + u - v, n + u + v, n - u + v], label: label, view: view)
        }
        return [
            f(.unitZ, .unitX, .unitY, "TOP", .top),
            f(-Vec3.unitZ, .unitX, -Vec3.unitY, "BOTTOM", .bottom),
            f(-Vec3.unitY, .unitX, .unitZ, "FRONT", .front),
            f(.unitY, -Vec3.unitX, .unitZ, "BACK", .back),
            f(.unitX, .unitY, .unitZ, "RIGHT", .right),
            f(-Vec3.unitX, -Vec3.unitY, .unitZ, "LEFT", .left),
        ]
    }()

    static let cornerDirs: [Vec3] = (0..<8).map { i in
        Vec3(i & 1 == 0 ? -1 : 1, i & 2 == 0 ? -1 : 1, i & 4 == 0 ? -1 : 1)
    }

    /// Cube-space point → canvas point (orthographic, camera orientation only).
    static func project(_ p: Vec3, camera: Camera, size: CGFloat) -> CGPoint {
        let s = size * 0.3
        return CGPoint(x: size / 2 + p.dot(camera.right) * s, y: size / 2 - p.dot(camera.up) * s)
    }

    /// The camera the cube is drawn from. Looking straight at a face, a flat square with a label
    /// wouldn't read as a cube you can tap, so it turns 15° to show two more faces.
    var displayCamera: Camera {
        let back = camera.back
        guard Self.faces.contains(where: { $0.normal.dot(back) > 0.985 }) else { return camera }
        var c = camera
        let tilt = 15 * Double.pi / 180
        c.yaw += tilt
        c.pitch = c.pitch > 0.5 ? c.pitch - tilt : c.pitch < -0.5 ? c.pitch + tilt : c.pitch + tilt
        return c
    }

    public var body: some View {
        let cam = displayCamera
        let look = appearance
        let hovered = hoveredFace
        Canvas { ctx, sz in
            let back = cam.back
            let visible = Self.faces.filter { $0.normal.dot(back) > 0.02 }.sorted { $0.normal.dot(back) < $1.normal.dot(back) }
            for face in visible {
                let pts = face.corners.map { Self.project($0, camera: cam, size: sz.width) }
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                let facing = face.normal.dot(back)
                ctx.fill(path, with: .color(look.cubeFace(facing: facing)))
                if face.view == hovered { ctx.fill(path, with: .color(look.cubeHover)) }
                ctx.stroke(path, with: .color(look.cubeEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                if facing > 0.3 {
                    let c = Self.project(face.normal, camera: cam, size: sz.width)
                    ctx.opacity = min(1, (facing - 0.3) * 2.5)
                    ctx.draw(Text(face.label).font(.system(size: 10, weight: .semibold).width(.condensed))
                                .foregroundStyle(look.chipInk),
                             at: c)
                    ctx.opacity = 1
                }
            }
            // Axis triad in the bottom-left corner.
            let o = CGPoint(x: 10, y: sz.height - 10)
            let pal = appearance.palette
            for (axis, color) in [(Vec3.unitX, pal.axisX.color), (Vec3.unitY, pal.axisY.color), (Vec3.unitZ, pal.axisZ.color)] {
                var p = Path()
                p.move(to: o)
                p.addLine(to: CGPoint(x: o.x + axis.dot(cam.right) * 13, y: o.y - axis.dot(cam.up) * 13))
                ctx.stroke(p, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in tap(loc) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hoveredFace = face(at: p)
            case .ended: hoveredFace = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel("View cube")
        .accessibilityValue(Self.faces.first { $0.normal.dot(camera.back) > 0.9 }.map { "Looking from \($0.view.rawValue)" } ?? "Angled view")
        .accessibilityActions {
            ForEach(Camera.StandardView.allCases, id: \.self) { v in
                Button(v.rawValue.capitalized) { onFace(v) }
            }
        }
    }

    /// Corners are small; a fingertip needs a wider catch than the pointer.
    #if os(iOS) || os(visionOS)
    static let cornerHitRadius: CGFloat = 18
    #else
    static let cornerHitRadius: CGFloat = 10
    #endif

    /// The visible face under a point (corners excluded), for hover.
    private func face(at loc: CGPoint) -> Camera.StandardView? {
        let camera = displayCamera
        let back = camera.back
        for d in Self.cornerDirs where d.dot(back) > 0.2 {
            let p = Self.project(d, camera: camera, size: size)
            if hypot(p.x - loc.x, p.y - loc.y) < Self.cornerHitRadius { return nil }
        }
        let visible = Self.faces.filter { $0.normal.dot(back) > 0.02 }.sorted { $0.normal.dot(back) > $1.normal.dot(back) }
        for face in visible {
            var path = Path()
            path.addLines(face.corners.map { Self.project($0, camera: camera, size: size) })
            path.closeSubpath()
            if path.contains(loc) { return face.view }
        }
        return nil
    }

    private func tap(_ loc: CGPoint) {
        let camera = displayCamera
        let back = camera.back
        // Corners first (iso views from that corner).
        for d in Self.cornerDirs where d.dot(back) > 0.2 {
            let p = Self.project(d, camera: camera, size: size)
            if hypot(p.x - loc.x, p.y - loc.y) < Self.cornerHitRadius {
                let n = d.normalized
                onCorner(atan2(n.x, -n.y), asin(n.z))
                return
            }
        }
        let visible = Self.faces.filter { $0.normal.dot(back) > 0.02 }.sorted { $0.normal.dot(back) > $1.normal.dot(back) }
        for face in visible {
            var path = Path()
            path.addLines(face.corners.map { Self.project($0, camera: camera, size: size) })
            path.closeSubpath()
            if path.contains(loc) {
                onFace(face.view)
                return
            }
        }
    }
}
