import FilletCore
import FilletKernel
import FilletViewport
import Foundation

/// What a section is cut along: an origin plane or a flat face, as it was when picked. The offset
/// and tilts are measured from it, so the readout means "this far from the XZ plane".
struct SectionReference: Equatable {
    /// "XZ plane", "Flat face of Extrude 1".
    var name: String
    /// A point on the picked plane (the world origin for an origin plane).
    var origin: Vec3
    /// The plane's normal, turned to the side the camera was on when it was picked: that side is
    /// what the cut takes away first, so the inside faces the viewer.
    var normal: Vec3
    /// The level axis in the plane (X on the XZ plane), the first tilt's axis. `normal × u` is the second.
    var u: Vec3

    var v: Vec3 { normal.cross(u) }
}

/// Section view, like Shapr3D's: pick an origin plane or a flat face and the model is cut open
/// there, then slide the cut along its normal (the arrow), tilt it about its two in-plane axes
/// (the curved grips) or flip which side is cut away. Typed values go in the panel or in the
/// value pill on the canvas. View state, like Measure: never a step, never in the document or the
/// undo history; the plane stays put in the world while orbiting, and is remembered while the
/// section is off (until it is deleted).
struct SectionState: Equatable {
    var reference: SectionReference
    /// A point on the cut, where the handles sit: rotations turn about it, sliding moves it.
    var center: Vec3
    /// Degrees: first about the reference's `u` axis, then about the in-plane axis that turned to.
    var tiltU = 0.0
    var tiltV = 0.0
    /// The other side is cut away (the normal points the other way; the plane stays where it is).
    var flipped = false
    /// Cutting the model. Off, the plane is kept for the next time Section view is turned on.
    var isOn = true
    /// The handles and the section panel are up (Escape or Done puts them away; the cut stays).
    var isEditing = true

    /// The plane's axes after the tilts, before the flip: `u` and `v` in the plane, `n` across it.
    var frame: (u: Vec3, v: Vec3, n: Vec3) {
        let a = tiltU * .pi / 180, b = tiltV * .pi / 180
        let u0 = reference.u, v0 = reference.v, n0 = reference.normal
        // About u0 (the right-hand rule): v0 turns towards n0.
        let v1 = v0 * cos(a) + n0 * sin(a)
        let n1 = n0 * cos(a) - v0 * sin(a)
        // Then about v1: u0 turns away from n1.
        let u2 = u0 * cos(b) - n1 * sin(b)
        let n2 = n1 * cos(b) + u0 * sin(b)
        return (u2.normalized, v1.normalized, n2.normalized)
    }

    /// Points at the side that is cut away (`SectionPlane`'s convention).
    var normal: Vec3 { flipped ? -frame.n : frame.n }

    /// The picked plane's normal on the side that is cut away (the reference before the tilts).
    var referenceNormal: Vec3 { flipped ? -reference.normal : reference.normal }

    /// How far the handles' point is from the picked plane, along its normal: positive moves into
    /// the side that is cut away. Its sign changes on a flip (the plane doesn't move); a tilt,
    /// which turns about that point, leaves it as it is.
    var offset: Double { (center - reference.origin).dot(referenceNormal) }

    /// Where the handles' point is along the cut's own normal (what the arrow drags).
    var alongNormal: Double { (center - reference.origin).dot(normal) }

    /// Slides the cut along its normal (the arrow) until the offset reads `value`. Tilted almost
    /// edge-on to the picked plane, where that barely moves the reading, it slides along the
    /// picked plane's normal instead.
    mutating func setOffset(_ value: Double) {
        let k = normal.dot(referenceNormal)
        let direction = abs(k) > 0.2 ? normal / k : referenceNormal
        center = center + direction * (value - offset)
    }

    var plane: SectionPlane { SectionPlane(origin: center, normal: normal) }

    /// The world axis `v` runs along ("X"), nil for a slanted one.
    static func axisName(_ v: Vec3) -> String? {
        let names = ["X", "Y", "Z"]
        let parts = [abs(v.x), abs(v.y), abs(v.z)]
        return parts.firstIndex { $0 > 0.9999 }.map { names[$0] }
    }

    /// The tilt fields' labels: the world axis each turns about where there is one.
    var tiltLabels: (u: String, v: String) {
        ("Tilt about \(Self.axisName(reference.u) ?? "width")", "Tilt about \(Self.axisName(reference.v) ?? "height")")
    }
}

extension DesignSession {
    static let sectionOffsetHandleID = "section.offset"
    static let sectionTiltUHandleID = "section.tiltU"
    static let sectionTiltVHandleID = "section.tiltV"

    /// Why Section view can't start right now, or nil when it can (one that is on can always be turned off).
    var sectionUnavailableReason: String? {
        if section?.isOn == true || choosingSectionPlane { return nil }
        if model.bodies.isEmpty { return "Needs a body to cut. Extrude a sketch first." }
        if isBusyEditing, section == nil, let name = editingFeature?.name { return "Finish \(name) first: Done or Cancel." }
        return nil
    }

    /// The tool button and ⇧⌘X: off turns it on (straight onto a picked flat face, onto the plane
    /// used last, or with the planes offered to pick from); on, or choosing, turns it off.
    func toggleSection() {
        if choosingSectionPlane { return cancelChoosingSectionPlane() }
        if section?.isOn == true { return turnSectionOff() }
        if let reason = sectionUnavailableReason { message = ToastMessage(reason); return }
        if let face = sketchableFace, section == nil { return startSection(onFace: face.body, face.index) }
        guard section != nil else { return beginChoosingSectionPlane() }
        section?.isOn = true
        // While a step is open its own handles and panel stay; the cut just comes back.
        if !isBusyEditing { editSection() }
    }

    /// Shows the origin planes and flat faces to cut along (the next tap picks one).
    func beginChoosingSectionPlane() {
        if sketchEditor != nil { finishSketch() }
        if choosingSketchPlane { cancelChoosingSketchPlane() }
        measure = nil
        section?.isEditing = false
        selection = []
        hover = nil
        choosingSectionPlane = true
        // Looking straight along an axis, two of the planes would be edge-on: turn to see all three.
        let back = camera.back.normalized
        if [Vec3.unitX, .unitY, .unitZ].contains(where: { abs(back.dot($0)) > 0.97 }) {
            var c = camera
            c.setView(.iso)
            camera = c
        }
    }

    func cancelChoosingSectionPlane() {
        choosingSectionPlane = false
        hover = nil
    }

    /// Cuts along an origin plane, through the middle of what's shown.
    func startSection(on plane: StandardPlane) {
        let p = plane.plane
        let reference = SectionReference(name: "\(plane.title) plane", origin: .zero, normal: facingCamera(p.normal, at: p.origin), u: p.xDir)
        beginSection(reference, center: visibleBodyBounds.map { reference.project(($0.min + $0.max) * 0.5) } ?? .zero)
    }

    /// Cuts along a flat face (displayed face index), right on it: drag the arrow in to see inside.
    func startSection(onFace body: BodyRef, _ index: Int) {
        guard let shown = model.body(body), let p = shown.shape.facePlane(index) else { return }
        let n = facingCamera(p.normal, at: p.origin)
        // Level in the face where it isn't level itself, so the first tilt tips it like a lid.
        var u = Vec3.unitZ.cross(n)
        if u.length < 1e-6 { u = p.xDir }
        let reference = SectionReference(name: "Flat face of \(shown.name)", origin: p.origin, normal: n, u: u.normalized)
        beginSection(reference, center: reference.project(shown.shape.faceInfo(index).centroid))
    }

    private func beginSection(_ reference: SectionReference, center: Vec3) {
        choosingSectionPlane = false
        measure = nil
        selection = []
        hover = nil
        section = SectionState(reference: reference, center: center)
    }

    /// `n` or its opposite, whichever points from `p` towards the camera.
    private func facingCamera(_ n: Vec3, at p: Vec3) -> Vec3 {
        let toEye = camera.projection == .orthographic ? camera.back : camera.eye - p
        return n.dot(toEye) < 0 ? -n : n
    }

    /// The handles and the panel come up on the section that's on.
    func editSection() {
        guard section != nil else { return }
        if choosingSketchPlane { cancelChoosingSketchPlane() }
        measure = nil
        selection = []
        hover = nil
        section?.isOn = true
        section?.isEditing = true
    }

    /// Done or Escape: the handles go, the cut stays.
    func endSectionEditing() {
        section?.isEditing = false
        sectionDrag = nil
        hover = nil
    }

    /// The model is whole again; the plane is kept for next time.
    func turnSectionOff() {
        guard section?.isOn == true else { return }
        section?.isOn = false
        section?.isEditing = false
        sectionDrag = nil
        message = "Section view off. Turn it on again to cut along the same plane."
    }

    /// Forgets the plane: the next Section view picks a new one.
    func deleteSection() {
        section = nil
        sectionDrag = nil
    }

    /// Picks a new plane, keeping this one until a new one is picked.
    func changeSectionPlane() {
        beginChoosingSectionPlane()
    }

    /// The other side is cut away; the plane stays where it is.
    func flipSection() {
        section?.flipped.toggle()
    }

    func setSectionOffset(_ value: Double) {
        section?.setOffset(value)
    }

    /// Tilts turn about the handles' centre, so the cut keeps going through the point it's at.
    func setSectionTilt(u: Double? = nil, v: Double? = nil) {
        if let u { section?.tiltU = Self.wrapDegrees(u) }
        if let v { section?.tiltV = Self.wrapDegrees(v) }
    }

    /// Back to the picked plane's direction (the offset stays).
    func resetSectionTilt() {
        section?.tiltU = 0
        section?.tiltV = 0
    }

    /// Looks straight at the cut from the side that is cut away, the whole model in view.
    func lookAtSection() {
        guard let s = section else { return }
        let f = s.frame
        let plane = Plane(origin: s.center, normal: s.normal, xDir: s.flipped ? -f.u : f.u)
        var c = camera.looking(at: plane, center: s.center)
        if let b = visibleBodyBounds { c = c.framing(b, viewSize: viewSize, insets: viewInsets, margin: Self.bodyMargin) }
        camera = c
    }

    /// -180…180, so a grip turned round and round still reads as an angle.
    static func wrapDegrees(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 } else if x <= -180 { x += 360 }
        return x
    }

    // MARK: Viewport

    /// What cuts the viewport: the section that's on, not while a new plane is being picked
    /// (the whole model shows to pick from).
    var shownSection: SectionPlane? {
        guard let s = section, s.isOn, !choosingSectionPlane else { return nil }
        return s.plane
    }

    /// The arrow across the cut, pointing at the side cut away, and a grip for each tilt, out on
    /// the plane's two in-plane axes. In the selection blue: they steer the view, not a step.
    func sectionHandles() -> [Handle] {
        guard let s = section, s.isOn, s.isEditing else { return [] }
        let color = ViewportColor(hex: 0x3B8BFF)
        let f = s.frame
        let n = s.normal
        return [
            Handle(id: Self.sectionOffsetHandleID, origin: s.center - n * s.alongNormal, direction: n, value: s.alongNormal, color: color),
            // About the reference's u: the grip sits out along v, which that turn keeps in the plane.
            Handle(id: Self.sectionTiltUHandleID, origin: s.center, direction: f.v, value: s.tiltU, color: color,
                   kind: .rotation(axis: s.reference.u)),
            Handle(id: Self.sectionTiltVHandleID, origin: s.center, direction: f.u, value: s.tiltV, color: color,
                   kind: .rotation(axis: f.v)),
        ]
    }

    /// A section handle was dragged: the offset in 0.1 mm steps, the tilts in whole degrees.
    /// Returns false for other handles.
    func dragSectionHandle(id: String, value: Double) -> Bool {
        switch id {
        case Self.sectionOffsetHandleID:
            // The arrow reads along the cut's normal; the offset is along the picked plane's.
            guard var s = section else { return true }
            s.center = s.center + s.normal * (value - s.alongNormal)
            setSectionOffset((s.offset * 10).rounded() / 10)
        case Self.sectionTiltUHandleID: setSectionTilt(u: value.rounded())
        case Self.sectionTiltVHandleID: setSectionTilt(v: value.rounded())
        default: return false
        }
        sectionDrag = id
        return true
    }

    /// What the value pill on the canvas says: the offset, signed like the panel's field.
    var sectionOffsetLabel: String {
        "\(Self.sectionFormat(section?.offset ?? 0)) mm"
    }

    /// One decimal, as the arrow moves; a minus sign, not a hyphen.
    static func sectionFormat(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return ExprField.format(r == 0 ? 0 : r).replacingOccurrences(of: "-", with: "−")
    }

    /// What the hint over the viewport says while the handles are up.
    var sectionHint: String {
        #if os(macOS)
        "Drag the arrow to slide the cut, a curved grip to tilt it. Esc when done"
        #else
        "Drag the arrow to slide the cut, a curved grip to tilt it"
        #endif
    }
}

extension SectionReference {
    /// `p` moved along the normal onto the plane.
    func project(_ p: Vec3) -> Vec3 { p - normal * (p - origin).dot(normal) }
}
