# MCP agent feedback backlog (2026-10-28)

An agent that modelled an iPad stand through the MCP server reported eight sources of friction.
Items 1 (re-pointing fillets), 3 (close-ups and sections) and 4 (hiding bodies) are being worked
on. The other five are logged here, with what a first look at the code found.

## 2. Sketch offset over MCP

**Report:** sketches have no offset, so the agent worked out inset curves by hand. It needed the
back curve (a spline) moved 1.5 mm inward and its first guess came out too shallow. It also wasn't
sure whether expressions take `cos(25deg)`.

**Found:**
- Expressions already handle this: `sin cos tan asin acos atan` take angles with `deg`, `rad` or `°`
  (`Sources/FilletCore/Expressions/ExprFunctions.swift`). The server instructions don't say so,
  which is why the agent typed constants like `slot*0.9063`.
- The core already has offset: `OffsetChain` in `Sources/FilletCore/Sketch/SketchOffset.swift`
  handles chain selection and lines, arcs, circles, slots, rectangles, polygons and an approximate
  spline offset. The app's Offset sketch tool uses it. No MCP tool calls it.

**Proposal:**
- An `offset_sketch_shapes` tool (or an `offset` op on `add_sketch_shapes`): a sketch, a picked
  shape (id or index), a distance (expression) and a side. It adds the offset chain the way the app
  does.
- One line in the instructions: expressions support trig with angle units (`cos(25deg)`).
- Later: engrave or emboss along a curved face (an offset of a face's boundary, or project and cut).

## 5. Reorder steps

**Report:** a cable channel came before the slot fillets in the timeline, split their edges and
made them collide. The agent couldn't move it, so it split one fillet into several steps and
lowered the radius.

**Found:** `Document.moveFeature(_:to:)` exists (`Sources/FilletCore/Model/DocumentEditing.swift`)
and the timeline drag uses it (`DesignSession.moveFeature`). There's no MCP tool for it, though
`History.effects` already says "Reordered steps".

**Proposal:** a `move_feature` tool that takes a step plus `before` or `after` another step, or an
index. It goes through `Change.apply`, so a move that breaks dependencies (a step moved ahead of its
sketch or body) is refused with a reason, and `allow_failures` works as usual. Undo names it
"Move <step>".

## 6. Face filters that match several faces

**Report:** a filter by surface direction put the lip-flute sketch on the iPad support face. There
was no error. The agent only caught it from the returned plane.

**Found:** `Resolver.faceRef` (`Sources/FilletAgent/Tools/ToolSupport.swift`) takes
`indices.first` when a filter matches more than one face. Sketch planes, `lay_flat`, `hole` faces
and every other single-face pick go through it.

**Proposal:** refuse an ambiguous single-face filter. Say how many faces matched and list them
briefly (index, centre, normal, area), and suggest `near`, `extreme` or an index. Picking by index
still works as now. Optionally accept `"limit": 1` as "I mean the first one".

## 7. Print check: where the overhangs are

**Report:** `check_print` reports only the total overhang area, so the agent found the faces by
listing them. A 50° threshold returned exactly the same area as the default 45°.

**Found:**
- The threshold is applied (`PrintAnalysis.analyze`, `threshold = sin(angle)`). The same area at
  45° and 50° is expected when the overhangs are flat ceilings or slopes steeper than 50°, which
  count at both angles. It isn't a bug, but the result doesn't echo the angle it used, so the agent
  couldn't tell.
- `PrintAnalysis` keeps `overhangTriangles` (mesh and triangle index) but not which B-rep face each
  triangle belongs to.

**Proposal:**
- Echo `overhang_angle` in the result.
- Group overhangs by body and face: face index (usable with `list_faces` and `render_view`
  highlights), area, centroid and worst angle, largest first, capped (say at 20). This needs a
  triangle-to-face map from tessellation. Check whether `Mesh` already carries face ids for picking.
- Optionally `render_view` with `highlight: {"overhangs": true}`, which reuses the app's overhang
  overlay.

## 8. Export can't write to the agent's folder

**Report:** the app is sandboxed, so `export` writes into its own temporary folder, and the agent
couldn't copy the file out.

**Found:** `export` writes to `path` or `FileManager.temporaryDirectory`. In the sandboxed Mac app
that's inside the container, and on the iPad it's on another device altogether. The bundled
`fillet-mcp --connect` helper (`Contents/Helpers/fillet-mcp`) runs outside the sandbox, as the
agent's own process.

**Proposal**, in order of reach:
1. Return the file inline: an MCP embedded resource (`blob`, base64) with the file name and MIME
   type, for clients that can save resources. This works from the iPad too. Cap the size, since
   STEP and 3MF files can be several MB.
2. In the `--connect` helper, intercept `export` calls that have a `path`: ask the app for the bytes
   (as in 1) and write them to that path itself, since the helper isn't sandboxed. Agents that use
   the helper then get real files in their project folder.
3. Say plainly in the tool description which paths can be written when connected over HTTP, so
   agents don't try a path that can't work.
