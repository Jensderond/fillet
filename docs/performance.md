# Performance

Recompute benchmark, the baseline numbers, and what each optimisation round changed (see
[Round 1](#round-1-kernel-booleans-2026-10-25)).

## Running it

```sh
swift build -c release --product fillet-bench
.build/release/fillet-bench --booleans > bench.md    # ~40 s on an M4 Pro (10 min at baseline); progress on stderr
```

`fillet-bench [design.fillet] [--runs N] [--query-runs M] [--top K] [--no-cascade] [--booleans]`.
It defaults to `Benchmarks/frog-wizard.fillet`. `--runs` (default 3) sets how many cold evaluates
and cascades it takes the median of. `--query-runs` (default 10) does the same for tessellation and
face/edge queries. `--booleans` replays each boolean of the 5 slowest combine steps on its own, then
all tools of a multi-tool step in one boolean (what the evaluator does since Round 1).

It measures:

- **Cold evaluate**: `ModelEvaluator.evaluate` on a fresh evaluator. The evaluator's opt-in timing
  (`ModelEvaluator(recordsTimings: true)`, off in the app) splits this into per-step modelling time,
  display tessellation and the rest.
- **Warm no-op**: re-evaluating an unchanged document, where every step is a cache hit.
- **Early-edit cascade**: the Y factor of the first `scale` step ×1.01, re-evaluated on a warm evaluator.
- **Tessellation, `faceInfos`, `edgeInfos` and `isSeamEdge`** for every final body. Each query
  runs on a fresh shape handle, so the kernel's index maps start empty.
- **Fillet edge lookup**: `edgeInfos` of each fillet's input body, compared with the whole step.
- **Geometry fingerprint**: per body, the solid, face and edge counts, volume, area, validity and
  bounds, plus failed steps and an FNV digest of all of it. **An optimisation must leave this
  unchanged.** If the digest differs, compare the lines: volume to 0.01 and bounds to 0.001
  are printed exactly, so a kernel option such as a fuzzy value can legitimately move the last digit.

## Fixture

`Benchmarks/frog-wizard.fillet` is a figurine an agent modelled through the MCP server. It has 80
steps: 25 primitives, 16 combines, 9 fillets, 8 lofts, 8 non-uniform scales, 6 moves, 3 sketches,
3 revolves and 2 mirrors. Non-uniform `scale` turns the spheres and revolves into B-spline
geometry, so the later joins and cuts intersect freeform surfaces.

## Baseline (2026-10-25, Apple M4 Pro 14-core, macOS 27.0.1, OCCT 8.0.1, release build)

| measurement | ms |
|---|---:|
| cold full evaluate (median of 3: 81 758 / 81 600 / 81 562) | **81 600** |
| … modelling (sum of steps) | 80 925 (99.2%) |
| … display tessellation, 11 bodies, 159k triangles | 669 (0.8%) |
| … evaluator overhead (hashing, cache, assembly) | 6 |
| warm re-evaluate, nothing changed | 0.1 |
| early-edit cascade (step 5 “Squash head”, 76 of 80 steps recomputed) | **82 036** |
| tessellate all final bodies (outside `evaluate`) | 338 |
| `faceInfos`, all final bodies | 604 (frog body, 88 faces: 484) |
| `edgeInfos`, all final bodies | 1.6 |
| `isSeamEdge` for every edge, all final bodies | 8.4 (frog body, 268 edges: 7.5) |

Cost by step type:

| type | steps | total ms | share | max ms |
|---|---:|---:|---:|---:|
| combine | 16 | 79 687 | 98.5% | 54 151 |
| fillet | 9 | 743 | 0.9% | 229 |
| primitive | 25 | 344 | 0.4% | 220 |
| scale | 8 | 110 | 0.1% | 100 |
| loft, move, mirror, sketch, revolve | 22 | 60 | 0.1% | 10 |

Slowest steps:

| # | step | type | ms | share |
|---:|---|---|---:|---:|
| 76 | Clear accessories from frog (cut, 8 tools) | combine | 54 151 | 66.9% |
| 64 | Join haunches | combine | 11 194 | 13.8% |
| 67 | Join front leg | combine | 5 716 | 7.1% |
| 31 | Join head | combine | 3 377 | 4.2% |
| 72 | Join arm | combine | 3 085 | 3.8% |
| 74 | Join fingers (6 tools) | combine | 1 805 | 2.2% |
| 73 | Blend shoulder | fillet | 229 | 0.3% |
| 68 | Bed trim 2 | primitive (cut) | 220 | 0.3% |
| 69 | Blend front leg | fillet | 177 | 0.2% |
| 66 | Blend right haunch | fillet | 148 | 0.2% |

Step 76, one boolean per tool. The faces column gives the target's face count, then the tool's:

| tool | faces | ms |
|---|---|---:|
| Strap | 80 + 1 | 19 876 |
| Hat | 53 + 5 | 17 037 |
| Satchel | 62 + 26 | 4 403 |
| Flap | 74 + 27 | 4 047 |
| Eyes | 54 + 2 | 3 607 |
| Blush | 56 + 2 | 2 406 |
| Smile | 58 + 3 | 2 135 |
| Staff | 83 + 3 | 443 |

A 2-face body joined to a 1-face body (“Join head”) still takes 3.4 s. The cost comes from how
complex the surfaces are, not from how many faces there are.

Fingerprint (digest `5f765134c5951dc2`):

```
Body 1 [50FE499C] solids=1 faces=88 edges=268 volume=128293.00 area=17789.11 valid=true bounds=(-31.547 -29.850 -0.000)..(47.000 26.500 76.767)
Body 18 [43A27D84] solids=1 faces=3 edges=8 volume=3325.03 area=2246.41 valid=true bounds=(38.411 -21.500 -0.000)..(55.498 -14.500 101.326)
Body 19 [D8B1C0C2] solids=1 faces=4 edges=10 volume=96.28 area=107.97 valid=true bounds=(45.676 -21.000 90.600)..(51.074 -15.000 96.288)
Body 20 [38D4B982] solids=1 faces=5 edges=12 volume=65208.62 area=14984.84 valid=true bounds=(-40.341 -41.521 61.952)..(41.917 41.521 119.171)
Body 22 [498D792B] solids=2 faces=4 edges=12 volume=1381.36 area=772.15 valid=true bounds=(-18.900 -27.700 50.500)..(18.900 -16.700 61.500)
Body 23 [8EC9D60E] solids=2 faces=2 edges=6 volume=22.99 area=49.26 valid=true bounds=(-17.650 -28.000 57.140)..(15.160 -24.530 60.380)
Body 25 [9BE2716F] solids=2 faces=2 edges=6 volume=190.26 area=247.40 valid=true bounds=(-24.055 -21.294 45.990)..(24.055 -15.306 53.010)
Body 26 [5B7ED4D2] solids=1 faces=3 edges=9 volume=32.23 area=74.99 valid=true bounds=(-5.525 -26.550 47.700)..(5.525 -24.325 52.325)
Body 27 [0FA16C4B] solids=1 faces=27 edges=67 volume=483.67 area=368.79 valid=true bounds=(-21.840 -14.720 20.419)..(-11.890 -1.861 28.597)
Body 28 [73B268B1] solids=1 faces=27 edges=62 volume=376.47 area=306.59 valid=true bounds=(-21.923 -15.173 27.404)..(-10.878 -0.955 32.439)
Body 30 [83E8A4A7] solids=1 faces=12 edges=26 volume=511.76 area=829.52 valid=true bounds=(-19.370 -18.676 28.329)..(19.370 18.676 42.671)
failed steps: none
```

## Where the time goes

From `sample` of the cold evaluate. Shares are of samples on the evaluating thread.

- **`fk_boolean`: 98.7%.** Within it:
  - `BRepAlgoAPI_BooleanOperation::Build`: 95%, nearly all in `BOPAlgo_PaveFiller::PerformEF`
    (edge/face intersection: `IntTools_BeanFaceIntersector::ComputeLocalized` →
    `Extrema_GenExtCS` → `math_PSO` global search, evaluating B-spline surfaces through
    `GeomAdaptor_TransformedSurface`). Face/face intersection (`PerformFF`) is under 1%.
    PerformEF already runs on OCCT's thread pool, but the evaluating thread spends 79% of it
    waiting for workers. A few expensive edge/face pairs dominate, so the process averages only
    about 3.1 of 14 cores.
  - `finish()` post-processing: `orientSolids` (a full `BRepGProp` volume per solid) is 4.5%,
    `BRepCheck_Analyzer` is 1.1% and `ShapeUpgrade_UnifySameDomain` is under 0.1%.
- **Swift-side overhead is negligible.** Hashing, caching and state copies take 6 ms of 81.6 s,
  and a warm no-op evaluate takes 0.1 ms. Fillet edge lookups are 0.3% of fillet time.
- **`fk_face_info`** (about 5.5 ms per face on the frog body). `BRepBndLib::AddOptimal` face bounds
  take 53% of it, `BRepGProp::SurfaceProperties` 34% and `normalNear` 12%. Nothing caches it: every
  `faceInfos` call recomputes. Agent tools call it on each `list_faces`, face filter or sketch-on-face.
- **Tessellation**: 93% in `BRepMesh_IncrementalMesh`.
- **`isSeamEdge`** rebuilds the edge→face ancestor map on every call, so `list_edges` and fillet
  `"all"` are O(edges²). That costs only 7.5 ms here, but grows quadratically.
- **In the app, every agent step is evaluated twice**: once by `LiveWorkspace.previewEvaluator`,
  then by the session's own evaluator, which has its own cache. An agent adding step 76 therefore
  waits about 108 s instead of 54 s.

## Optimisation candidates at baseline (ranked)

Round 1 took care of 1 and 4; see [what's left](#whats-left-ranked) after it.

1. **Faster booleans on freeform bodies (the 98.5%).** Try BRepAlgoAPI options on the
   `--booleans` replay, then check the fingerprint:
   - `SetUseOBB(true)`: low risk, payoff unknown.
   - `SetFuzzyValue`: can change topology, so medium risk.
   - `SetNonDestructive(false)` on the copies we own.
   - A single boolean with all tools for multi-tool combines (steps 74 and 76) instead of one per
     tool. That saves repeated intersection, and `finish()` runs once.

   Separately, look at why the scaled B-splines are so expensive to intersect. Candidates are the
   pole count after `BRepBuilderAPI_GTransform`, rational vs polynomial surfaces, and located
   (`TransformedSurface`) faces. Simpler geometry would speed up every later step.
2. **Share or reuse evaluation between the preview and session evaluators in the app.** This
   halves the latency of each agent step (−50% of the agent wait), and the result is identical.
   Low-to-medium risk, because the two evaluators run on different actors.
3. **Cache `faceInfos` and `edgeInfos` per `Shape`**, lazily, since a shape is immutable. This
   removes up to about 0.5 s per agent request on the frog body, at no risk. Optionally, compute
   face bounds without `AddOptimal`, but bounds feed reference signatures, so that is medium risk.
   Build the seam set once per shape to make `isSeamEdge` O(1).
4. **Cheaper `orientSolids`.** Check orientation with a point classifier, or with a low-precision
   volume. Saves about 4.5% of boolean time (about 3.6 s cold). Low risk.
5. **Dependency-aware cache keys.** Key each step on the steps it references instead of the whole
   prefix. In this fixture that helps little, because nearly all the cost is in the frog-body chain
   every early edit touches. It pays off in designs with independent parts. Medium risk.
6. **Tessellation**: 0.3–0.7 s for a full recompute. The mesh cache already skips unchanged bodies.
   A coarser angular deflection would make interactive late-step edits feel faster. Low payoff.
7. **Parallelising independent steps**: low payoff on this fixture, which is one long dependent
   chain. The kernel already parallelises inside PerformEF.

## Round 1: kernel booleans (2026-10-25)

Same machine and fixture as the baseline. Cold evaluate **81.6 s → 2.39 s (34×)**, early-edit
cascade **82.0 s → 2.38 s**. Six commits, all in the kernel except the multi-tool combine:

| commit | change | cold evaluate ms |
|---|---|---:|
| baseline | | 81 600 |
| `744bd00` | cap OCCT's localised edge/face search (patched `IntTools_BeanFaceIntersector`) | 7 815 |
| `ecfd7e1` | multi-tool combines as one boolean | 4 148 |
| `b66467a` | inside-out check by classifier instead of volume in `finish()` | 2 995 |
| `120a2e6` | optimal bounds per face in parallel (`fk_bounds`) | 2 712 |
| `3e86e66` | parallel `BRepCheck_Analyzer` in `finish()` | 2 472 |
| `ec515e7` | `SetCheckInverted(false)` when every argument came out of `finish()` | 2 367 |

The final bench run below gives 2 390 (runs 2 390 / 2 332 / 2 393): run-to-run noise is about ±50 ms.

### What changed

1. **The 98.5% was an OCCT pathology, not the B-splines as such.** For an edge against a B-spline
   face of degree > 2 with more than one knot span in both directions, `IntTools_BeanFaceIntersector`
   first "localises" candidate (curve range, surface patch) pairs by box overlap. Every patch box is
   enlarged by one deflection estimated on the whole face's coarse knot grid: 5.2–7.7 mm on the
   scaled frog body, because a full circle has only 7 grid points. Boxes therefore never shrink and
   the recursion runs down to its minimum size along every stretch within those millimetres of the
   face: 870 to 179 000 candidates per edge/face pair in this fixture, each followed by a
   `math_PSO` global extremum search. One transversal crossing in "Join head" took 3.3 s (61 556
   candidates). Even a box edge crossing a NURBS-converted (unscaled) head gives thousands.
   `Sources/CFilletKernel/src/OCCTPatches/IntTools_BeanFaceIntersector.cpp` is a copy of the OCCT
   8.0.1 file with one change: past 256 candidates `LocalizeSolutions` gives up, and the
   intersector takes its generic path (the one OCCT uses for every non-B-spline surface, and when
   localisation fails). Compiled into CFilletKernel, it replaces the archive member at link time
   (a static archive member is only loaded for undefined symbols). An `#error` fires when the OCCT
   version changes, so the copy gets refreshed with the next upgrade. Every replayed boolean of the
   fixture gives the same faces, edges and bounds; "Join head" 3.4 s → 26 ms.
2. **Multi-tool combines in one boolean** (`fk_boolean_tools`, `Shape.boolean(_:_:[Shape])`). Cut
   and fuse put all tools into one `BRepAlgoAPI_Cut`/`Fuse`; common still chains, because OCCT
   would intersect with the union of the tools. `ModelEvaluator.combine` falls back to one tool at a
   time if the single boolean fails. Step 76: 3 006 → 812 ms, step 74: 1 787 → 361 ms.
3. **`finish()` orientation by classification.** `BOPTools_AlgoTools::IsInvertedSolid` (a point
   at infinity classified against the solid) instead of the sign of a full `BRepGProp` volume:
   same decision for a valid closed solid, 30 ms instead of 205 ms on the 88-face frog body.
4. **`fk_bounds` per face in parallel.** The evaluator computes optimal bounds of every final body
   to pick the display deflection; on the frog body that was 237 ms of the 653 ms "display
   tessellation". `AddOptimal` is a union of per-face boxes, so running faces on OCCT's thread
   pool gives bit-identical bounds (checked on 45 dumped bodies): 36 ms.
5. **Parallel validity check.** `BRepCheck_Analyzer(s, true, /*parallel*/ true)` in `finish()`.
6. **`SetCheckInverted(false)` for known-good arguments.** OCCT classifies every argument solid to
   widen the box of an inside-out one. `FKShape::solidsOriented` records that a shape came out of
   `finish()` (kept by copy and compound); booleans skip the check only when the target and every
   tool have it. STEP and BRep imports keep it.

### Tried and dropped

- **`SetUseOBB(true)`**: slower. "Join head" 3.47 → 4.73 s at baseline; over all 16 combine steps
  (patched kernel, one boolean per tool) 5.86 → 6.12 s. Same geometry.
- **`SetFuzzyValue(1e-5 / 1e-6)`**: no measurable effect (3.47 vs 3.54 s, 5.86 vs 5.87 s), same
  geometry. Not worth the topology risk.
- **`SetNonDestructive(false)`**: not tried. The arguments are cached shapes shared with earlier
  steps, so letting OCCT modify them in place is unsafe.
- **`SetRunParallel(false)`** for comparison: "Join head" 3.5 → 9.8 s, so the existing `true` stays.
- **Simpler geometry from `scale`.** `BRepBuilderAPI_GTransform` already produces exact, minimal
  rational B-splines with no approximation: degree 2×3 with 6×9 poles for the scaled frog body,
  2×2 with 6×5 for the scaled spheres and torus, and a 2×2 B-spline for the scaled base plane. A
  cheaper exact form exists only when the scale keeps a revolution (equal factors across the axis:
  "Widen hat"), and it would change face types from `bspline` to `revolution`, which edge and face
  signatures in saved documents refer to. With the localisation fixed, B-spline arguments are no
  longer what makes booleans slow ("Join head" 26 ms), so this was not pursued. NURBS-converting the
  *unscaled* body and head reproduces the slowness (5.3 s), which is how the real cause was found.
- **Volume integration instead of the classifier, at lower precision**: not needed after 3.

### Fingerprint

New digest **`cc487b99da55f349`** (baseline `5f765134c5951dc2`). Every line is identical except
Body 1's volume and area:

```
baseline  Body 1 [50FE499C] solids=1 faces=88 edges=268 volume=128293.00 area=17789.11 valid=true bounds=(-31.547 -29.850 -0.000)..(47.000 26.500 76.767)
round 1   Body 1 [50FE499C] solids=1 faces=88 edges=268 volume=128296.88 area=17789.99 valid=true bounds=(-31.547 -29.850 -0.000)..(47.000 26.500 76.767)
```

The geometry is the same; the printed numbers move because `fk_volume`/`fk_surface_area` use
`BRepGProp`'s default-precision integration, which on this body is off by 21 mm³ and reacts to how
an edge is approximated. Two commits change such approximations (the patched intersector picks a
different start point for one blush intersection curve; the single multi-tool boolean approximates
its section curves in one go), with the same faces, edges, tolerances and bounds. Comparing the
final BRep of Body 1 before and after (dumped from the evaluator):

| | baseline | round 1 | difference |
|---|---:|---:|---:|
| volume, `BRepGProp` eps 1e-9 | 128 271.909836 | 128 271.909803 | 3.3e-5 mm³ (2.6e-10) |
| area, eps 1e-9 | 17 760.287899 | 17 760.287896 | 2.7e-6 mm² |
| centre of mass | | | 7.8e-9 mm apart |
| max distance, mesh nodes of one to the other shape (~2 400 points each way) | | | 8.7e-8 mm |

All other bodies have bit-identical precise volumes and areas. A future fingerprint could print
an eps-1e-9 volume instead, so representation changes stop moving it.

### Numbers after Round 1 (median of 3)

| measurement | baseline ms | round 1 ms |
|---|---:|---:|
| cold full evaluate (runs 2 390 / 2 332 / 2 393) | 81 600 | **2 390** |
| … modelling (sum of steps) | 80 925 | 1 955 |
| … display tessellation, 11 bodies, 159k triangles | 669 | 425 |
| … evaluator overhead | 6 | 10 |
| warm re-evaluate, nothing changed | 0.1 | 0.1 |
| early-edit cascade (step 5, 76 of 80 steps) | 82 036 | **2 377** |
| tessellate all final bodies (outside `evaluate`) | 338 | 337 |
| `faceInfos`, all final bodies | 604 | 609 |
| `isSeamEdge` for every edge, all final bodies | 8.4 | 8.3 |

Cost by step type:

| type | steps | baseline ms | round 1 ms | share | max ms |
|---|---:|---:|---:|---:|---:|
| combine | 16 | 79 687 | 1 351 | 69.1% | 546 |
| fillet | 9 | 743 | 266 | 13.6% | 62 |
| primitive | 25 | 344 | 182 | 9.3% | 83 |
| scale | 8 | 110 | 103 | 5.3% | 95 |
| loft, move, mirror, sketch, revolve | 22 | 60 | 33 | 1.7% | 6 |

Slowest steps:

| # | step | type | baseline ms | round 1 ms | share |
|---:|---|---|---:|---:|---:|
| 76 | Clear accessories from frog (cut, 8 tools) | combine | 54 151 | 546 | 27.9% |
| 67 | Join front leg | combine | 5 716 | 159 | 8.1% |
| 74 | Join fingers (6 tools) | combine | 1 805 | 153 | 7.8% |
| 72 | Join arm | combine | 3 085 | 119 | 6.1% |
| 38 | Widen hat | scale | 100 | 95 | 4.9% |
| 68 | Bed trim 2 | primitive (cut) | 220 | 83 | 4.3% |
| 64 | Join haunches | combine | 11 194 | 83 | 4.2% |
| 19 | Combine 2 | combine | ≤148 | 66 | 3.4% |
| 73 | Blend shoulder | fillet | 229 | 62 | 3.1% |
| 79 | Clear bag from strap | combine | ≤148 | 57 | 2.9% |

"≤148": not in the baseline top 10, whose last entry was 148 ms. #31 "Join head" (3 377 ms at
baseline) is no longer in the top 15 (≤36 ms; 26 ms replayed on its own).

Step 76 replayed one tool at a time (`--booleans`) now costs 95–232 ms per tool (1 287 ms in
total); all eight tools in one boolean take 540 ms.

### Where the time goes now

- **Booleans: about 60% of the cold evaluate** (combine steps 57%, plus primitive cuts and joins). `BOPAlgo_PaveFiller::PerformFF` (face/face
  intersection) is now the largest part, then `PerformEF`, then `BOPAlgo_Builder` (splitting
  faces and solids). `finish()` is down to a few percent.
- **Display tessellation: 425 ms (18%).** Bodies are meshed one after another (each mesh is
  parallel over its faces). Re-meshing the final bodies outside `evaluate` takes 337 ms in total;
  the frog body's bounds take 36 ms.
- **Fillets: 266 ms**, mostly `BRepFilletAPI_MakeFillet::Build`.
- **"Widen hat": 95 ms** in `BRepBuilderAPI_GTransform` (converting the hat's revolutions, torus
  and sphere to B-splines).

### What's left (ranked)

1. **Mesh bodies concurrently in `ModelEvaluator.displayMeshes`** (Swift side; bodies are
   independent and the kernel meshes a copy). A large part of the 425 ms, with identical meshes;
   the other agent's Swift-side caching work touches the same file, so it was left alone here.
2. **Share evaluation between the app's preview and session evaluators** (baseline candidate 2):
   still halves an agent step's wait, now about 2.4 s → 1.2 s for step 76-sized edits.
3. **Cache `faceInfos`/`edgeInfos` per shape** (baseline candidate 3): `faceInfos` on the frog body
   is 488 ms, now more than a fifth of a full cold evaluate.
4. **Fingerprint with eps-1e-9 volume and area**, so future rounds can show identity directly.
5. **Dependency-aware cache keys** (baseline candidate 5): unchanged, still fixture-dependent.
6. **Exact revolution surfaces for revolution-preserving scales** ("Widen hat"): saves up to
   ~90 ms here, but changes face types that saved references use. Needs a migration story first.
||||||| parent of 9ca17c7 (perf: Document round 1b (agent step caching) in performance.md)

## Round 1b: agent steps (candidates 2 and 3)

Release build, measured while another benchmark loaded the machine, so expect ±10%. The query
and MCP timings run on the fixture's 11 final bodies, loaded from BRep into a headless workspace
(one imported body per step), so no boolean runs.

**Per-shape caches.** `Shape` computes `faceInfos`, `edgeInfos` and `seamEdges` once, on first
use, behind a lock per table. Per-index lookups read the table once it exists. `fk_seam_edges`
builds the edge→face map once per shape. Values are byte-identical on all 11 bodies.

| query, all final bodies (frog body) | before: 1st / repeat ms | after: 1st / repeat ms |
|---|---:|---:|
| `faceInfos` | 618 / 605 (496 / 484) | 587 / 0.00 (473 / 0.00) |
| `edgeInfos` | 1.5 / 1.3 | 1.4 / 0.00 |
| `isSeamEdge` for every edge | 8.1 / 7.8 (7.2 / 7.0) | 0.10 / 0.01 (0.06 / 0.01) |

| MCP request on the frog body (headless) | before ms | after ms |
|---|---:|---:|
| `list_faces` (first) | 475 | 483 |
| `list_faces` (again) | 477 | 0.6 |
| `list_edges` | 4.0 | 0.6 |
| `create_sketch` on a frog face | 951 | 5 |

**One evaluation per agent step in the app.** `LiveWorkspace.preview` now checks a change on the
window's own evaluator (`DesignSession.preview` → `ModelEvaluator.preview`). A preview fills a
separate cache, so the session's recompute after the commit is all cache hits, and a refused
preview leaves the window's cached steps alone. Measured through the MCP server with an
app-like workspace (session evaluator + preview), filleting the frog body's straight edges:

| | separate preview evaluator (before) | session's evaluator (after) |
|---|---:|---:|
| preview evaluate | 628 | 609 |
| recompute after commit | 615 | 1.9 |
| whole `fillet` request | 1 959 | 1 331 |

On the fixture, an agent adding step 76 therefore waits about 54 s instead of 108 s.

**Next candidate.** Of the remaining 1.3 s, about 0.7 s is the step's report: `volume` (211 ms),
`surfaceArea` (190 ms), `bounds` (239 ms) and `isValid` (64 ms) of the changed frog body, each
recomputed on every request. `bounds` is also called by the evaluator (`boundsOverlap`, display
deflection). They can be cached per shape the same way.

Fingerprint after both changes (`fillet-bench --runs 1 --no-cascade`): digest `5f765134c5951dc2`, unchanged.
