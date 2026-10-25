# Performance

Recompute benchmark and baseline numbers. Measurement only: nothing here has been optimised yet.

## Running it

```sh
swift build -c release --product fillet-bench
.build/release/fillet-bench --booleans > bench.md    # ~10 min on an M4 Pro; progress on stderr
```

`fillet-bench [design.fillet] [--runs N] [--query-runs M] [--top K] [--no-cascade] [--booleans]`.
It defaults to `Benchmarks/frog-wizard.fillet`. `--runs` (default 3) sets how many cold evaluates
and cascades it takes the median of. `--query-runs` (default 10) does the same for tessellation and
face/edge queries. `--booleans` replays each boolean of the 5 slowest combine steps on its own.

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

## Optimisation candidates (ranked)

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
