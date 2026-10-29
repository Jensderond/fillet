import CoreGraphics
import Foundation

/// Keyboard modifiers held during an input event.
public struct ViewportModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = ViewportModifiers(rawValue: 1 << 0)
    public static let control = ViewportModifiers(rawValue: 1 << 1)
    public static let option = ViewportModifiers(rawValue: 1 << 2)
    public static let command = ViewportModifiers(rawValue: 1 << 3)
}

/// A key pressed while the viewport has keyboard focus (Mac), for typing sizes while drawing.
public enum ViewportKey: Hashable, Sendable {
    case tab(backward: Bool)
    case returnKey
    case deleteBackward
    case text(String)
}

/// A pointer sample delivered to the active tool (Pencil, finger with "draw with
/// finger", or the left mouse button on Mac).
public struct ViewportToolEvent: Sendable {
    /// World-space ray through the pointer.
    public var ray: Ray
    /// Pointer location in view points (origin top-left).
    public var location: CGPoint
    /// Normalised pressure 0…1 for Apple Pencil, nil otherwise.
    public var pressure: Double?
    public var modifiers: ViewportModifiers
    public var pointer: PointerKind
    /// What lies under the pointer with the current `PickFilter` (useful for snapping).
    public var hit: PickHit?

    public init(ray: Ray, location: CGPoint, pressure: Double? = nil, modifiers: ViewportModifiers = [],
                pointer: PointerKind = .mouse, hit: PickHit? = nil) {
        self.ray = ray; self.location = location; self.pressure = pressure
        self.modifiers = modifiers; self.pointer = pointer; self.hit = hit
    }
}

/// Receives viewport interaction. All methods have empty default implementations.
@MainActor
public protocol ViewportDelegate: AnyObject {
    /// When true, Apple Pencil (and the left mouse button, and fingers with
    /// `ViewportOptions.fingerDraws`) drive the `viewportTool…` callbacks instead of
    /// navigating. Fingers always keep navigating otherwise.
    var wantsToolInput: Bool { get }

    /// A tap/click. `target` is the picked element (nil = empty space). `pointer` says what made
    /// it, for ``SelectionRules``: a click replaces the selection, a touch adds.
    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers,
                        pointer: PointerKind)
    /// A second tap or click on the same element right after the first (which arrived as
    /// `viewportDidTap`): Fusion's double-click to select an edge's loop. `face` is the face under
    /// the pointer, which says which of an edge's two faces' loops is meant. Return false when a
    /// double tap means nothing there: the second tap then arrives as an ordinary tap.
    func viewportDidDoubleTap(target: PickTarget?, face: PickTarget?, location: CGPoint, modifiers: ViewportModifiers,
                              pointer: PointerKind) -> Bool
    /// A selection box was let go: `targets` is what it selects (see ``ViewportPicker/boxSelect``),
    /// `box` how it was drawn (its mode and what it does to the selection).
    func viewportDidBoxSelect(_ targets: [PickTarget], box: SelectionBox)
    /// The element under the pointer changed (mouse, trackpad pointer, Pencil hover).
    func viewportHoverChanged(target: PickTarget?)
    /// Pointer moved without a button/contact while a tool is active (rubber-band previews).
    func viewportToolHover(_ event: ViewportToolEvent)
    func viewportToolBegan(_ event: ViewportToolEvent)
    func viewportToolMoved(_ event: ViewportToolEvent)
    func viewportToolEnded(_ event: ViewportToolEvent)
    /// The system cancelled the stroke (e.g. a palm rejection or a gesture took over).
    func viewportToolCancelled()
    /// A handle is being dragged; `value` is the new (clamped) handle value.
    func viewportHandleDragged(id: String, value: Double)
    func viewportHandleDragEnded(id: String, value: Double)
    /// Right after `viewportHandleDragged`: when the handle steers the section, the plane and the
    /// handles as that step left them. The viewport draws them at once and keeps them over any
    /// scene that comes in until the drag ends, so a step moves the cut without a new scene (nil:
    /// the next scene shows what the step changed).
    func viewportSectionDragged(id: String) -> SectionDragStep?
    /// A press on `target` started moving while no tool takes the input. Return true to drag
    /// it (`viewportDragMoved` / `Ended` / `Cancelled` follow) instead of navigating. `event`
    /// is the press. A press that doesn't move stays a tap.
    func viewportShouldBeginDrag(target: PickTarget, event: ViewportToolEvent) -> Bool
    func viewportDragMoved(_ event: ViewportToolEvent)
    func viewportDragEnded(_ event: ViewportToolEvent)
    func viewportDragCancelled()
    /// The camera settled after a gesture or animation (also written to the binding).
    func viewportCameraChanged(_ camera: Camera)
    /// Apple Pencil double tap or squeeze (by convention: switch between the current tool and the last one).
    func viewportPencilToolSwitch()
    /// A finger orbited or tapped while the active tool wanted input and `fingerDraws` is off:
    /// someone may be trying to draw without Apple Pencil.
    func viewportFingerMissedTool()
    /// A key the viewport doesn't handle itself. Return true when it was used; otherwise it goes
    /// on up the responder chain (menu shortcuts, Escape).
    func viewportKeyDown(_ key: ViewportKey) -> Bool
}

public extension ViewportDelegate {
    var wantsToolInput: Bool { false }
    func viewportSectionDragged(id: String) -> SectionDragStep? { nil }
    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers,
                        pointer: PointerKind) {}
    /// A tap made in code (automation, demos): a touch, so it adds to the selection.
    func viewportDidTap(target: PickTarget?, hit: PickHit?, ray: Ray, location: CGPoint, modifiers: ViewportModifiers) {
        viewportDidTap(target: target, hit: hit, ray: ray, location: location, modifiers: modifiers, pointer: .touch)
    }
    func viewportDidDoubleTap(target: PickTarget?, face: PickTarget?, location: CGPoint, modifiers: ViewportModifiers,
                              pointer: PointerKind) -> Bool { false }
    func viewportDidBoxSelect(_ targets: [PickTarget], box: SelectionBox) {}
    func viewportHoverChanged(target: PickTarget?) {}
    func viewportToolHover(_ event: ViewportToolEvent) {}
    func viewportToolBegan(_ event: ViewportToolEvent) {}
    func viewportToolMoved(_ event: ViewportToolEvent) {}
    func viewportToolEnded(_ event: ViewportToolEvent) {}
    func viewportToolCancelled() {}
    func viewportHandleDragged(id: String, value: Double) {}
    func viewportHandleDragEnded(id: String, value: Double) {}
    func viewportShouldBeginDrag(target: PickTarget, event: ViewportToolEvent) -> Bool { false }
    func viewportDragMoved(_ event: ViewportToolEvent) {}
    func viewportDragEnded(_ event: ViewportToolEvent) {}
    func viewportDragCancelled() {}
    func viewportCameraChanged(_ camera: Camera) {}
    func viewportPencilToolSwitch() {}
    func viewportFingerMissedTool() {}
    func viewportKeyDown(_ key: ViewportKey) -> Bool { false }
}

/// Viewport behaviour switches.
public struct ViewportOptions: Hashable, Sendable {
    /// One-finger drags go to the active tool instead of orbiting (iPad "draw with finger").
    public var fingerDraws: Bool
    /// Animate when the camera binding is changed from outside (standard views, sketch entry).
    public var animatesCameraChanges: Bool
    public var cameraAnimationDuration: Double
    public var showsViewCube: Bool
    /// Measure labels and the bed name.
    public var showsLabels: Bool
    /// Force an appearance; nil follows the environment's colour scheme.
    public var appearance: ViewportAppearance?
    /// Parts of the view covered by floating chrome; "fit all" frames the model in the rest.
    public var contentInsets: ViewportInsets
    /// What the 3D view shows, for VoiceOver ("1 body, 80 × 30 × 12 mm; 4 edges picked").
    public var accessibilitySummary: String
    /// What a selection box picks (`.edges`, `.faces`, `.bodies`); empty: no selection boxes, so
    /// every drag navigates as before.
    public var boxFilter: PickFilter
    /// Box select mode: a one-finger or left-button drag draws a selection box instead of
    /// orbiting (two fingers, right-drag and ⌥-drag still navigate). Without it a box comes from
    /// Apple Pencil, or a drag with Shift or ⌘ held.
    public var boxSelects: Bool

    public init(fingerDraws: Bool = false, animatesCameraChanges: Bool = true, cameraAnimationDuration: Double = 0.35,
                showsViewCube: Bool = true, showsLabels: Bool = true, appearance: ViewportAppearance? = nil,
                contentInsets: ViewportInsets = .zero, accessibilitySummary: String = "",
                boxFilter: PickFilter = [], boxSelects: Bool = false) {
        self.boxFilter = boxFilter
        self.boxSelects = boxSelects
        self.fingerDraws = fingerDraws
        self.animatesCameraChanges = animatesCameraChanges
        self.cameraAnimationDuration = cameraAnimationDuration
        self.showsViewCube = showsViewCube
        self.showsLabels = showsLabels
        self.appearance = appearance
        self.contentInsets = contentInsets
        self.accessibilitySummary = accessibilitySummary
    }
}
