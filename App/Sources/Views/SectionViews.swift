import FilletCore
import FilletKernel
import FilletViewport
import SwiftUI

/// The section tool's glyph, on the tool strip, the panel and the pill.
enum SectionSymbol {
    static let name = "square.split.diagonal"
}

// MARK: - Choosing the plane

/// Over the viewport while choosing where Section view cuts: what to pick, the three origin
/// planes as buttons (for a plane behind the part or edge-on, for VoiceOver and the keyboard),
/// and Cancel. Like the sketch plane bar, a chip and its plane light up together.
struct SectionPlaneBar: View {
    @Bindable var session: DesignSession
    @Environment(\.touchTargets) private var touch

    private static let prompt = "\(Theme.Copy.pick) a plane or a flat face to cut along"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showsPrompt: true)
            bar(showsPrompt: false)
        }
        .onAppear { AccessibilityNotification.Announcement(Self.prompt).post() }
        .automationMarker("section-plane-bar")
    }

    private func bar(showsPrompt: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if showsPrompt {
                    Label(Self.prompt, systemImage: SectionSymbol.name)
                } else {
                    Image(systemName: SectionSymbol.name).accessibilityLabel(Self.prompt)
                }
            }
            .font(Theme.body.weight(.medium))
            .foregroundStyle(Theme.ink)
            .fixedSize()
            divider
            // Three chips written out, not a ForEach: iPad's asynchronous renderer re-ran a ForEach's
            // items off the main thread while the bar slid in, which a main-actor view can't allow.
            HStack(spacing: Theme.Space.xs) {
                chip(.xy)
                chip(.xz)
                chip(.yz)
            }
            divider
            Button("Cancel") { session.cancelChoosingSectionPlane() }
                .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: touch ? 44 : 28)
                .contentShape(Rectangle())
                .hoverHighlight()
                .help("Stop choosing a plane [Esc]")
                .automationFrame("section-plane.cancel")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
        .floatingElevation(cornerRadius: touch ? 26 : 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section view")
    }

    private func chip(_ plane: StandardPlane) -> some View {
        PlaneChip(plane: plane, lit: session.hover == .originPlane(plane), help: "Cut along \(plane.title), the \(plane.role) plane",
                  hint: "Cuts the model open along the \(plane.role) plane", automationID: "section-plane.\(plane.rawValue)") {
            session.startSection(on: plane)
        } onHover: { inside in
            if inside { session.hover = .originPlane(plane) } else if session.hover == .originPlane(plane) { session.hover = nil }
        }
    }

    private var divider: some View { Theme.hairlineStrong.frame(width: 1, height: 16) }
}

// MARK: - On, with the handles away

/// Over the viewport while a section cuts the model and its handles are away: it says so (a cut
/// model can look like a broken one) and offers the way back to the handles, or out.
struct SectionPill: View {
    @Bindable var session: DesignSession
    @Environment(\.touchTargets) private var touch

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Label("Section view", systemImage: SectionSymbol.name)
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            Theme.hairlineStrong.frame(width: 1, height: 16)
            action("Edit", "slider.horizontal.3", help: "Bring back the handles to move the cut") { session.editSection() }
                .disabled(session.isBusyEditing)
            action("Turn off", "xmark", help: "Show the whole model [⇧⌘X]") { session.turnSectionOff() }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, touch ? 0 : Theme.Space.xs)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().strokeBorder(Theme.select.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .automationMarker("section-pill")
    }

    private func action(_ title: String, _ symbol: String, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.selectInk)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: touch ? 44 : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight()
        .help(help)
        .automationFrame("section-pill.\(title)")
    }
}

// MARK: - Panel

/// Section view's panel, where the inspector goes while its handles are up: the plane it cuts
/// along, the offset and the two tilts as typed values, flip, and a straight look at the cut.
struct SectionInspector: View {
    @Bindable var session: DesignSession

    private var ev: Evaluator { session.model.parameters.evaluator }

    var body: some View {
        if let s = session.section {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                InspectorHeader(symbol: SectionSymbol.name, title: "Section view", subtitle: "Cutting along \(s.reference.name)", tint: Theme.selectInk)
                plane(s)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ExprField(label: "Offset", value: Expr(rounded(s.offset)), labelWidth: 92, evaluator: ev) { expr in
                        if let v = try? ev.length(expr) { session.setSectionOffset(v) }
                    }
                    .automationFrame("section.offset")
                    ExprField(label: s.tiltLabels.u, value: Expr(rounded(s.tiltU)), kind: .angle, labelWidth: 92, evaluator: ev) { expr in
                        if let v = try? ev.angleDegrees(expr) { session.setSectionTilt(u: v) }
                    }
                    ExprField(label: s.tiltLabels.v, value: Expr(rounded(s.tiltV)), kind: .angle, labelWidth: 92, evaluator: ev) { expr in
                        if let v = try? ev.angleDegrees(expr) { session.setSectionTilt(v: v) }
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button { session.flipSection() } label: { Label("Flip side", systemImage: "arrow.left.arrow.right") }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Cut away the other side; the cut stays where it is")
                        .automationFrame("section.flip")
                    Button { session.resetSectionTilt() } label: { Label("Untilt", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(s.tiltU == 0 && s.tiltV == 0)
                        .help("Back to the direction of \(s.reference.name)")
                }
                Button { session.lookAtSection() } label: { Label("Look at the cut", systemImage: "eye") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Turn the view to look straight at the cut, from the side cut away")
                Hint("The arrow points at the side that's cut away. A positive offset moves the cut that way.", symbol: "arrow.down.right")
                Hint("Drag the arrow to slide the cut, a curved grip to tilt it, or \(Theme.Copy.pick.lowercased()) the value beside the arrow to type one.",
                     symbol: "hand.draw")
            }
            .automationFrame("section-panel")
        }
    }

    /// The plane it cuts along, and the way to another one.
    private func plane(_ s: SectionState) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Plane").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                Text(s.reference.name).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Change") { session.changeSectionPlane() }
                .buttonStyle(SecondaryButtonStyle())
                .help("Pick another origin plane or flat face")
                .automationFrame("section.change")
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// What the fields show: hundredths at most, as the handles move in tenths and whole degrees.
    private func rounded(_ v: Double) -> Double {
        let r = (v * 100).rounded() / 100
        return r == 0 ? 0 : r
    }
}

/// Delete and Done, pinned to the bottom of the inspector while the section's handles are up.
struct SectionFooter: View {
    let delete: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                .buttonStyle(SecondaryButtonStyle(role: .destructive))
                .help("Make the model whole and forget this plane")
            Button(action: done) {
                Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .help("Put the handles away; the cut stays [Esc]")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }
}

// MARK: - On the canvas

/// Section view's controls that live by its handles: the offset in a pill past the arrow's head
/// (tap it to type one), a round flip button behind the arrow's base, and while a grip turns, its
/// angle beside it. They follow the live camera, so they stay with the handles while orbiting.
/// Fetches the kernel's exact outline of the section shown once the plane holds still (see
/// `DesignSession.loadSectionCurves`). On its own, and drawing nothing, so a drag step restarts
/// only its wait and redraws nothing else.
struct SectionCurvesLoader: View {
    let session: DesignSession

    var body: some View {
        let request = session.sectionCurvesRequest
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: request) { await session.loadSectionCurves(request) }
    }
}

struct SectionGizmoOverlay: View {
    @Bindable var session: DesignSession
    let controller: ViewportController
    @State private var typing = false
    @State private var text = ""
    /// The field opens with its value selected, so typing replaces it.
    @State private var selection: TextSelection?
    @State private var error = false
    @FocusState private var focused: Bool
    @Environment(\.touchTargets) private var touch

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.pickMode == .section, let s = session.section, let layout = layout(s) {
                valuePill(s)
                    .position(layout.pill)
                flipButton(angle: layout.axisAngle)
                    .position(layout.flip)
                if let drag = session.sectionDrag, drag != DesignSession.sectionOffsetHandleID, let tag = layout.tiltTag {
                    let value = drag == DesignSession.sectionTiltUHandleID ? s.tiltU : s.tiltV
                    Text("\(DesignSession.sectionFormat(value))°")
                        .font(Theme.value)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().strokeBorder(Theme.select, lineWidth: 1.5))
                        .fixedSize()
                        .position(tag)
                        .allowsHitTesting(false)
                        .automationMarker("section-angle-tag")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: session.pickMode == .section) { _, up in if !up { typing = false } }
    }

    /// Where things go on screen: the pill out past the arrow's head, the flip button behind its
    /// base, both along the arrow as drawn. Looking straight down the arrow there is no "along",
    /// so they sit off to the sides.
    private func layout(_ s: SectionState) -> (pill: CGPoint, flip: CGPoint, axisAngle: Angle, tiltTag: CGPoint?)? {
        let cam = controller.liveCamera, size = controller.viewSize
        guard size.width > 0, let c = cam.project(s.center, viewSize: size) else { return nil }
        let wpp = cam.worldUnitsPerPoint(at: s.center, viewSize: size)
        let n = s.normal
        guard let end = cam.project(s.center + n * (HandleMetrics.totalLength * wpp), viewSize: size) else { return nil }
        let dx = end.x - c.x, dy = end.y - c.y
        let length = (dx * dx + dy * dy).squareRoot()
        var pill = CGPoint(x: c.x + 52, y: c.y - 34), flip = CGPoint(x: c.x - 38, y: c.y + 30)
        var angle = Angle.zero
        if length > 18 {
            let ux = dx / length, uy = dy / length
            // Past the head by about half a pill; behind the base dot by a button and a gap.
            let reach: CGFloat = 16 + 40 * abs(ux) + 12 * abs(uy)
            pill = CGPoint(x: end.x + ux * reach, y: end.y + uy * reach)
            flip = CGPoint(x: c.x - ux * 30, y: c.y - uy * 30)
            angle = .radians(atan2(uy, ux))
        }
        var tag: CGPoint?
        if let drag = session.sectionDrag {
            let f = s.frame
            let out = drag == DesignSession.sectionTiltUHandleID ? f.v : f.u
            tag = cam.project(s.center + out * ((HandleMetrics.gripRadius + 30) * wpp), viewSize: size)
        }
        return (pill, flip, angle, tag)
    }

    @ViewBuilder private func valuePill(_ s: SectionState) -> some View {
        if typing {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "keyboard").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                TextField("Offset", text: $text, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(Theme.value)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 72)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .focused($focused)
                    .focusedValue(\.isEditingText, focused ? true : nil)
                    .onSubmit(apply)
                    #if os(macOS)
                    .onExitCommand { typing = false }
                    #endif
                    .accessibilityLabel("Section offset, millimetres")
                Text("mm").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: touch ? 40 : 28)
            .background(Capsule().fill(Theme.raised))
            .overlay(Capsule().strokeBorder(error ? Theme.danger : Theme.select, lineWidth: 2))
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
            .fixedSize()
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in if !isFocused { typing = false } }
            .onChange(of: text) { _, _ in error = false }
            .automationMarker("section-offset-field")
        } else {
            Button {
                text = ExprField.format((s.offset * 100).rounded() / 100)
                selection = TextSelection(range: text.startIndex..<text.endIndex)
                error = false
                typing = true
            } label: {
                Text(session.sectionOffsetLabel)
                    .font(Theme.value)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Theme.select, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                    .fixedSize()
                    // A fingertip-sized target around the small pill.
                    .padding(touch ? 10 : 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("The cut's offset from \(s.reference.name). Click to type one")
            .accessibilityLabel("Section offset")
            .accessibilityValue(session.sectionOffsetLabel)
            .accessibilityHint("Type an offset")
            .automationFrame("section-pill-value")
        }
    }

    private func flipButton(angle: Angle) -> some View {
        Button { session.flipSection() } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.selectInk)
                .rotationEffect(angle)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.raised))
                .overlay(Circle().strokeBorder(Theme.select, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                .padding(touch ? 9 : 3)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Flip: cut away the other side")
        .accessibilityLabel("Flip section side")
        .automationFrame("section-flip")
    }

    private func apply() {
        let expr = Expr(stringLiteral: text.trimmingCharacters(in: .whitespaces))
        guard let v = try? session.model.parameters.evaluator.length(expr) else { error = true; return }
        session.setSectionOffset(v)
        typing = false
    }
}
