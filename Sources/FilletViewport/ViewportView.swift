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
    private weak var delegate: (any ViewportDelegate)?
    @State private var controller: ViewportController
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - scene: what to draw.
    ///   - camera: the camera; external changes animate, gestures write back when they end.
    ///   - filter: what taps, hover and tool hits can pick.
    ///   - options: input/display switches.
    ///   - delegate: receives taps, hover, tool strokes and handle drags.
    ///   - controller: pass your own to call `fitAll()`, `show(_:)` etc. from outside.
    public init(scene: ViewportScene, camera: Binding<Camera>, filter: PickFilter = .default,
                options: ViewportOptions = ViewportOptions(), delegate: (any ViewportDelegate)? = nil,
                controller: ViewportController? = nil) {
        self.scene = scene
        self._camera = camera
        self.filter = filter
        self.options = options
        self.delegate = delegate
        self._controller = State(initialValue: controller ?? ViewportController())
    }

    private var appearance: ViewportAppearance {
        options.appearance ?? (colorScheme == .dark ? .dark : .light)
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if controller.renderer != nil {
                ViewportRepresentable(controller: controller, scene: scene, camera: $camera, filter: filter,
                                      options: options, delegate: delegate, appearance: appearance)
            } else {
                Rectangle().fill(.gray.opacity(0.2))
                    .overlay(Text("Metal is not available").foregroundStyle(.secondary))
            }
            if options.showsLabels {
                ViewportLabels(controller: controller, scene: scene, appearance: appearance)
                    .allowsHitTesting(false)
            }
            if options.showsViewCube {
                ViewCubeOverlay(controller: controller, appearance: appearance)
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
    let filter: PickFilter
    let options: ViewportOptions
    weak var delegate: (any ViewportDelegate)?
    let appearance: ViewportAppearance

    func makeUIView(context: Context) -> ViewportUIView {
        ViewportUIView(controller: controller)
    }

    func updateUIView(_ view: ViewportUIView, context: Context) {
        controller.cameraBinding = $camera
        controller.update(scene: scene, camera: camera, filter: filter, options: options, delegate: delegate, appearance: appearance)
    }
}
#elseif os(macOS)
struct ViewportRepresentable: NSViewRepresentable {
    let controller: ViewportController
    let scene: ViewportScene
    @Binding var camera: Camera
    let filter: PickFilter
    let options: ViewportOptions
    weak var delegate: (any ViewportDelegate)?
    let appearance: ViewportAppearance

    func makeNSView(context: Context) -> ViewportNSView {
        ViewportNSView(controller: controller)
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        controller.cameraBinding = $camera
        controller.update(scene: scene, camera: camera, filter: filter, options: options, delegate: delegate, appearance: appearance)
    }
}
#endif

// MARK: - Labels (measures, bed name)

struct ViewportLabels: View {
    let controller: ViewportController
    let scene: ViewportScene
    let appearance: ViewportAppearance

    var body: some View {
        let cam = controller.liveCamera
        let size = controller.viewSize
        ZStack(alignment: .topLeading) {
            ForEach(scene.measures) { m in
                if let p = cam.project((m.from + m.to) * 0.5, viewSize: size) {
                    Text(m.label)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: p.x + 8, y: p.y)
                        .fixedSize()
                }
            }
            if let plate = scene.plate, !plate.name.isEmpty,
               let p = cam.project(Vec3(plate.minXY.x, plate.minXY.y, 0), viewSize: size),
               p.x > -50, p.y > -20, p.x < size.width + 50, p.y < size.height + 20 {
                Text(plate.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(appearance == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.4))
                    .fixedSize()
                    .position(x: p.x, y: p.y + 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - View cube

struct ViewCubeOverlay: View {
    let controller: ViewportController
    let appearance: ViewportAppearance

    var body: some View {
        VStack(spacing: 8) {
            ViewCube(camera: controller.liveCamera, appearance: appearance,
                     onFace: { controller.show($0) },
                     onCorner: { controller.show(yaw: $0, pitch: $1) })
            HStack(spacing: 6) {
                CubeButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Fit all") { controller.fitAll() }
                CubeButton(systemName: controller.liveCamera.projection == .perspective ? "cube" : "square.grid.3x3",
                           help: "Perspective / orthographic") { controller.toggleProjection() }
            }
        }
    }
}

private struct CubeButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    public var body: some View {
        let cam = camera
        let dark = appearance == .dark
        Canvas { ctx, sz in
            let back = cam.back
            let visible = Self.faces.filter { $0.normal.dot(back) > 0.02 }.sorted { $0.normal.dot(back) < $1.normal.dot(back) }
            for face in visible {
                let pts = face.corners.map { Self.project($0, camera: cam, size: sz.width) }
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                let facing = face.normal.dot(back)
                let shade = dark ? 0.24 + 0.16 * facing : 0.80 + 0.16 * facing
                ctx.fill(path, with: .color(Color(white: shade).opacity(0.94)))
                ctx.stroke(path, with: .color(dark ? .white.opacity(0.22) : .black.opacity(0.22)), lineWidth: 1)
                if facing > 0.3 {
                    let c = Self.project(face.normal, camera: cam, size: sz.width)
                    ctx.opacity = min(1, (facing - 0.3) * 2.5)
                    ctx.draw(Text(face.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(dark ? .white : .black.opacity(0.75)),
                             at: c)
                    ctx.opacity = 1
                }
            }
            // Axis triad in the bottom-left corner.
            let o = CGPoint(x: 10, y: sz.height - 10)
            for (axis, color) in [(Vec3.unitX, Color.red), (Vec3.unitY, Color.green), (Vec3.unitZ, Color.blue)] {
                var p = Path()
                p.move(to: o)
                p.addLine(to: CGPoint(x: o.x + axis.dot(cam.right) * 13, y: o.y - axis.dot(cam.up) * 13))
                ctx.stroke(p, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in tap(loc) }
        .accessibilityElement()
        .accessibilityLabel("View cube")
        .accessibilityActions {
            ForEach(Camera.StandardView.allCases, id: \.self) { v in
                Button(v.rawValue.capitalized) { onFace(v) }
            }
        }
    }

    private func tap(_ loc: CGPoint) {
        let back = camera.back
        // Corners first (iso views from that corner).
        for d in Self.cornerDirs where d.dot(back) > 0.2 {
            let p = Self.project(d, camera: camera, size: size)
            if hypot(p.x - loc.x, p.y - loc.y) < 10 {
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
