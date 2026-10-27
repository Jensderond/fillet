# OCCT patches

Changes Fillet makes to OpenCascade, as patches against the OCCT `V8_0_1` tag.
`scripts/build-occt.sh` resets `vendor/occt-src` to a clean `V8_0_1` tree, applies every
`*.patch` here in name order with `git apply`, and only then configures and builds. Each patch
starts with a short note on what it changes and why; `git apply` skips that text.

- `0001-BRepClass3d_SolidExplorer-parallel-intersectors.patch`: a solid classifier builds its
  per-face intersectors on OCCT's thread pool instead of one after another (2026-10-26).
- `0002-IntTools_BeanFaceIntersector-cap-localization.patch`: the localised edge/face search
  gives up past 256 candidates and takes OCCT's generic path, so scaled B-spline faces
  intersect fast (2026-10-25).

Background and measurements are in [docs/performance.md](../../docs/performance.md).

## Upgrading OCCT

1. Check out the new tag in `vendor/occt-src` and apply each patch in turn:
   `git apply --3way ../../scripts/occt-patches/0001-….patch` (run from `vendor/occt-src`).
2. Fix any conflicts by hand, keeping the `FILLET PATCH` comments on changed lines.
3. Regenerate each patch from its own change with `git diff -- <file>` and replace everything
   below the note in the `.patch` file. Update the tag in the note and in this README.
4. Check that the set applies to a clean tree: `git apply --check scripts/occt-patches/*.patch`
   from a fresh checkout of the new tag.
