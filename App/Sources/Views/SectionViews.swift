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
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    SectionLookToggle(symbol: "pencil.and.ruler", title: "2D section view", isOn: session.section2D,
                                      on: "Straight at the cut, as a drawing", off: "Turns the view straight at the cut",
                                      help: "Look straight at the cut, flat and orthographic, the rest of the model as lines",
                                      automationID: "section.2d") { session.setSection2D($0) }
                    SectionLookToggle(symbol: "square.stack.3d.up.slash", title: "Section only", isOn: session.sectionOnly,
                                      on: "Only the cut faces show", off: "Hides everything but the cut faces",
                                      help: "Show only the cut faces, nothing else of the model",
                                      automationID: "section.only") { session.setSectionOnly($0) }
                }
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
                        .automationFrame("section.untilt")
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

/// One of Section view's looks (2D, Section only) in its panel: a switch with a line saying what
/// it does, like the panel's other options.
struct SectionLookToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let on: String
    let off: String
    let help: String
    let automationID: String
    let onChange: (Bool) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.selectInk : Theme.inkTertiary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(isOn ? on : off)
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.switchOn)
        .frame(minHeight: Theme.Metrics.target(touch: touch))
        .animation(Theme.Motion.hover, value: isOn)
        .help(help)
        .automationFrame(automationID)
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
    /// The pill being typed into, nil when none is.
    @State private var typing: Field?
    @State private var text = ""
    /// The field opens with its value selected, so typing replaces it.
    @State private var selection: TextSelection?
    @State private var error = false
    @FocusState private var focused: Bool
    @Environment(\.touchTargets) private var touch

    /// What a pill reads and sets: the offset, or one of the tilts.
    enum Field: Equatable {
        case offset, tiltU, tiltV

        var handleID: String {
            switch self {
            case .offset: DesignSession.sectionOffsetHandleID
            case .tiltU: DesignSession.sectionTiltUHandleID
            case .tiltV: DesignSession.sectionTiltVHandleID
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.pickMode == .section, let s = session.section, let layout = layout(s) {
                pill(.offset, s)
                    .position(layout.pill)
                flipButton(angle: layout.axisAngle)
                    .position(layout.flip)
                // A tilt that isn't 0 keeps its angle in a pill under the offset's, to read and type.
                let tilts = [Field.tiltU, .tiltV].filter { value($0, s) != 0 && session.sectionDrag != $0.handleID || typing == $0 }
                if !tilts.isEmpty {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(tilts, id: \.handleID) { pill($0, s) }
                    }
                    .position(x: layout.pill.x, y: layout.pill.y + (touch ? 44 : 30))
                }
                // While a grip turns, its angle rides at the tip of the arc it sweeps.
                if let drag = session.sectionDrag, drag != DesignSession.sectionOffsetHandleID, let tag = layout.tiltTag {
                    let value = drag == DesignSession.sectionTiltUHandleID ? s.tiltU : s.tiltV
                    Text("\(DesignSession.sectionFormat(value))°")
                        .font(Theme.value)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.select))
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
                        .fixedSize()
                        .position(tag)
                        .allowsHitTesting(false)
                        .automationMarker("section-angle-tag")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: session.pickMode == .section) { _, up in if !up { typing = nil } }
    }

    private func value(_ field: Field, _ s: SectionState) -> Double {
        switch field {
        case .offset: s.offset
        case .tiltU: s.tiltU
        case .tiltV: s.tiltV
        }
    }

    private func label(_ field: Field, _ s: SectionState) -> String {
        field == .offset ? session.sectionOffsetLabel : "\(DesignSession.sectionFormat(value(field, s)))°"
    }

    /// Where things go on screen: the pill out past the arrow's head, the flip button behind its
    /// base, both along the arrow as drawn. Looking straight down the arrow there is no "along",
    /// so they sit off to the sides. A turning grip's angle goes past the end of its arc.
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
        if let drag = session.sectionDrag, drag != DesignSession.sectionOffsetHandleID {
            let f = s.frame
            let out = drag == DesignSession.sectionTiltUHandleID ? f.v : f.u
            tag = cam.project(s.center + out * ((HandleMetrics.ringRadius + 26) * wpp), viewSize: size)
        }
        return (pill, flip, angle, tag)
    }

    /// A value on the canvas: tap to type one. The offset's fills in while its arrow is held, so
    /// the press shows before anything moves.
    @ViewBuilder private func pill(_ field: Field, _ s: SectionState) -> some View {
        if typing == field {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "keyboard").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                TextField(field == .offset ? "Offset" : "Angle", text: $text, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(Theme.value)
                    .foregroundStyle(Theme.ink)
                    .frame(width: field == .offset ? 72 : 52)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .focused($focused)
                    .focusedValue(\.isEditingText, focused ? true : nil)
                    .onSubmit { apply(field) }
                    #if os(macOS)
                    .onExitCommand { typing = nil }
                    #endif
                    .accessibilityLabel(field == .offset ? "Section offset, millimetres" : "Section tilt, degrees")
                Text(field == .offset ? "mm" : "°").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: touch ? 40 : 28)
            .background(Capsule().fill(Theme.raised))
            .overlay(Capsule().strokeBorder(error ? Theme.danger : Theme.select, lineWidth: 2))
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
            .fixedSize()
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in if !isFocused, typing == field { typing = nil } }
            .onChange(of: text) { _, _ in error = false }
            .automationMarker(field == .offset ? "section-offset-field" : "section-angle-field")
        } else {
            let held = session.sectionDrag == field.handleID
            Button {
                text = ExprField.format((value(field, s) * 100).rounded() / 100)
                selection = TextSelection(range: text.startIndex..<text.endIndex)
                error = false
                typing = field
            } label: {
                Text(label(field, s))
                    .font(Theme.value)
                    .foregroundStyle(held ? .white : Theme.ink)
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                    .background(Capsule().fill(held ? Theme.select : Theme.raised))
                    .overlay(Capsule().strokeBorder(Theme.select, lineWidth: 1.5))
                    .shadow(color: .black.opacity(held ? 0.18 : 0.1), radius: held ? 6 : 4, y: 1)
                    .scaleEffect(held ? 1.08 : 1)
                    .animation(Theme.Motion.press, value: held)
                    .fixedSize()
                    // A fingertip-sized target around the small pill.
                    .padding(touch ? 10 : 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(field == .offset ? "The cut's offset from \(s.reference.name). Click to type one" : "The cut's tilt. Click to type one")
            .accessibilityLabel(field == .offset ? "Section offset" : (field == .tiltU ? s.tiltLabels.u : s.tiltLabels.v))
            .accessibilityValue(label(field, s))
            .accessibilityHint(field == .offset ? "Type an offset" : "Type an angle")
            .automationFrame(field == .offset ? "section-pill-value" : (field == .tiltU ? "section-pill-tiltU" : "section-pill-tiltV"))
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

    private func apply(_ field: Field) {
        let expr = Expr(stringLiteral: text.trimmingCharacters(in: .whitespaces))
        let ev = session.model.parameters.evaluator
        switch field {
        case .offset:
            guard let v = try? ev.length(expr) else { error = true; return }
            session.setSectionOffset(v)
        case .tiltU, .tiltV:
            guard let v = try? ev.angleDegrees(expr) else { error = true; return }
            if field == .tiltU { session.setSectionTilt(u: v) } else { session.setSectionTilt(v: v) }
        }
        typing = nil
    }
}
