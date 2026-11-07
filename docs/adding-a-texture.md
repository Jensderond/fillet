# Adding a texture

A surface texture (knit, dots, …) is a height field over a face's surface. Adding one is **one
new file** in `Sources/FilletCore/Texture/Patterns/` plus **one line** in `TextureCatalog.patterns`.
Nothing else changes: the timeline step, the inspector, file coding, the MCP `texture` tool, the
export and the texture-lab harness all read the pattern's declarations.

| What | Where it comes from |
| --- | --- |
| Menu, swatch tile, timeline subtitle | `displayName`, `summary`, `symbol`, `height(at:)` |
| Inspector fields (length, angle, count, number, switch, menu) | `parameters` |
| Lit tiles for a choice (a dot's profile) | any `.choice` with 2–4 options that look different |
| A field shown only for some choices | `.shown(when:is:)` on the parameter |
| `.fillet` file | `{"type": "texture", "pattern": "<id>", "values": {"<parameter id>": "<expression>"}}` |
| MCP `texture` tool: pattern enum, `values` schema, description | `id`, `parameters`, `summary` |
| Range checks (inspector field and recompute) | `range` of each parameter |
| texture-lab `patterns`, `sample --pattern <id> --value id=expr` | the catalogue |
| Display and printed mesh, watertight, fade at borders, wall limit | `TextureEngine` |

## 1. Write the pattern

Create `Sources/FilletCore/Texture/Patterns/<Name>Pattern.swift` with a struct conforming to
`TexturePattern`:

```swift
public struct RibsPattern: TexturePattern {
    public static let id: TexturePatternID = "ribs"        // stored in files: never change it
    public static let displayName = "Ribs"
    public static let summary = "Rounded vertical ribs, like a fluted vase."
    public static let symbol = "line.3.vertical"            // SF Symbol
    public static let parameters: [TextureParameter] = [
        .length("pitch", "Rib spacing", default: 6, range: 1...60, help: "Distance between rib centres"),
        .number("width", "Rib width", default: 0.6, range: 0.1...1, help: "Width as a fraction of the spacing"),
        .length("depth", "Depth", default: 1, range: 0.05...8, help: "How far the ribs stand out"),
        .toggle("raised", "Raised", default: true, help: "Ribs stand out (off: flutes cut in)"),
    ]

    let pitch: Double, width: Double, depth: Double, raised: Bool

    public init(_ values: TextureValues) {          // every declared id is filled in
        pitch = values["pitch"]; width = values["width"]; depth = values["depth"]; raised = values.bool("raised")
    }

    public var cell: SIMD2<Double> { SIMD2(pitch, pitch) }   // one repeat in (u, v), mm
    public var amplitude: Double { depth }                  // largest |height|
    public var detail: Double { max(pitch * width / 8, 0.1) } // export edge length, mm

    public func height(at p: SIMD2<Double>) -> Double {     // mm along the outward normal
        let x = abs(p.x - (p.x / pitch).rounded() * pitch) / (pitch * width / 2)
        let h = x >= 1 ? 0 : (1 - x * x).squareRoot()
        return raised ? h * depth : -h * depth
    }
}
```

That struct and the catalogue line below are a complete, working texture: this exact `RibsPattern`
was built into a copy of the tree, textured a shelled vase through `texture-lab sample` and a cup
through the MCP tool, and both exports checked watertight.

### The rules `height(at:)` must keep

- **Coordinates** are millimetres of surface. On a face that turns around an axis (cylinder, cone,
  sphere, torus, revolved profile) `u` goes around it and `v` up the profile, so rows run around
  a vase and columns up it. On a flat face `u` is horizontal and `v` runs up the face (on a
  horizontal face u = world X, v = world Y). A ring of straight walls that meet smoothly (an
  extruded heart, a rounded box) shares one `u` along its outline. Any other face (the blend where
  two fillets meet, a fillet swept along a curved outline, a B-spline) uses its own surface
  parameters, measured in mm along the surface: `u` along a fillet's edge, `v` across its round
  (whichever runs more up the part), seen from outside `u` to the right and `v` up. Only a face
  the kernel can't sample falls back to a triplanar blend of the world planes.
- **Periodic over `cell`**: `height(p) == height(p + cell)`. Around a closed face the engine fits
  a whole number of `cell.x` repeats (stretching `u` slightly), so the seam is invisible only if
  the pattern repeats. The catalogue test checks this for every pattern.
- **Bounded by `amplitude`**: `|height| <= amplitude`. The engine budgets triangles and limits
  displacement near thin walls by it.
- **Positive raises, negative cuts in.** Fading to zero at face borders, keeping the bed flat,
  stopping short of the inside of a thin wall, keeping deep cuts clear of sharp corners and
  keeping the mesh closed are the engine's job,
  not the pattern's.
- **`detail`** is the triangle edge length for export: a fifth to a tenth of the smallest feature.
  Too coarse and edges come out ragged; too fine and a big part hits the 2.5 million triangle
  budget (the viewport uses 1.4 × detail and 400 000 triangles).

### Parameters

`TextureParameter` has six kinds: `.length` (mm), `.angle` (degrees), `.count`, `.number`,
`.toggle` (0/1, a switch) and `.choice([options])` (an index, a menu). Each has an `id`, a label,
a default, a range and a one-line help. Ids are what files store: **never rename or reuse one once
shipped**. A file missing a value takes the default; values a pattern doesn't declare are kept
untouched, so adding parameters later is safe. Every pattern also gets the shared `fade` ("Fade at
face border") from `TextureCatalog.common`; don't declare it yourself.

## 2. Register it

One line in `TextureCatalog.patterns` (`Sources/FilletCore/Texture/TexturePattern.swift`), in the
order the pattern picker shows them:

```swift
public static let patterns: [any TexturePattern.Type] = [
    KnitPattern.self,
    DotsPattern.self,
    RibsPattern.self,
]
```

A `public static let ribs: TexturePatternID = "ribs"` beside `.knit` and `.dots` in
`Sources/FilletCore/Model/Texture.swift` is optional sugar for tests; nothing requires it.

## 3. Check it

```sh
swift build -c release --product texture-lab
L=.build/release/texture-lab
$L patterns                                     # the new pattern and its parameters
$L sample --base vase --diameter 60 --height 80 --shell 2 --pattern ribs --value pitch=7 \
    -o ribs.fillet --3mf ribs.3mf --png ribs.png --camera hero
$L check ribs.3mf                               # PASS watertight manifold, …
scripts/slice-check.sh ribs.3mf                 # Bambu CLI slice
scripts/bambu-gui-check.sh ribs.3mf             # the real Bambu Studio (holds the GUI lock)
swift test --filter Texture                     # catalogue consistency, watertightness, coding
```

`patternsDeclareConsistentParameters` in `Tests/FilletCoreTests/TextureTests.swift` runs over every
registered pattern: unique ids, defaults inside their ranges, heights within `amplitude` and
periodic over `cell`, a swatch. Add a watertightness case for the new pattern to
`texturedCylinderIsWatertight`'s arguments.

## Optional hooks

Every hook has a default, so a plain pattern like the ribs above needs none of them.

| Hook | Default | Use it when |
| --- | --- | --- |
| `fitted(to:wraps:)` | unchanged | the pattern should adapt to each face: centre features, fit whole rows, drop cut-off ones |
| `fitted(to: TextureFace)` | `fitted(to:wraps:)` | features must stay inside a face that isn't a rectangle in (u, v), or off the seams where it meets another textured face smoothly: `clearance(at:)` is the distance to its nearest edge (`seamsOnly:` to its nearest seam) |
| `detail(at:)` | `detail` everywhere | only some places need fine triangles (a dot's rim) |
| `fitsAround` | `false` | `fitted` spaces the pattern around a closed face itself, so `u` stays plain arc length |
| `rims(lo:hi:scale:)` | none | a sharp round outline should be meshed along its own curve |
| `presented(_:)` | unchanged | relabel or condition parameters from a separate file |
| `fadesAtBorders(_:)` | `true` | the pattern keeps clear of face borders itself, so the fade field is hidden |
| `solid(over:)` | `nil` (per-face (u, v)) | features must run on unbroken across the edges between faces (a fillet next to a flat face, a corner blend): the pattern is laid out once in space over the whole textured surface |

### Laying a pattern out in space: `solid(over:)`

Each face gets its own (u, v), so where two faces meet smoothly (a fillet and the flat face it
rounds into, two fillets and the corner blend between them) two unrelated layouts butt together.
Nothing is pinned at a smooth edge, so a feature that crosses it is sliced by a straight seam
with a step. Knit and dots get away with it (knit runs along walls that share one mapping; dots
stay off seams). An irregular pattern that should cover a rounded box cannot.

`solid(over: TextureSurface)` returns a `SolidTexture`, or nil to stay on the per-face path. The
surface is every face of the texture step as triangles in space. `scatter(spacing:jitter:seed:)`
spreads points evenly over it: fixed in space, so they don't change with the tessellation, and
two sides of a thin wall (normals more than 120° apart, `TextureSurface.opposite`) don't crowd
each other out. Each lattice point is dropped straight onto a triangle below or above it, never
clamped onto a triangle's edge: clamping piled whole wedges of space onto the convex folds of the
tessellation (a fillet's facets, a tight curve, the surface's border), and the seeds lined up
there into straight seams and sliver stones. Points are kept no nearer than the spacing along
the surface (`surfaceDistanceSquared`, not the shorter chord round a curve), and candidates on a
tight convex bend go first (`bendPriority`), so stones wrap a rounded corner like quoins instead
of a joint running down it. Its `detailScale` is how much coarser than
asked the mesh comes out (1 for export, about 2 for the viewport). A pattern can widen features
that mesh can't follow, so they render smooth rather than frayed. The engine then calls
`SolidTexture.height(at:normal:)` and `detail(at:normal:)` with each point in space and the surface's
normal there, for every face of the step, instead of the per-face mapping. Fading at sharp edges
and untextured faces, the thin-wall limit and fold relaxing work as for any pattern.
`height(at:)` in (u, v) is still required: the inspector swatch draws it.

The triangle budget treats a solid pattern differently. Other patterns get every triangle capped at
the length a uniform mesh would need to fit. A solid pattern's `detail(at:normal:)` keeps its
proportions instead: a trial subdivision 1.6 times coarser measures how many triangles it needs,
and when that is over the budget every wanted length grows by the same factor. A uniform cap made
the viewport's stone edges no finer than their tops, and they frayed. The crease flips
(`alignCreases`) skip solid patterns' faces: their relief has no creases, and the flips chained
into fans of needle triangles that shaded as spikes along the stone edges.

Optionally, `contour(at:normal:)` returns a smooth measure along the surface whose level lines
`contourLevels` the relief bends along (flagstone: the distance into a stone across its edge
round). Before displacing, the engine slides points within about a third of an edge of a level
line onto it, so the triangles run along the bend instead of zigzagging across it (which shades
as a saw-toothed fringe, worst on the viewport's coarser mesh). The default (nil) leaves the mesh
as subdivided.

Points of a solid pattern are cut along their surface normals averaged over about the pattern's
`amplitude` in space (a kernel blend's normals jitter by a degree between points microns apart),
and a cut is kept within `cutSlope` times its straight distance from a sharp or untextured edge
(`cutLimit(at:amplitude:)`): the limit rises from the edge along a smootherstep, level at both
ends, and the cut is rounded into it, so a joint running into the bed or a rim ramps out
smoothly instead of ending in a saw-toothed line.

## Worked example: knit (`KnitPattern.swift`)

Knit uses the minimum plus two hooks.

- **Parameters**: `stitchWidth`, `stitchHeight`, `depth` (lengths), `yarn` (a number, 0.6–1.4),
  `raised` and `cutEdges` (toggles). The inspector shows them as fields and switches; the MCP tool
  accepts `{"stitchWidth": 3.4, "raised": false}`.
- **`cell`** is one stitch (`stitchWidth` × `stitchHeight`); **`amplitude`** is
  `depth × 1.9`, because the crevices between the yarn legs sink 0.9 × depth below the surface.
- **`height(at:)`** builds each V from two leaf-shaped legs in stitch-local coordinates, takes the
  two highest, rounds the crease between them, and fillets their feet into the surface.
- **`fitted(to:wraps:)`**: around a closed face (a bowl, or a ring of walls like the heart box) it
  changes `rowHeight` so a whole number of rows runs from the bottom edge to the top, and records
  the face length so stitches settle into the surface near both edges (unless `cutEdges`). A band
  narrower than 1.3 rows (a rounded rim) is finished as a twisted rope instead.
- **`detail(at:)`** asks for 0.65 × detail along the steep flanks of the legs, where coarse
  triangles would leave a saw-tooth, and the plain detail elsewhere. That keeps a 160 mm bowl under
  a million triangles.

## Worked example: dots (`DotsPattern.swift` and `DotsPattern+Presentation.swift`)

Dots use most hooks, because a flat disc needs a crisp, round, whole outline.

- **Parameters**: `diameter` (default 20 mm), `spacing`, `rowSpacing`, `height` (1 mm),
  `profile` as a `.choice(["Soft dome", "Round cap", "Flat disc"], default: 2)`, `edge` (the flat
  disc's top-edge round, 0.3 mm), and the `raised`, `stagger` and `whole` toggles. Because
  `profile` is a choice whose options look different, the inspector shows it as lit tiles with no
  extra code.
- **`fitsAround = true`** and **`fitted(to:wraps:)`**: around a closed face the dots are spaced so a
  whole number fits without stretching (the engine then leaves `u` as plain arc length, so discs
  stay round), and with `whole` the rows are centred on the face and dots its edges would cut are
  left out. `fitted(to: TextureFace)` also drops dots that come closer than the margin to any edge
  of the face's real outline, so a fillet trimmed by a corner blend, or a face with a hole, keeps
  whole dots too. Without `whole` it still drops the dots that would straddle a seam (each face
  lays its dots out on its own, so such a dot would be cut in two, with a step, under its
  neighbour's dots); only the textured area's outer edges cut dots. The disc's side is laid along its own axis on a curved wall (`wrapRadius`).
- **`detail(at:)`** is coarse on the disc top and the plain wall and fine only near the rim.
- **`rims(lo:hi:scale:)`** returns each flat disc's outline (foot, top of the side, the steps of
  the edge round) as rings the engine meshes along, so the foot is a clean circle rather than a
  stair-step across the triangles.
- **`presented(_:)`** (in `DotsPattern+Presentation.swift`) renames `edge` to "Rim rounding" and
  shows it only while the profile is Flat disc, via `.shown(when: "profile", is: 2)`. The catalogue
  only accepts a presentation that keeps every id, kind, default and range, so it can never change
  what files store.
- **`fadesAtBorders(_:)`** returns `!whole`: whole dots never reach a border, so the fade field is
  hidden.

## Worked example: flagstone (`FlagstonePattern.swift` and `FlagstonePattern+Solid.swift`)

Flagstone lays irregular stones over everything, fillets and corner blends included.

- **`solid(over:)`** scatters one seed per stone over the surface (`scatter`, spacing 0.83 ×
  `size`). Each stone is the part of the surface nearer to its seed than to any other. A point's
  distance to its stone's outline is measured to the bisector with each neighbouring seed, in
  the surface's tangent plane, with every seed first unfolded into that plane
  (`TextureSurface.unfold`: as far away as the way along the surface, exactly so round a
  cylinder). With the seeds as they are in space, round a tight corner the distance came out short
  on one side of a joint and long on the other, and the edge round was squeezed into a crease.
  The corners are rounded by a disc (`rounded`: the outline opened
  by a circle reaching just past the top of the edge round, so a sharp corner ends in a round
  rather than a low wedge melting into the joint). Seeds facing away
  from the point by more than `TextureSurface.opposite` (the far side of a thin wall) count as
  farther, smoothly, so they never cut a stone off; seeds round a convex corner or a tight curve
  count at their plain distance.
- **Sampled along smoothed normals.** The engine smooths the kernel's normals under a layout in
  space before sampling it (`smoothDirections`: a plane fitted per face, so a flat face's normals
  stay true where it meets a fillet), evens out the jump in curvature where a flat face meets a
  fillet (`fairing`: a crisp line across every stone otherwise), and removes slivers along face
  edges (`dissolveSlivers`) before cutting.
- **The profile** across a joint (`shoulder`) rises with its curvature half a sine wave up over
  the first 35 % of the edge round (the foot, down in the joint) and a longer, gentler one down
  over the rest (the shoulder onto the top): no kink and no jump in curvature where it leaves the
  joint floor or meets the stone top. The shoulder is what catches the light, so it gets the room:
  at the defaults (2.5 mm edge, 1 mm deep) it bends over onto the top at a radius of about 1.9 mm
  and is at most 35° steep. A symmetric smootherstep over the old 1 mm default bent at 0.4 mm,
  about two triangles, and rendered as a dotted line along every crest; at 1.5 mm (0.9 mm, 47°)
  the highlight along the crest still traced every stone with a hard bright line. The round
  is widened by two triangles (`softeningSteps`), at export and at the viewport's coarser detail
  (`detailScale`) alike.
- **`contour(at:normal:)`** is the distance into the stone, with level lines where the round
  leaves the floor, where the foot bends most, where it turns into the shoulder, in quarters
  across the shoulder, and where it meets the top.
- **`detail`** is the coarse size for the stone tops, and **`detail(at:)`** /
  `detail(at:normal:)` is fine (a ninth of the joint or edge, whichever is smaller) across the
  edge round and grows quickly away from it.
- **The grain** on the stone tops (`roughness`) has its fine octave at a fifth of a stone, so
  the slope changes by under a degree across one of the tops' triangles. At a ninth it changed
  by 1.7°, and seen at a glancing angle the tops shaded as streaks along the triangles' rows.
- **`height(at:)`** in (u, v) is a jittered-grid version of the same stones, for the swatch.

## What a pattern never touches

- `Texture` (the step), `FeatureKind` coding, `ModelEvaluator`: a texture step stores the pattern
  id and a `[parameter id: expression]` dictionary, whatever the pattern.
- `TextureInspector`, `FilletTools.texture`, `texture-lab`: they list `TextureCatalog.patterns` and
  build fields, schema and help from `parameters`.
- `TextureEngine`: subdivision, rims, fading, the thin-wall limit, fold relaxing and welding work
  on any height field.

A file naming a pattern this version doesn't know still opens and saves it unchanged; its step
reports that it needs a newer Fillet, and the inspector offers the known patterns instead.
