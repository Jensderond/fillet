# Fillet — design

A native, offline, parametric CAD app for designing 3D‑printable parts on
iPad Pro (touch + Apple Pencil) and Mac. Kernel: OpenCascade 8.0.1.

## Why

The owner prints on Bambu Lab printers (A1 mini among them) and designs
functional parts in Fusion 360 free: holders, hangers, clips, adapters,
brackets, typically 6–150 mm, prismatic (sketch → extrude → fillet → holes),
sometimes parametric ("RadiatorHookParametric_22-22", "dimmer-adapter-6mm-4mm").
Pain points with Fusion: it requires being online, and its cloud
project/file model gets in the way. They have also used Shapr3D (iPad).

Success = they can design a part like their toothpaste holder or tacker
hanger end to end on the iPad or Mac, offline, save it as a normal file in
iCloud Drive / Files, and send a 3MF to Bambu Studio.

## Goals

- Parametric, Fusion-style workflow: sketch on a plane or face → features
  (extrude, revolve, fillet, chamfer, shell, booleans, mirror, pattern,
  move) in an editable **timeline**, with named **parameters** and
  expressions (`width/2 + 3`).
- One design = one `.fillet` document file. Native document handling
  (`DocumentGroup`): Files app, iCloud Drive, recents, autosave, undo.
  No account, no network, ever.
- 3D‑print first: printer bed presets (A1 mini 180³, A1 256³, P1S/X1C 256³,
  H2D 325×320×325), fits-on-bed indicator, overhang highlight (> 45°
  configurable), lay‑flat on a face, validity/watertight check,
  export **3MF** (one object with a part per body, mm), **STL**, **STEP**; import STEP.
- First-class iPad: Pencil draws/selects, fingers navigate; big touch
  targets; numeric entry that works with on-screen keyboard. Mac: mouse,
  trackpad, keyboard shortcuts.
- Fast: Metal viewport, recompute off the main thread.

## Non-goals (v1)

- Full geometric constraint solver (sketch shapes are parametric primitives
  with numeric/expression dimensions instead; solver is v2).
- Assemblies/joints, drawings, CAM, rendering, cloud sync, collaboration.
- Windows/Linux/Android.
- Mesh (STL) editing.

## Anti-goals

- Anything that needs an account or network connection.
- Hiding files inside an app database / "projects".
- A desktop UI shrunk onto the iPad (tiny targets, hover-only affordances).

## Architecture

```
fillet/
  Package.swift              SwiftPM package "FilletKit" (all non-UI-shell code, testable with `swift test`)
  Sources/
    CFilletKernel/           C++ (OpenCascade) behind the C API in include/FilletKernel.h
    FilletKernel/            Swift wrapper: Shape, Mesh, Plane, errors
    FilletCore/              Document model, sketch, features, parameters, recompute, exporters
    FilletViewport/          Metal renderer + camera + gestures + picking (SwiftUI view)
  Tests/                     XCTest/Swift Testing per module
  App/                       SwiftUI multiplatform app (iPadOS + macOS), XcodeGen project.yml
  vendor/OCCT.xcframework    OCCT.framework (one dynamic library, LGPL) per platform, built by
                             scripts/build-occt.sh with scripts/occt-patches applied (gitignored)
```

Deployment targets: iPadOS 18, macOS 15. Swift 6 language mode, Xcode 27.

### Kernel (CFilletKernel + FilletKernel)

Contract: `Sources/CFilletKernel/include/FilletKernel.h` (authoritative).
C++ implementation catches every `Standard_Failure` / std exception and
turns it into NULL + `fk_last_error()`; it must never crash the app on bad
input (degenerate profiles, fillet radius too big, etc.).

Swift wrapper (FilletKernel module), shape of the API:

```swift
public struct KernelError: Error { public let message: String }
public struct Vec3: Hashable, Codable, Sendable { x, y, z: Double  + math ops, length, normalized, cross, dot }
public struct Plane: Hashable, Codable, Sendable { origin, normal, xDir: Vec3; yDir; point(u:v:) -> Vec3; project(_:) -> (u,v);
                                                  static xy, xz, yz }
public final class Shape: @unchecked Sendable {   // owns FKShape*, freed in deinit
  static func box(corner:size:) throws -> Shape, cylinder(base:radius:height:), sphere, cone, torus
  func extruded(along:distance:back:taper:) throws, revolved(axisOrigin:axisDir:angle:)
  func fused(with:), cut(by:), common(with:)
  func filleted(edges:[Int], radius:), chamfered(edges:distance:), shelled(removing:[Int], thickness:)
  func transformed(_ m: Transform), mirrored(across: Plane)
  var faceCount, edgeCount; func faceInfo(_:) -> FaceInfo; edgeInfo(_:) -> EdgeInfo; facePlane(_:) -> Plane?
  var bounds: (min: Vec3, max: Vec3)?; volume; surfaceArea; isValid; solidCount; solids() -> [Shape]
  func distance(to:) -> (distance, Vec3, Vec3)?
  func tessellate(linearDeflection:angularDeflection:) throws -> Mesh
  static func importSTEP(url:) throws -> Shape; static func exportSTEP([(Shape,String)], url:) throws
  func brepString() -> String; static func fromBRep(String) throws -> Shape
  static func compound([Shape]) throws -> Shape
}
public enum Segment2D: Hashable, Codable, Sendable { line(a,b), arc(start, through, end), circle(center, radius), bspline([SIMD2<Double>]) }
public final class SketchRegions { init(plane:segments:) throws; count; region(containing:) -> Int?; interiorPoint(_:) -> SIMD2<Double>; profile(indices:) throws -> Shape; outline(i) for display = tessellated face }
public struct Mesh: Sendable { positions: [SIMD3<Float>]; normals: [SIMD3<Float>]; indices: [UInt32]; triangleFaces: [Int32]; edges: [[SIMD3<Float>]] }
public struct FaceInfo, EdgeInfo   (mirror the C structs)
```

### Core (FilletCore)

**Document** (`Codable`, value type, saved as pretty JSON inside the
`.fillet` file — a single flat file, UTType `app.fillet.document`,
conforms to `public.json`, exported type):

```
Document { formatVersion, name?, units = mm, printer: PrinterPreset.ID,
           parameters: [Parameter{id, name, expression, comment}],
           features: [Feature], rollbackIndex: Int?  (timeline marker; nil = end) }
Feature  { id: UUID, name, suppressed: Bool, kind: FeatureKind }
FeatureKind =
  .sketch(Sketch)                                  // plane: .standard(xy|xz|yz, offset expr) or .face(FaceRef) ; shapes
  .extrude(Extrude{ sketch: UUID, regions: [RegionRef], distance: Expr, back: Expr?, symmetric, taper: Expr,
                     operation: .newBody | .join | .cut | .intersect, targets: [BodyRef] })
  .revolve(Revolve{ sketch, regions, axis: .sketchLine(entity id) | .x | .y, angle: Expr, operation, targets })
  .fillet(EdgeFeature{ body, edges: [EdgeRef], size: Expr }), .chamfer(...)
  .shell(Shell{ body, removeFaces: [FaceRef], thickness: Expr })
  .primitive(Primitive{ kind: box|cylinder|sphere|cone|torus, placement plane, dims: [Expr], operation, targets })
  .combine(Combine{ target: BodyRef, tools: [BodyRef], operation, keepTools })
  .move(Move{ bodies, translation [Expr x3], rotation axis+angle })
  .mirror(Mirror{ bodies, plane: .standard | .face(FaceRef), merge: Bool })
  .pattern(Pattern{ bodies, .linear(dir, count, spacing) | .circular(axis, count, angle) })
  .importedSTEP(name, brep: String)
  .layFlat(LayFlat{ body, face: FaceRef })        // print-orientation helper: rotates the body so face is on bed
```

Expressions: `Expr` stores the user string; evaluated with parameters
(`+ - * / ^ ( )`, units suffix `mm`/`cm`/`in`/`deg`, functions `sqrt sin cos
tan min max abs round`). A bare number is mm (or degrees for angles).

**Bodies**: a body is identified by the UUID of the feature that created it
(`BodyRef = UUID`). Join/cut/intersect modify target bodies in place.

**Persistent references** (topological naming): `FaceRef`/`EdgeRef` store
`{ body, signature }` where signature = surface/curve type + centroid/mid
point + normal/tangent + area/length (+ radius). Recompute resolves each ref
to the best match in the current shape (same type, nearest point, scored
with normal/tangent alignment and size similarity; reject if beyond
tolerance → feature error "reference lost"). `RegionRef` stores an interior
point in sketch coordinates.

**Sketch**: `Sketch { plane, shapes: [SketchShape] }` where each shape is
parametric with `Expr` dimensions:
`line(a, b)`, `polyline(points, closed, arcs-between flags via bulge)`,
`rectangle(corner|center, w, h, angle)`, `circle(center, d)`,
`arc(3 points)`, `polygon(center, sides, radius, inscribed)`,
`slot(a, b, width)` (common for prints), `spline(points)`, `point`.
Every shape has `construction: Bool`. Points are `Point2Expr {x: Expr, y: Expr}`.
`SketchShape.segments(eval) -> [Segment2D]` feeds `SketchRegions`.

**Recompute** (`Model`/`Evaluator`, runs on a background actor): walks
features up to the rollback marker, producing `EvaluatedModel { bodies:
[UUID: Shape], sketches: [UUID: EvaluatedSketch(plane, segments, regions)],
featureErrors: [UUID: String] }`. A failing feature records its error and
is skipped; later features still run. Cache per-feature results keyed by
(feature, inputs hash) so editing the last feature doesn't redo everything.

**Print**: `PrinterPreset` list (A1 mini, A1, P1S, P1P, X1C, X1E, H2D,
custom), `PrintAnalysis` (bounds vs bed, overhang triangles by angle,
validity, solid count, volume → grams by PLA density 1.24 g/cm³).

**Export**: `ThreeMFWriter` (minimal ZIP writer, stored entries + CRC32,
3MF core spec, one `<object>` per body, unit millimeter, items placed on the
bed centre), `STLWriter` (binary), STEP via kernel. Tessellation for export
uses a finer deflection (0.01 mm linear, 0.1 rad) than display.

### Viewport (FilletViewport)

Pure rendering + input; knows nothing about features. Contract:

```swift
public struct ViewportScene {
  var bodies: [SceneBody]             // id: UUID, mesh: Mesh, color, opacity, visible, highlight
  var previews: [SceneBody]           // translucent feature previews
  var sketch: SketchOverlay?          // plane, curves [[SIMD3]] with style (normal/construction/selected/hover),
                                      // points, filled regions [triangulated polygons] with selected flags
  var plate: BuildPlate?              // size, name (drawn as bed outline + grid)
  var selection: Set<PickTarget>, hover: PickTarget?
  var overhang: OverhangStyle?        // threshold angle; tints downward-facing triangles red
  var handles: [Handle]               // draggable arrows (e.g. extrude distance), id, origin, direction, value
  var referencePlanes: [ReferencePlane] // pickable translucent plane patches (origin planes while choosing a sketch plane)
  var pickableFaces: [UUID: Set<Int>]?  // restricts face picks (flat faces only while choosing a sketch plane)
}
public enum PickTarget: Hashable { face(body: UUID, index: Int), edge(body: UUID, index: Int),
                                   region(Int), sketchShape(UUID), sketchPoint(UUID, Int), handle(String),
                                   referencePlane(String) }
public struct ViewportView: View { init(scene:, camera: Binding<Camera>, filter: PickFilter, delegate: ViewportDelegate) }
public protocol ViewportDelegate { tap(target: PickTarget?, ray: Ray, modifiers)
                                   toolDragBegan/Changed/Ended(ray: Ray)    // Pencil / left-mouse in tool mode
                                   handleDragged(id, value) ; hoverChanged }
public struct Camera { target, distance, yaw, pitch, projection (.perspective/.orthographic), fov;
                       standard views; fit(bounds) }
```

Rendering: shaded triangles with a soft studio lighting + hemisphere
ambient, crisp edges (screen-space thick lines), silhouette-friendly, MSAA
4×, depth bias so edges sit on faces, transparent previews, infinite-feel
grid + bed rectangle, sketch overlay drawn on top with depth test off for
points. Picking on the CPU: ray vs triangles (BVH per body) for faces,
screen-space distance to edge polylines (tolerance 8 pt touch / 4 pt mouse).

Section cuts (`ViewportScene.section`) discard everything on the plane's cut-away side in the
shaders and close every opaque solid they open with a cap, drawn right after the opaque bodies
with the stencil buffer (`depth32Float_stencil8`). Per body: what is left of its surface is drawn
without colour or depth test, flipping a stencil bit per layer, so the bit ends up set where the
plane lies inside the solid (closed meshes; parity, so cavities, enclosed channels and crossing
bores come out open); then a polygon on the plane (where it crosses the body's bounding box) is
drawn where the bit is set, with a small depth bias so a face lying in the plane doesn't fight it;
then the surface again clears that bit for the next body. The cap also sets a second stencil bit
where it is drawn, and the outline where the plane meets each body (sliced from its triangles on
the GPU, then the kernel's exact lines once the plane settles) only draws where that bit is clear:
it runs round a cap and never over it, so a 0.8 mm wall keeps its whole width. Caps of
default-coloured bodies take a cut colour each (the section red, then slate, plum, ochre, teal,
olive, mixed into the body grey) and a body with its own colour keeps it, so nested parts read as
parts; each also hatches at its own angle (45°, 135°, 15°…). The hatch is a hairline at one
spacing over the whole cap, a power of two in world units nearest 5 pt where the view looks (the
camera's target moved onto the cap), so it stays put on the part, steps only when zooming, and
never shows faint lines between the real ones. Caps are half lit in 3D. Silhouettes and edges are
cut with the body, not dropped, and so is the contact shadow (it is of the kept part's box).
`ViewportScene.sectionOnly` draws the caps and nothing else of the bodies; `sectionDrawing` is a
2D section view: caps flat, what's left of the bodies laid down in depth only (the background
shows) with its edges and silhouettes in the line colour, no hidden edges, ground, bed or shadow.
Picks clip the ray to the kept side: what is cut away can't be picked or hide anything, and a ray
that enters a body through the plane hits its cap, which picks the body but no face.

Input:
- iPad: 1 finger drag orbit, 2 finger drag pan, pinch zoom, two-finger double‑tap
  fit; tap = pick. Apple Pencil (or a finger when "draw with finger" is on)
  goes to the active tool; with no tool, a Pencil drag draws a selection box.
- Mac: left click pick / tool, right‑drag or option‑drag orbit, middle-drag
  or shift‑right‑drag pan, scroll / pinch zoom, two-finger trackpad scroll pan.
  Shift‑ or ⌘‑drag draws a selection box.

### Selection

The conventions live in `SelectionRules` (FilletViewport), so taps, clicks and boxes agree:

- **Click replaces, touch adds.** A mouse or trackpad click replaces the selection, like Fusion
  and the Finder; Shift- or ⌘-click toggles. A finger or Pencil tap toggles: touch has no modifier
  keys, so it keeps adding (Shapr3D's convention). A hardware keyboard's Shift/⌘ toggles on iPad
  too. A tap or click on empty space clears (with a modifier held, nothing). While a step picks
  (Fillet, Shell…), every tap toggles, as in a Fusion command. Selecting is never an undo step.
- **Tangent chain.** Fillet and Chamfer have Fusion's "Tangent chain", on for new steps: a picked
  edge brings every edge joined to it with G1 continuity (the kernel's `fk_tangent_chain`: vertex
  → edge adjacency, curve tangents compared at shared vertices within 2°, seams stop a chain). The
  step stores the pick as a seed plus `tangentChain: true` and grows the chain again on every
  recompute, so a chain that gains edges upstream (a corner rounded later) is still rounded
  whole; files without the key read as `false` and save unchanged. Turning it off turns each
  chain into its edges, picked singly, so nothing rounded changes.
- **Loop.** A double tap or double click on an edge picks the loop of the face beside it under
  the pointer (a face's wire, `fk_face_loops`); the second tap replaces what the first did.
  *Select more ▸ Tangent chain / Loop* in the inspector does the same from the last picked edge.
- **Box select.** Left to right takes what is wholly inside (window), right to left anything it
  touches (crossing), as in Fusion. A Pencil drag, a Shift/⌘-drag, or any one-finger/left drag
  with *Box select* (W) on draws one. On iPad a finger box ends Box select, so one finger orbits
  again; on the Mac it stays on (right-drag orbits). Outside a step the bar chooses edges, faces
  or bodies; in a step the step's kind. Only what can be seen is taken, like a single pick: hidden
  bodies and geometry behind faces are left out (edges are sampled every ~4 pt and ray-tested,
  faces by a ray grid over the box). What the box would take lights up while dragging, with a
  count on its tag.

### App

`DocumentGroup(newDocument:)` with `FileDocument` (`.fillet`). Main window:

- Top toolbar: undo/redo, tool groups (Sketch | Create | Modify | Inspect |
  Print), printer picker, Export menu.
- Left sidebar (collapsible): Bodies (visibility toggles), Sketches,
  Parameters.
- Bottom: timeline of features (tap to edit, drag rollback marker,
  right-click/long-press: suppress, delete, rename).
- Right inspector: the active feature's fields (expressions), OK/Cancel.
- Viewport fills the rest; view cube / standard-view buttons top right.

Sketch mode: enter by choosing a plane or planar face, like Fusion. With a
flat face selected, Sketch opens on it; otherwise the viewport shows the three
origin planes (translucent, tinted by the axis they face along: XY blue, XZ
green, YZ red; the bed square plus two upright planes standing on it) and only
flat faces react, so a tap on a plane or a flat face opens the sketch there.
A face seen through a plane wins the tap; curved faces still hide what is
behind them. A bar over the viewport names what to pick and has XY / XZ / YZ
buttons (for planes hidden in the part or seen edge-on, and for VoiceOver) and
Cancel (Esc). Camera animates to look at the chosen plane; sketch toolbar (line, rectangle, circle, arc, polygon, slot,
spline, construction toggle, finish). After drawing, the inspector shows the
shape's dimensions for exact entry.

With Select, dragging a shape (or its midpoint or centre) moves every selected
shape. Dragging a vertex (a line's start or end, a polyline's or spline's
point; FilletCore `SketchVertex`) moves only that point, and the ends of other
shapes joined to it go along, so a chain of lines stays closed. A tap on a
vertex selects just it (drawn as a selected point, its line selected for the
inspector); a tap on its line then selects the whole line. A dragged end lines
up with its line's other end (a level or upright line) but never lands on it:
a line can't shrink to nothing. Each drag is one undo step ("Move Point").

Snapping, shared by every drawing tool and by dragging shapes with Select
(FilletCore `SnapTargets` → `SnapContext.resolve`, drawn by the viewport as
`SketchOverlay.guides` / `markers`): in priority order, points (endpoints,
centres, sketch points and crossings of curves), midpoints and quadrants,
horizontal/vertical alignment with any vertex, then the extension of a
straight edge past its ends, then the grid. Where two guides cross near the
pointer it snaps to the crossing (level with one vertex, under another).

Edges of the bodies that lie in the sketch's plane snap too, like the face
edges Fusion brings into a sketch on a face (FilletCore `SnapReference`): the
outline and holes of the face a sketch is on, or the outline a part leaves on
the bed. Their corners, midpoints, hole centres and quadrants are snap points,
alignment guides come from them, straight edges extend, and sketch curves
crossing them give crossings. The ends of edges that only touch the plane (an
upright edge's foot) are points too. Only visible bodies count, as they were
just before the sketch, so editing an early sketch doesn't snap to what later
steps made. They are snap targets only: never drawn, saved or used as profiles.

The radius is the pointer's pick tolerance on screen (finger 10 pt, Pencil 6 pt,
mouse 5 pt, × 1.5; guides catch within ¾ of that), so it feels the same at
every zoom. A snap holds until the pointer is 1.5 radii away or a better kind,
or one a quarter radius closer, takes over, so it doesn't flicker. Guides are
thin dashed orange lines with a small ring on the vertex they come from; the
snapped point gets a marker by kind (square endpoint, triangle midpoint, ×
crossing, diamond quadrant, ring centre). They are feedback only: never picked,
saved or undone, and gone when the gesture ends. `SnapTargets` is built once per
change to the sketch, its parameters, its plane or the bodies (points sorted by x
and y, so a pointer event only looks near it). `FILLET_SCENARIO=snapping` and the `FilletUITests` scheme exercise it on iPad.

Section view (`App/Sources/Session/Section.swift`, after Shapr3D's): Section on the tool strip,
⇧⌘X or *View ▸ Section View* cuts the model open. With a flat face selected it cuts right on that
face; otherwise the viewport offers the origin planes and flat faces like choosing a sketch plane
(bar with XY / XZ / YZ and Cancel). The picked plane's normal is turned towards the camera, so
what faces the viewer is cut away and the inside shows. An origin plane that misses the part (a
part standing on the bed, or beside the plane) starts the cut through the part's middle instead,
so picking always shows a cut; a face starts right on it. Then, with the panel in the inspector:

- An arrow across the cut (in the selection blue: it steers the view, not a step) slides it; the
  offset reads in a pill past the arrow's head, live while dragging, and a tap on the pill types
  one (an expression, like every field). The offset is the handles' distance from the picked plane
  along its normal, positive towards the side cut away, in 0.1 mm steps.
- Two curved grips, out on the plane's in-plane axes, tilt it about the handles' point (whole
  degrees; first about the picked plane's level axis, then about the axis that turned to). Tilting
  never moves that point, so the offset reads the same through a tilt. The grip's angle shows
  beside it while it turns.
- A round button behind the arrow's base flips the side cut away; the plane stays where it is.
- Pressing a handle shows it's held before it moves: it grows and takes a halo, the arrow shows the
  line it slides along (dashed, both ways) and the pill fills in blue. A turning grip shows a dashed
  ring round the handles' point with a solid arc from where it reads 0°, and its angle at the arc's
  end. Let go, a tilt that isn't 0° keeps its angle in a pill under the offset's; a tap types one.
- The panel types the offset and both tilts, changes the plane, untilts, and *Look at the cut*
  turns the camera straight at it from the cut-away side.
- *2D section view* (panel, or *View ▸ 2D Section View*) turns the camera orthographic and straight
  at the cut from the side cut away, framing what's left, and draws it as a section drawing:
  caps flat and hatched with a line round each, the rest of the model as lines, no bed or grid.
  The handles go (they'd be end-on); the pills and the panel steer it, and a flip or typed tilt
  turns the view with the cut. Off goes back to the camera before it.
- *Section only* draws the caps and nothing else, in 3D or 2D. Both looks end with the section.

It is view state, like Measure: never a step, never in the document or the undo history, and the
plane stays put in the world while orbiting. Escape or Done puts the handles away and keeps the
cut, with a pill over the viewport (Edit, Turn off); other tools and steps take over the handles
but keep the cut. The tool turns it off and later back on at the same plane (Delete forgets it).
A section drag doesn't rebuild the scene: each step goes from the viewport controller straight to
the renderer, which moves the section uniform (the stencil caps follow on the GPU) and slices the
outline from the meshes on the GPU too, and the view draws once a display refresh while the handle
is held. Only the panel and the pill redraw around it (the mode is kept apart from the plane, so
the rest of the editor doesn't). When the plane holds still for 0.12 s, or is let go, the kernel
cuts each body with it off the main thread (`fk_section`) and those exact lines, split to about
half a pixel, replace the mesh's outline; a step drops a fetch still running. The frog (159k
triangles) drags at 60 frames/s with no scene rebuilt; see `docs/performance.md`.

## Milestones

1. Foundations: OCCT xcframework, package wiring, kernel bridge + tests, app
   shell building for iPad + Mac.
2. Core model + recompute + exporters (tests), Metal viewport.
3. App integration: documents, sketch mode, extrude, timeline, fillet/
   chamfer/shell, export 3MF → first usable build.
4. Print tools (bed, overhangs, lay flat, analysis), parameters UI,
   revolve/mirror/pattern/move/primitives, STEP import, polish.
5. v2: constraint solver, sketch on face projection, threads, text.
