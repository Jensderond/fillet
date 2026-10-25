import FilletCore
import FilletKernel
import SwiftUI

extension StandardPlane {
    /// "XY", as the viewport labels the plane.
    var title: String { rawValue.uppercased() }
    /// Where the plane lies on the printer.
    var role: String {
        switch self {
        case .xy: "bed"
        case .xz: "front"
        case .yz: "side"
        }
    }
    /// The colour the viewport tints the plane: the axis it faces along.
    var tint: Color {
        switch self {
        case .xy: Theme.axisZ
        case .xz: Theme.axisY
        case .yz: Theme.axisX
        }
    }
}

/// Over the viewport while choosing where a new sketch goes: what to pick, the three origin
/// planes as buttons (for a plane hidden behind the part, edge-on or out of view, and for
/// VoiceOver and the keyboard), and Cancel. A chip and its plane in the viewport light up
/// together, whichever of the two the pointer is over.
struct SketchPlaneBar: View {
    @Bindable var session: DesignSession
    @Environment(\.touchTargets) private var touch

    private static let prompt = "\(Theme.Copy.pick) a plane or a flat face"

    var body: some View {
        // The prompt folds into its glyph when the bar runs out of room (Split View, big text).
        ViewThatFits(in: .horizontal) {
            bar(showsPrompt: true)
            bar(showsPrompt: false)
        }
        .onAppear { AccessibilityNotification.Announcement("\(Self.prompt) to sketch on").post() }
        .automationMarker("sketch-plane-bar")
    }

    private func bar(showsPrompt: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if showsPrompt {
                    Label(Self.prompt, systemImage: "hand.tap")
                } else {
                    Image(systemName: "hand.tap").accessibilityLabel(Self.prompt)
                }
            }
            .font(Theme.body.weight(.medium))
            .foregroundStyle(Theme.ink)
            .fixedSize()
            divider
            HStack(spacing: Theme.Space.xs) {
                ForEach(StandardPlane.allCases, id: \.self) { plane in
                    PlaneChip(plane: plane, lit: session.hover == .originPlane(plane)) {
                        session.startSketch(on: plane)
                    } onHover: { inside in
                        if inside { session.hover = .originPlane(plane) } else if session.hover == .originPlane(plane) { session.hover = nil }
                    }
                }
            }
            divider
            Button("Cancel") { session.cancelChoosingSketchPlane() }
                .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: touch ? 44 : 28)
                .contentShape(Rectangle())
                .hoverHighlight()
                .help("Stop choosing a plane (Esc)")
                .automationFrame("sketch-plane.cancel")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
        .floatingElevation(cornerRadius: touch ? 26 : 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New sketch")
    }

    private var divider: some View { Theme.hairlineStrong.frame(width: 1, height: 16) }
}

/// One origin plane: its glyph in the plane's colour and its name.
private struct PlaneChip: View {
    let plane: StandardPlane
    /// The plane is under the pointer, here or in the viewport.
    let lit: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PlaneGlyph(plane: plane, lit: lit)
                    .frame(width: 22, height: 16)
                Text(plane.title)
                    .font(Theme.value)
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minWidth: touch ? 64 : 52, minHeight: touch ? 44 : 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(lit ? plane.tint.opacity(0.14) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover(perform: onHover)
        .animation(Theme.Motion.hover, value: lit)
        .help("Sketch on \(plane.title), the \(plane.role) plane")
        .accessibilityLabel("\(plane.title) plane")
        .accessibilityHint("Starts a sketch on the \(plane.role) plane")
        .automationFrame("sketch-plane.\(plane.rawValue)")
    }
}

/// The three origin planes as the viewport draws them (the bed square and the two upright
/// planes standing on it), seen from the isometric view, with this chip's plane filled in.
struct PlaneGlyph: View {
    let plane: StandardPlane
    var lit = false

    /// The patch corners in world units: XY spans ±1 in x and y, the upright planes rise 0…1.
    static func corners(_ p: StandardPlane) -> [Vec3] {
        switch p {
        case .xy: [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)]
        case .xz: [Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(-1, 0, 1)]
        case .yz: [Vec3(0, -1, 0), Vec3(0, 1, 0), Vec3(0, 1, 1), Vec3(0, -1, 1)]
        }
    }

    /// The app's isometric camera (yaw 45°, pitch atan 1/√2): screen right and up in world space.
    private static let right = Vec3(0.5.squareRoot(), 0.5.squareRoot(), 0)
    private static let up = Vec3(-1 / 6.0.squareRoot(), 1 / 6.0.squareRoot(), (2 / 3.0).squareRoot())

    var body: some View {
        Canvas { ctx, size in
            // Projected extents: x ±√2, y −0.82…1.22; fit and centre them.
            let scale = min(size.width / (2 * 2.0.squareRoot()), size.height / 2.04)
            func point(_ v: Vec3) -> CGPoint {
                CGPoint(x: size.width / 2 + v.dot(Self.right) * scale,
                        y: size.height / 2 - (v.dot(Self.up) - 0.2) * scale)
            }
            func path(_ p: StandardPlane) -> Path {
                var path = Path()
                path.addLines(Self.corners(p).map(point))
                path.closeSubpath()
                return path
            }
            for other in StandardPlane.allCases where other != plane {
                ctx.stroke(path(other), with: .color(Theme.inkTertiary.opacity(0.6)), lineWidth: 0.75)
            }
            let own = path(plane)
            ctx.fill(own, with: .color(plane.tint.opacity(lit ? 0.55 : 0.3)))
            ctx.stroke(own, with: .color(plane.tint), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
