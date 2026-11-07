# Texture performance

How fast the surface texture step (`TextureEngine.apply`, see [adding-a-texture.md](adding-a-texture.md))
runs, measured on fixed designs. The kernel and recompute rounds are in [performance.md](performance.md).

## Running it

```sh
swift build -c release --product texture-lab
.build/release/texture-lab bench > bench.md          # ~5 min on an M4 Pro; progress on stderr
.build/release/texture-lab bench --fixture flagstone-box --mode display --stages
```

`texture-lab bench [--runs N] [--fixture <name|file.fillet> ...] [--mode display|export] [--stages]
[--loop <seconds>] [--dir Benchmarks/textures]`. It runs every `.fillet` in `Benchmarks/textures`
(or the ones `--fixture` names) `--runs` times (default 5) per mode and prints, per fixture and
mode, the median, minimum and maximum wall-clock ms, the triangle count and a digest.

- **display**: what the viewport recomputes on every edit of a textured body.
  `TextureEngine.apply` at `TextureQuality.display` plus `creaseShaded()`, from the fine base
  tessellation (`ModelEvaluator.texturedBaseDeflection`), which the app caches per shape and the
  bench makes once outside the timing.
- **export**: what a 3MF/STL export runs once: `EvaluatedBody.printMesh(quality: .export)` of
  every body (tessellation plus textures at export detail).
- **Digest**: bit-exact 64-bit FNV-1a over every output mesh's positions, normals, indices and
  triangle faces, in order. **An optimisation must leave every digest unchanged.** Each run's
  digest is compared; runs that differ are flagged **UNSTABLE** and the exit status is 1.
- **`--stages`**: the engine's time per stage (`TextureStageTimes`, a task-local recorder the
  engine marks when one is bound; unbound in the app, where a mark costs one task-local read).
  The digests are the same with and without it.
- **`--loop S`**: re-runs one fixture and mode for S seconds and prints its pid, for a profiler.

The design is evaluated once per fixture, without display meshes (`ModelEvaluator(displayMeshes:
false)`), outside the timing.

`texture-lab export` used to evaluate the design with display meshes first, so every export
textured each body twice, once at display detail (`export --display` ran the display texture
twice): `export --display` of `flagstone-box` took 6.0 s, two display runs of 2.9 s each.
`export`, `check` and `sample` now evaluate without display meshes; `export --viewport` still
makes them. The exported files are byte-identical.

## Fixtures

`Benchmarks/textures/`, each one body with one texture step:

| fixture | design | path through the engine |
|---|---|---|
| `dots-vase` | revolved vase Ø70 × 110, shelled 2 mm, dots Ø8 at 12 × 11 mm, whole dots on | per face (revolved mapping), rims, wall limit across a thin wall |
| `flagstone-box` | box 60 × 60 × 45, corners r8, top r20 (corner blends), flagstone defaults on every face but the bed | laid out in space: `TextureSurface.scatter`, `SolidFlagstones`, budget trial, contour snap, smoothed normals, fairing; `fk_face_grid` for the fillets' `FaceSurface` |
| `flagstone-vase` | revolved vase Ø75 × 80, flagstone defaults on the side | laid out in space over one large free-form face (stress) |
| `knit-box` | the same rounded box, knit 5 × 4.5 mm, 1 mm deep, on every face but the bed | per face on fillets and corner blends: `ParametricChart` / `fk_face_grid`, wall bands |
| `knit-vase` | revolved vase Ø70 × 110, knit defaults on the side | per face, revolved mapping, crease flips |

Every export passes `texture-lab check` (watertight, manifold, no self-intersections).

## Baseline (2026-11-07, Apple M4 Pro 14-core, macOS 27.0.1, release build)

Two full runs (`bench --stages`, then `bench`), 5 runs each; digests identical in both.

| fixture | mode | median ms (run 1 / run 2) | triangles | digest |
|---|---|---:|---:|---|
| dots-vase | display | 2 246 / 2 351 | 730 236 | `92ff8befc2e78bd8` |
| dots-vase | export | 9 426 / 9 431 | 1 799 556 | `1414fc5025e6af55` |
| flagstone-box | display | **2 867 / 2 893** | 309 924 | `b962c35bde25be1d` |
| flagstone-box | export | 10 534 / 10 637 | 1 427 640 | `0ebc5d5b7d114f53` |
| flagstone-vase | display | 3 024 / 2 996 | 376 802 | `bdc6d36f195f91f8` |
| flagstone-vase | export | 12 720 / 12 760 | 1 670 312 | `9ccb5661919a73e9` |
| knit-box | display | 2 266 / 2 291 | 318 260 | `dedc7a9ca1b58f51` |
| knit-box | export | 7 923 / 8 006 | 871 944 | `f8864982df86c5a4` |
| knit-vase | display | 1 167 / 1 114 | 227 454 | `019463016a59ce5d` |
| knit-vase | export | 4 767 / 4 648 | 693 902 | `9d246d727d112cdc` |

### Where the time goes (`--stages`, median ms)

| stage | flagstone-box display | flagstone-box export | knit-box display | knit-box export | dots-vase display | knit-vase export |
|---|---:|---:|---:|---:|---:|---:|
| tessellate (export only) | – | 28 | – | 28 | – | 517 |
| solid layout (scatter, seeds) | 79 | 80 | 1 | 1 | 3 | 2 |
| budget trial (probe subdivision) | **644** | 81 | – | – | – | – |
| subdivide | **837** | **3 998** | **734** | **3 233** | 247 | **1 741** |
| rims | 209 | 756 | 196 | 492 | **548** | 98 |
| contour snap | **412** | 1 685 | 17 | 64 | 40 | 47 |
| normals, pins | 74 | 475 | 102 | 284 | 132 | 146 |
| smooth normals | 81 | 565 | – | – | – | – |
| height sampling | 297 | 1 296 | 155 | 442 | 145 | 269 |
| fairing | 65 | 769 | – | – | – | – |
| wall limit | 35 | 169 | 35 | 112 | 83 | 93 |
| relax folds | 18 | 84 | 210 | 754 | 10 | 12 |
| crease flips | 54 | 342 | **628** | **2 208** | **898** | **1 657** |
| other stages | 63 | 251 | 190 | 344 | 156 | 186 |
| **total** | 2 867 | 10 534 | 2 266 | 7 923 | 2 246 | 4 767 |

(Each stage is its own median, so the column adds up to within about 1% of the total's median.)

Flagstone (laid out in space): subdivision (with its budget trial, a second subdivision at display
detail) is half the viewport time; then contour snapping, height sampling and rims. Per face
(knit, dots): subdivision and the crease flips, and rims for dots.

## Profiling

```sh
.build/release/texture-lab bench --fixture flagstone-box --mode display --loop 30 &
sleep 4; sample $(pgrep -f 'texture-lab bench --fixture flagstone-box') 12 -file flagstone.txt
```

The process has about 40 idle threads (OCCT's pool), so read the main thread's call tree (the
engine's own parallel loops show under `DispatchQueue … concurrent`). `xctrace record --template
'Time Profiler' --launch -- .build/release/texture-lab bench --fixture … --mode … --loop 20`
works as well.

Hotspots in the baseline (main thread, 8 064 samples of `flagstone-box` display):

- `WorkMesh.subdivide` (40%): `improve(where:passes:)` (edge flips: `Dictionary.find` and
  hashing of edge keys, `atan2`), and `SolidFlagstones.detail(at:normal:)` for every new point
  (`stone(at:normal:)` → `rounded(_:nearest:radius:)`, which sorts the neighbouring seeds).
- `snapToContours` (15%) and height sampling (8%): `SolidFlagstones.contour` / `height`, again
  through `stone(at:normal:)` and its sort.
- `followRims` (8%) on a pattern without rims: it builds a `SurfaceMapping` per face, whose
  `ParametricChart.uv` projects every point of the fillets and corner blends.
- `estimatedTriangles` (2.5%) and the probe subdivision of the budget trial.

`knit-box` display: `Dictionary.find` and `Hasher` (edge maps in `alignCreases` and `improve`),
`relax`, `atan2` / `acos`, `ParametricChart.closest`.

## Tests

`swift test --filter Texture` (the texture coding, catalogue, engine, export and preview suites
and the MCP texture suite): about 4 minutes on an M4 Pro, 47 tests.
