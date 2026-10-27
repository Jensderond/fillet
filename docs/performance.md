# Performance

Recompute benchmark, the baseline numbers, and what each optimisation round changed (see
[Round 1](#round-1-kernel-booleans-2026-10-25), [Round 1b](#round-1b-agent-steps-candidates-2-and-3),
[Round 2](#round-2-meshing-face-infos-and-report-queries-2026-10-25) and
[Round 3](#round-3-report-values-solid-classification-and-meshing-2026-10-26)).

## Running it

```sh
swift build -c release --product fillet-bench
.build/release/fillet-bench --booleans > bench.md    # ~40 s on an M4 Pro (10 min at baseline); progress on stderr
```

`fillet-bench [design.fillet] [--runs N] [--query-runs M] [--top K] [--no-cascade] [--booleans] [--all-bodies]`.
It defaults to `Benchmarks/frog-wizard.fillet`. `--runs` (default 3) sets how many cold evaluates
and cascades it takes the median of. `--query-runs` (default 10) does the same for tessellation and
face/edge queries. `--booleans` replays each boolean of the 5 slowest combine steps on its own, then
all tools of a multi-tool step in one boolean (what the evaluator does since Round 1).
`--all-bodies` extends the report-value digest (below) to every distinct body before each step.

It measures:

- **Cold evaluate**: `ModelEvaluator.evaluate` on a fresh evaluator. The evaluator's opt-in timing
  (`ModelEvaluator(recordsTimings: true)`, off in the app) splits this into per-step modelling time,
  display tessellation and the rest.
- **Warm no-op**: re-evaluating an unchanged document, where every step is a cache hit.
- **Early-edit cascade**: the Y factor of the first `scale` step ×1.01, re-evaluated on a warm evaluator.
- **Tessellation, `faceInfos`, `edgeInfos` and `isSeamEdge`** for every final body. Each query
  runs on a fresh shape handle, so the kernel's index maps start empty.
- **Report queries**: `volume`, `surfaceArea`, `bounds` and `isValid`, the values agent tools
  report for a changed body, first and repeated call on a fresh handle.
- **Fillet edge lookup**: `edgeInfos` of each fillet's input body, compared with the whole step.
- **Geometry fingerprint**: per body, the solid, face and edge counts, volume, area, validity and
  bounds, plus failed steps and an FNV digest of all of it. **An optimisation must leave this
  unchanged.** Since Round 2 volume and area are integrated to a relative error of 1e-9
  (`Shape.massProperties(precision:)`, about 2 s for all bodies) and printed to 0.001, so a
  different approximation of the same edge no longer moves them. If the digest differs, compare
  the lines: bounds to 0.001 are printed exactly, so a kernel option such as a fuzzy value can
  legitimately move the last digit. Reference digest: **`c9740640fe841e22`**.
- **Mesh and face-info digests**: bit-exact FNV digests of the evaluator's display meshes and of
  every final body's face and edge infos (which feed persistent reference signatures). Reference:
  meshes `8cb4b3419e1f5575` (159 433 triangles), face/edge infos `78ee99c9d3ec3ba6`.
- **Report-value digest** (since Round 3): bit-exact FNV digest of the default-precision `volume`,
  `surfaceArea` and `isValid` that agent tools report, each on a fresh handle. Reference: 11 final
  bodies `a4497fd231990065`; with `--all-bodies`, 80 bodies `4610a59b64605b24`.

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
   `scripts/occt-patches/0002-IntTools_BeanFaceIntersector-cap-localization.patch` changes one
   thing in the OCCT 8.0.1 file: past 256 candidates `LocalizeSolutions` gives up, and the
   intersector takes its generic path (the one OCCT uses for every non-B-spline surface, and when
   localisation fails). `scripts/build-occt.sh` applies it to the OCCT source before building; `git apply`
   refuses it once the file changes upstream, so it gets refreshed with the next OCCT upgrade. (Until OCCT became a dynamic framework, this was a patched copy of the file compiled
   into CFilletKernel that replaced the static archive member at link time.) Every replayed
   boolean of the fixture gives the same faces, edges and bounds; "Join head" 3.4 s → 26 ms.
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

## Round 2: meshing, face infos and report queries (2026-10-25)

Same machine and fixture, release build, median of 3 (cold, cascade) or 10 (queries). Four commits:

| commit | change |
|---|---|
| `a6b3d47` | precise fingerprint (eps 1e-9 volume and area) plus mesh and face-info digests |
| `b885e58` | mesh changed bodies concurrently |
| `d71c690` | compute a shape's face infos in parallel (`fk_face_infos`) |
| `53d292e` | cache `bounds`, `volume`, `surfaceArea` and `isValid` per shape |

| measurement | before ms | after ms |
|---|---:|---:|
| cold full evaluate | 2 383 | **2 119** |
| … modelling | 1 965 | 1 928 |
| … display tessellation, 11 bodies | 422 | **186** |
| early-edit cascade (76 of 80 steps) | 2 358 | **2 151–2 209** |
| … its display tessellation | 421 | 178–216 |
| first `faceInfos`, all final bodies (frog body) | 590 (477) | **125 (59)** |
| repeated `volume` / `surfaceArea` / `bounds` / `isValid`, frog body | 208 / 187 / 30 / 63 | 0.0 each |

Headless MCP server (`fillet-mcp` on a copy of the fixture, the agent's requests over stdio),
before (`c2a6f9d`) and after:

| request | before ms | after ms |
|---|---:|---:|
| `get_design` (opens the file: cold evaluate) | 2 440–2 490 | 2 150–2 160 |
| `get_design` again | 76 | 0.6 |
| first `list_faces` on the frog body | 480–498 | 61 |
| `fillet` of the frog body's straight edges (r 0.3) | 686–695 | 663–687 |
| `undo` | 89–107 | 59–73 |
| `measure` of the frog body | 491 | 469–477 |

### What changed

1. **Precise fingerprint first**, so the other three could show identity directly. New kernel call
   `fk_mass_properties(shape, eps, …)`: `BRepGProp` volume and area to a relative error of `eps` per
   face. With eps 1e-9 Body 1 is 128 271.910 mm³ / 17 760.288 mm² both at the baseline and after
   Round 1 (see [Round 1's fingerprint](#fingerprint)); default precision gave 128 293.00 vs
   128 296.88. New digest `c9740640fe841e22` (was `cc487b99da55f349`), identical over repeated runs
   and after every Round 2 commit. The fingerprint now takes about 2.1 s.
2. **Concurrent meshing.** `ModelEvaluator.displayMeshes` collects the shapes without a cached mesh
   and tessellates them with `DispatchQueue.concurrentPerform`; the kernel already meshes a private
   copy of each shape. Meshing everything at once naively only got to 298 ms, and the frog body's
   mesh was bimodal (100 or 300 ms): `OSD_Parallel` loops lock whichever pool threads are free, so
   the small bodies' parallel bounds and meshes (2–5 faces, each holding a few threads for up to
   100 ms) left the 88-face body one thread. Now the body with the most faces computes its bounds
   alone first, then is the only one meshed with `BRepMesh`'s parallel mode (new `parallel` flag on
   `fk_tessellate` / `Shape.tessellate`), while the others mesh on one thread each. The remaining
   critical path is a 5-face body (Body 20, 24 578 triangles) meshed on one thread: about 150 ms.
   Meshes bit-identical (digest `8cb4b3419e1f5575`); a test checks serial meshes made concurrently
   equal the parallel mesh.
3. **Parallel face infos.** `fk_face_infos` computes every face with the same `faceInfoOf` as
   `fk_face_info`, on OCCT's pool. `Shape.faceInfos` fills its cache with it; per-index lookups
   before that still ask for one face. 8× on the frog body. Values bit-identical (digest
   `78ee99c9d3ec3ba6`, whose reference was computed face by face).
4. **Scalar caches.** `bounds`, `volume`, `surfaceArea` and `isValid` are lazy, one lock each, like
   the topology tables. Repeat calls are free, but a step's changed body is a new shape, so an
   agent step's report still pays for each value once: the `fillet` request only loses the bounds
   the display mesh had already computed. The app benefits more: `visibleBodyBounds` (sketch-plane
   picking, framing) and the overhang view asked for the bounds of every body on each
   `makeScene`, 77 ms for the fixture, now once per shape.

### Where an agent step's time goes now

The 665 ms `fillet` request on the frog body is roughly 460 ms of report (`volume` 208,
`surfaceArea` 187, `isValid` 63), about 100 ms of display mesh and the fillet itself, and saving the
document. `measure` (470 ms) is the same volume and area on a body not described before.

### What's left (ranked)

1. **Parallel volume and area per face.** `BRepGProp` sums independent per-face integrals; computing
   the faces on the pool and adding them in face order (as `BRepGProp` does) should give the same
   value at about 1/6 of the time: about −330 ms on every agent step that changes the frog body,
   and on `measure`. The default-precision values are reported to agents, so check bit identity on
   all bodies, as for face infos.
2. **Parallel `isValid`.** `BRepCheck_Analyzer(s, true, /*parallel*/ true)`, as `finish()` already
   does: −50 ms per agent step. Same verdict by construction.
3. **Booleans again.** The cascade's modelling (1.95 s) is still about 60% booleans (`PerformFF`,
   `BOPAlgo_Builder`), with step 76 alone 546 ms. Dependency-aware cache keys only help designs
   with independent parts.
4. **Mesh Body 20 faster.** The cold tessellation's critical path is now one 5-face body meshed on
   one thread (about 150 ms of the 186). Either a bigger OCCT pool so several bodies can use it at
   once (affects booleans too, so measure), or give the pool to the body with the most triangles
   from the last mesh rather than the most faces.
5. **UI:** `planarFaces` is cheap (5 ms for the frog body, cached per shape); `makeScene`'s bounds
   are cached now, and the `faceInfos` it resolves a lay-flat's face against are cached and 8×
   faster on first use. No other kernel query in `makeScene` showed up.

## Round 3: report values, solid classification and meshing (2026-10-26)

Same machine and fixture, release build. Another agent's builds shared the CPU (load 7–15), so
every comparison below is back to back with the build before it, median of 3–5 runs. Five commits:

| commit | change |
|---|---|
| `9a63b56` | volume and area integrated per face in parallel (`fk_volume`, `fk_surface_area`) |
| `109077b` | `fk_is_valid` with `BRepCheck_Analyzer`'s parallel mode |
| `e99c150` | a solid classifier's face intersectors built in parallel (patched `BRepClass3d_SolidExplorer`) |
| `75ac43b` | OCCT's pool sized to 4× the processors, every body meshed in parallel |
| `5698f7d` | the evaluator keeps the previous evaluate's display meshes, so undo doesn't re-mesh |

Whole branch, two back-to-back pairs of full `fillet-bench --booleans` runs (Round 2's `0cab901`
first in each pair):

| measurement | round 2 ms | round 3 ms |
|---|---:|---:|
| cold full evaluate | 2 112 / 2 141 | **1 839 / 1 868** |
| … modelling | 1 923 / 1 952 | 1 688 / 1 690 |
| … display tessellation, 11 bodies | 187 / 184 | 145 / 178 |
| early-edit cascade (76 of 80 steps) | 2 136 / 2 165 | **1 809 / 1 827** |
| … its display tessellation | 189 / 183 | 166 / 149 |
| combine steps (16) | 1 339 / 1 356 | 1 176 / 1 179 |
| fillet steps (9) | 265 / 267 | 221 / 219 |
| first `volume` / `surfaceArea` / `isValid`, frog body | 209 / 187 / 63 | **25 / 22 / 12** |
| … all 11 final bodies | 233 / 208 / 74 | 41 / 37 / 18 |

The display tessellation varies most: the dedicated comparison for `75ac43b` (three pairs) gave
187 / 183 / 187 → 142 / 146 / 143 ms. Slowest steps: "Join front leg" 160 → 103 ms, "Join
fingers" 147 → 94 ms, "Join arm" 114 → 77 ms, "Bed trim 2" 83 → 56 ms. Step 76 "Clear
accessories" is 545 → 537 ms (see below).

Headless MCP server (`fillet-mcp` on a fresh copy of the fixture, requests over stdio, two
back-to-back pairs of 3 runs each):

| request | round 2 ms | round 3 ms |
|---|---:|---:|
| `get_design` (opens the file: cold evaluate) | 2 173 / 2 168 | **1 809 / 1 850** |
| first `list_faces` on the frog body | 59 / 61 | 57 / 59 |
| `fillet` of the frog body's straight edges (r 0.3) | 672 / 675 | **230 / 230** |
| `undo` | 59 / 69 | **2 / 2** |
| `measure` of the frog body | 462 / 462 | **58 / 59** |

Fingerprint `c9740640fe841e22`, mesh digest `8cb4b3419e1f5575` and face/edge-info digest
`78ee99c9d3ec3ba6` are unchanged after every commit. The new report-value digest (default-precision
`volume`, `surfaceArea`, `isValid`) is `4610a59b64605b24` over the 80 bodies before every step,
before and after.

### What changed

1. **Parallel volume and area.** `BRepGProp` integrates each face on its own against one
   reference point for the whole shape (the mean of every vertex the explorer visits) and adds the
   masses up in explorer order: `dim = dim + Item.dim * 1.0`. `massOf` in `Shapes.cpp` does the
   same per face on OCCT's pool and sums in the same order, starting from 0, so the double is the
   same. It only takes OCCT's per-face path: shapes with a shared solid (OCCT integrates per
   solid then), faces without a surface (triangulation), shapes without vertices and any face that
   throws go to `BRepGProp` itself. `volumeOf` (also the shell feature's check) uses it too. A test
   compares `volume`/`surfaceArea` bit for bit with `massProperties(precision: 1)`, which is
   OCCT's own serial loop at default precision. The fingerprint's eps-1e-9 integration stays serial,
   as an independent reference.
2. **Parallel validity check** in `fk_is_valid`: the same checks per sub-shape, as `finish()`
   has done since Round 1.
3. **Solid classifier set-up in parallel.** Every `BRepClass3d_SolidClassifier` first builds an
   `IntCurvesFace_Intersector` per face (a sampled polyhedron for B-spline faces), one face after
   another, before it classifies anything. Profiling the cold evaluate showed that set-up at about
   20% of the evaluating thread: `BOPAlgo_BuilderSolid::PerformAreas` classifies a boolean's result
   shells to tell holes from solids (on the calling thread, while the pool idles), and `finish()`'s
   inside-out check (`IsInvertedSolid`) does it again.
   `scripts/occt-patches/0001-BRepClass3d_SolidExplorer-parallel-intersectors.patch` (applied by
   `scripts/build-occt.sh` like Round 1's patch; at the time a patched copy linked over the archive
   member) changes the OCCT 8.0.1 file so that its `InitShape` builds the intersectors on the pool, then binds them in face order with the
   original's last-wins binding and first-exception-in-order behaviour. Each intersector depends
   only on its face, so every classification is unchanged. `finish()`'s orientation check went
   from 208 to 83 ms per cold evaluate, and most combine steps on the frog body got 30–40% faster
   (single "Join fingers" tools replayed: 98–111 → 44–56 ms; step 76 is the exception, below). A test cuts a B-spline cavity out of a box
   (a hole shell) and fills it again on 8 threads at once.
4. **A bigger OCCT pool, every body meshed in parallel.** A parallel loop locks whichever pool
   threads are free when it starts, at most one per processor. With OCCT's default pool (one thread
   per processor) a second concurrent loop gets one thread, which is why Round 2 meshed only the
   body with the most faces in parallel. That left Body 20 (5 faces, 24 578 triangles) meshing on
   one thread for about 130 ms, the critical path. The kernel now sizes the pool to 4× the logical
   processors on its first call (`fk::ensureThreadPool`, from `guarded`) and keeps the per-loop
   limit at one per processor, so a boolean on its own locks no more threads than before. The
   evaluator meshes every body with `parallel: true`, and the critical path is the slowest single
   face (Body 18, about 85 ms). Meshing everything in parallel without the bigger pool was bimodal:
   147 or 337 ms. Modelling did not get slower (1 709 / 1 695 / 1 742 → 1 676 / 1 662 / 1 657 ms;
   possibly because nested loops inside booleans now find threads). The cost: one body meshed on its
   own is 5–8 ms slower (frog body 62–64 → 68–71 ms), for the same reason.
5. **Undo without re-meshing.** The evaluator's mesh cache held only the current bodies, so undoing
   a step re-meshed the bodies it brought back (the frog body: about 65 ms of the 70 ms `undo`).
   It now also keeps the previous evaluate's cache, which costs one more generation of meshes (and
   their shapes) in memory. Redo still recomputes the step, because the step cache holds one
   document.

### Step 76 and what the booleans spend now

Step 76 "Clear accessories" (cut, 8 tools in one boolean) gained little: 545 → 537 ms, replayed
on its own about 530 ms. Sampled in a loop, its calling thread spends 83% in `BOPAlgo_PaveFiller`
(face/face 43%, edge/face 31%) and 11% in `BOPAlgo_Builder`, and 24% of the step waiting for the
last few face/face and edge/face pairs to finish on other threads.

Over the whole cold evaluate (sampled after commit 3), the evaluating thread spends 63% in OCCT's
boolean `Build` (pave filler 50%: face/face 28%, edge/face 16%; builder 13%), 11% in fillets
(`ChFi3d_Builder::Compute`), 11% in `finish()` after any operation (validity 5%, orientation 4%),
11% meshing (before commit 4) and 7% in the scale steps' `BRepBuilderAPI_GTransform`.

### Tried and dropped

- **A 2× pool** (28 threads): meshing everything in parallel was still bimodal once (about 300 ms).
- **Lazy, box-rejected face intersectors** in the classifier: the box `IntCurvesFace_Intersector`
  rejects a line with is its own polyhedron's, which needs the polyhedron, so a cheaper pre-check
  can't be shown to give the same answer. Building them in parallel can.
- **Section-curve tolerances** (`IntTools_FaceFace::ComputeTolReached3d` →
  `GeomLib_CheckCurveOnSurface`, about 29% of face/face CPU): they become edge tolerances, so any
  shortcut changes the result. Not touched.
- **Skipping `finish()`'s orientation check after booleans** of oriented arguments: OCCT's builder
  already classifies the shells it builds, so it is likely redundant, but there is no guarantee to
  point to. About 50 ms per cold evaluate after 3; left as a candidate.

### What's left (ranked)

1. **The tail of the face/face and edge/face loops** (24% of step 76): OCCT runs the pairs in
   index order, so an expensive pair that starts late finishes alone. Starting the pairs with the
   most surface spans first would shorten that tail without changing results (they are stored by
   index). Needs a patched `BOPAlgo_PaveFiller`; up to about 100 ms on step 76.
2. **Skip the orientation check after booleans of `finish()`ed arguments** (above): about 50 ms
   per cold evaluate, medium-low risk; the volume sign in the fingerprint would catch a mistake on
   the fixture, but not in general.
3. **Fillets** (220 ms, 13% of modelling): `ChFi3d_Builder::Compute`, then `finish()`.
4. **Redo and toggled edits**: a second generation of step states (like the meshes in 5) would
   make redo free instead of recomputing the step.
5. **"Widen hat"** (`BRepBuilderAPI_GTransform`, 94 ms): unchanged; exact revolutions need a
   migration for saved face references (see Round 1).
6. **Single-body meshing** is 5–8 ms slower with the bigger pool (nested loops). If that matters
   more than the cold and cascade gains, mesh bodies with only a few faces serially.
