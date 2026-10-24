# Fillet UI re-score, round 3, 24 October 2026

This is the third scoring pass, with the same rubric, strictness and calibration as `2026-10-24-ui-rereview.md` and `-2.md`:

- **Primary lens:** the `swiftui-design-skill` 5-dimension review.
- **Secondary lenses:** `emil-design-eng`, `apple-design` and `review-animations`.
- **Scoring rule:** **8 means genuinely excellent.**

It covers the commits `e2d22d1`…`ab6a6e4`: N01–N06, plus a follow-up for the shell and lay-flat highlights. I verified everything on screen except where marked [code].

## Evidence

All evidence is under `R3 = /private/tmp/claude-503/-Users-jens/f9edf617-fa38-4e5b-91c4-92f9b5cfd9e6/scratchpad/rereview3/`. Every Mac and iPad capture set has 14 steps, including the new `09a-fillet-widened`.

| Set | Files |
| --- | --- |
| Mac light / dark, composited | `R3/mac-light/comp/`, `R3/mac-dark/comp/` |
| iPad Pro 12.9" portrait, light and dark | `R3/ipad-portrait-light/`, `R3/ipad-portrait-dark/` |
| Landscape at **1366×1024 pt** (now the real 12.9" size), light and dark | `R3/ipad-landscape-light/`, `R3/ipad-landscape-dark/` |
| 700 pt width | `R3/ipad-narrow-light/` |
| `accessibility-large` + Increase Contrast, portrait and landscape | `R3/ipad-a11y-portrait/`, `R3/ipad-a11y-landscape/` |
| Crops (edges, bed label, segments, sketch bar) | `R3/crops/` |

**Automation checks:** all passed on the Mac (light and dark) and on all seven iPad runs. That includes the new layout checks:

- **Editor width:** "editor 0…W pt in a W pt window" holds on every step.
- **Sketch tools:** all 10 sit on the bar in portrait, Split View and Mac; 7 on the bar plus 3 in "More shapes" in landscape and at accessibility-large.

The simulator is reset to light, `content_size large`, Increase Contrast disabled.

---

## Scores

| Dimension | Mac | Δ from round 2 | iPad 12.9" | Δ from round 2 | One-line justification |
| --- | --- | --- | --- | --- | --- |
| **Philosophy alignment** | **8** | ±0 | **8** | ±0 | The drafting language now runs from icon to splash to the paper or blueprint bed. Even the bed label reads as a drawing annotation set along the bed edge. |
| **Visual hierarchy** | **8** | ±0 | **8** | ±0 | One primary at a time, picked edges where the eye expects them, and blue used only for "picked" again (region fills are neutral). The slate selected segment is a little loud (N07). |
| **Craft quality** | **8** | ±0 | **8** | **+2** | Nothing clips or widens the window in any configuration. The sketch bar folds cleanly ("…" with a chevron), and at accessibility sizes Construction and Delete stack full-width. |
| **Functionality** | **8** | **+1** | **8** | **+2** | Picked-edge previews now show the edges the kernel actually rounds, including after a parametric change and on a failed step. Every sketch tool is reachable at every width and text size. |
| **Originality** | **8** | ±0 | **8** | ±0 | Paper and blueprint bed, ruler and caliper timeline, edge-aligned bed tag, tilting view cube, and a splash that lands on the same paper. |
| **Average** | **8.0** | +0.2 | **8.0** | +0.8 | **Combined 8.0** (+0.5) |

### Supplementary dimensions

| Dimension | Mac | Δ | iPad | Δ | Justification |
| --- | --- | --- | --- | --- | --- |
| Accessibility | 8 | ±0 | **8** | **+3** | The P0 is gone. At accessibility-large, sketch mode lays out within the window in portrait and landscape: tools fold, values and Delete are reachable, no mid-word breaks. The bed label is now secondary ink on a backing capsule. |
| Motion and interaction feel | 8 | ±0 | 8 | ±0 | Unchanged from round 2. iPad momentum and drawer detents are verified in code only. |

**Shipping bar:** the Mac and iPad are both at least 8 on every rubric dimension.

---

## Status of N01–N06

| ID | Status | How verified | Evidence |
| --- | --- | --- | --- |
| N01 Picked edges in the wrong place after widening | **Fixed** | [screen + harness check] | After widening, Fillet 1 draws four dashed edges at the four vertical corners of the 80 mm plate: `mac-light/comp/09a-fillet-widened.png`, `ipad-portrait-light/09a-fillet-widened.png`. The same holds on the *failed* step at r = 40 (`crops/mac-09c-model.png`). The highlights now come from `model.resolvedEdges`, which the evaluator records before the kernel runs, so they can't disagree with the fillet. Harness check: "4 picked edges drawn, 4 match the resolved edges, 4 at plate corners (x 0…80)". |
| N02 Sketch bar widens the editor (P0 at large text) | **Fixed** | [screen + harness check] | Landscape light and dark: no clipping ("Browser", sidebar and inspector edges intact: `crops/ipad-landscape-light-02a-drawing-left.png`, `crops/ipad-landscape-dark-06-sketch-on-face-left.png`). The bar folds polygon, slot and centre rectangle into "…" (`crops/land-02-sketchbar.png`). Accessibility-large portrait is fully inside the window (`ipad-a11y-portrait/02a-drawing.png`, `…/06-sketch-on-face.png`). The editor now sits in an `OfferedSpace` layout that can't be widened by its content, and `finishInBar` follows the window. |
| N03 Bed label on the outline, 2.79:1 | **Fixed** | [screen] | The label is set *along* the front-left bed edge, outside the bed, in secondary ink on a raised capsule (`crops/mac-light-bedlabel.png`, `crops/mac-dark-bedlabel.png`, `crops/ipad-bedlabel.png`). See the design judgement below. |
| N04 Selected segment 1.47:1 | **Fixed** | [screen] | A solid slate plate with white text in light, and a light slate plate with ink text in dark (`crops/mac-light-segments.png`, `crops/mac-dark-segments.png`, `crops/ipad-dark-segments.png`). It passes comfortably, but see N07. |
| N05 Region fill in selection blue | **Fixed** | [screen] | Regions fill neutral on paper and blueprint; blue is reserved for picked shapes (`mac-dark/comp/02a-drawing.png`, `ipad-portrait-light/02a-drawing.png`). In dark mode the neutral fill is a fairly light slab on navy. It's acceptable, but quieter would be better. |
| N06 "Con-/struction" | **Fixed** | [screen] | At accessibility sizes Construction and Delete stack full-width with no breaks (`ipad-a11y-portrait/02a-drawing.png`). |
| Follow-up: shell and lay-flat highlights | **Fixed (lay flat); by omission (shell)** | [code] | Lay flat resolves against the body before it. Shell's removed faces are no longer highlighted at all, because they are openings in the result; the inspector count and the openings carry it (see N08). |

## Design judgement on the two additions beyond the brief

- **Bed-label backing capsule: good design, keep it.** Setting the printer name along the bed edge, outside the plate, on a small raised tag reads like a title block or dimension annotation on a drawing. That fits the brand better than a floating caption. The capsule keeps it legible over both the grey floor grid and the navy blueprint without adding a new colour. Two nits:
  - The text runs downhill at the camera's angle and is harder to read at steep views. Consider flipping it to stay upright (rotate by π when the edge angle exceeds ±90°).
  - It also sits close to the axis triad origin in some views.
- **Solid slate selected segment: works, but too heavy (N07).** In light mode a dark slate block with white text is the most saturated element in the inspector after the orange Done. With two segmented rows (Operation, Direction), the Extrude inspector has four filled accents: blue picked card, two slate blocks and orange Done. They compete with the primary action. It also introduces a second language for "selected": the tool strip's view toggles (Browser, Overhangs) show "on" as a light `hairlineStrong` plate with ink text, while segments use a solid dark block. The dark-mode version, a light slate plate with ink text, is well judged. In light it should step down to a raised white thumb on the recessed track, as below.

---

## New findings

| ID | Sev | Platform | Area | Observation and evidence | File:line | Concrete fix | Raises |
| --- | --- | --- | --- | --- | --- | --- | --- |
| N07 | P3 | both (light) | Segmented selection weight | **[screen]** The selected segment is a solid slate block with white text. It outweighs everything in the panel but the primary button, and it differs from the "on" style of the tool-strip toggles (`crops/mac-light-segments.png`). | `App/Sources/Views/InspectorView.swift` (`ThemeSegmented`) | Light mode: a raised white thumb (`Theme.raised`) with a 1 pt `inkTertiary` border (4.1:1 against the track) and a soft 1 pt shadow on a `panel` track, with the selected text in `ink` semibold. Dark mode: keep it as is. Align the tool-strip toggle "on" plate with the same thumb so "selected" has one look. | Hierarchy, Craft |
| N08 | P3 | both | Shell preview | **[code]** While editing a Shell, the faces being removed are no longer marked in the viewport. You see only the openings in the preview and the "N open faces picked" count. Picking the *wrong* face is then visible only as a wrong opening. | `App/Sources/Session/ViewportBridge.swift` (shell case removed) | Draw the removed faces' outlines dashed in `select` blue from the pre-shell body (as fillet edges are drawn from `resolvedEdges`). That means having the evaluator record the resolved face indices per shell. | Functionality |
| N09 | P3 | both | Bed label orientation | **[screen]** The edge-aligned label reads downhill and would read upside down past ±90° of yaw. | `Sources/FilletViewport/ViewportView.swift` (bed label) | Flip by 180° when the projected edge angle leaves (−90°, 90°), so the text always reads left to right. | Craft |

There are no P0, P1 or P2 findings.

---

## What still holds a dimension below 8

**Nothing.** Every rubric dimension is at 8 on both platforms, and so are the supplementary Accessibility and Motion scores.

To go beyond 8 the work is refinement, not repair:

- N07: one selection language.
- N08: shell face preview.
- N09: upright bed label.
- A quieter dark-mode region fill.
- Verifying iPad momentum and the drawer drag on a physical iPad with Pencil, which the simulator can't show.
