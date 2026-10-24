# Fillet UI re-score after the fix round, 24 October 2026

This re-scores the app after the fix round (commits `f090e34`…`acbaaa5`). It uses the same rubric, strictness and calibration as my first review (`2026-10-24-ui-rereview.md`): the `swiftui-design-skill` 5-dimension review is primary; `emil-design-eng`, `apple-design` and `review-animations` are secondary. **8 means genuinely excellent.**

I did not read the other reviewer's document. I verified the implementer's claims on screen where the harness allowed it. For things it can't show (hover, momentum, drawer drag), I verified them in code and say so.

## Evidence

Evidence paths are relative to `R2 = /private/tmp/claude-503/-Users-jens/f9edf617-fa38-4e5b-91c4-92f9b5cfd9e6/scratchpad/rereview2/`.

| Set | Device and settings | Files |
| --- | --- | --- |
| Mac light / dark | 1600×1000 window. The window and Metal captures are composited by `R2/tools/comp.swift`. | `R2/mac-light/comp/*.png`, `R2/mac-dark/comp/*.png` |
| iPad portrait light / dark | **iPad Pro 12.9" (6th gen)**, iPadOS 26.5, 1024×1366 pt | `R2/ipad-portrait-light/`, `R2/ipad-portrait-dark/` |
| iPad landscape light / dark | `FILLET_ORIENTATION=landscape` | `R2/ipad-landscape-light/`, `R2/ipad-landscape-dark/` |
| iPad Split View width | `FILLET_WIDTH=700` | `R2/ipad-narrow-light/` |
| iPad accessibility | `accessibility-large` + Increase Contrast, portrait and landscape | `R2/ipad-a11y-portrait/`, `R2/ipad-a11y-landscape/` |
| Crops | Left edge of the landscape and accessibility captures | `R2/crops/` |

Run notes:
- **Landscape is simulated.** The harness still lays landscape out at the 13" size, 1376×1032 pt (`DebugAutomation.swift:52-53`). The 12.9" in landscape is 1366×1024 pt, 10 pt narrower, so the landscape overflow in N02 will be slightly *worse* on the owner's device.
- **New screens.** The harness now also captures `09b-failed-step` and `09c-show-failed`. It also adds checks for framing, a single Finish button, undo/redo truthfulness, the VoiceOver summary and the failure banner.
- **Checks passed:** every check passed on the Mac (light and dark) and on all seven iPad runs.
- **Simulator reset afterwards:** appearance light, content size `large`, Increase Contrast disabled.
- **Compositing artefact:** the halo around the floating sketch bar and the toast in the Mac composites comes from my compositing, not the app.

Each status and finding is marked **[screen]** if I verified it in a capture, **[code]** if I verified it in the source, or **[measured]** for a contrast ratio I computed.

---

## Scores

| Dimension | Mac | Δ | iPad 12.9" | Δ | One-line justification |
| --- | --- | --- | --- | --- | --- |
| **Philosophy alignment** | **8** | +1 | **8** | +1 | The drafting paper now reaches the workspace: a cream graph-paper bed in light mode, a navy blueprint in dark that matches the splash. The model is in brand-toned blue-grey with a contact shadow, and the view cube uses the theme colours. Icon, splash and editor now read as one object. |
| **Visual hierarchy** | **8** | +1 | **8** | +2 | One primary action per state, measured by the harness (`finish-sketch` count = 1). A "Showing step 2 of 5 · Play to end" pill, dashed rolled-back stations, ruler numbers only where they matter, the camera framing the work in the clear part of the viewport, and the failure banner, the print-check row and the red station agreeing. |
| **Craft quality** | **8** | +1 | **6** | ±0 | Mac: hover on every control, one themed segmented control with matching widths, correct verbs, no UUIDs or orphaned wraps. iPad: in landscape sketch mode the whole editor overflows its window and both edges clip ("Browser", the sidebar text, the inspector toggle). At accessibility sizes in portrait the inspector's fields and the Delete button go off-screen (N02). |
| **Functionality** | **7** | ±0 | **6** | ±0 | Undo is truthful, tools say why they're unavailable, failed steps are announced with Show, and the camera frames content. Two problems remain. After a parametric change, two of the four picked-edge highlights land on the wrong edges, inside the pocket (N01, both platforms). On iPad, sketch mode breaks at accessibility text sizes and clips in landscape (N02), and the "More shapes" fold that should prevent it never triggers. |
| **Originality** | **8** | +1 | **8** | +1 | The paper and blueprint bed, ruler and caliper, hatched rollback, the tilting view cube and the plotter splash flowing into the same paper. It would not be mistaken for a template. |
| **Average** | **7.8** | +0.8 | **7.2** | +0.8 | **Combined 7.5** (+0.8) |

### Supplementary dimensions

These are outside the rubric, scored the same way as in the first review.

| Dimension | Mac | Δ | iPad | Δ | Justification |
| --- | --- | --- | --- | --- | --- |
| Accessibility | 8 | +1 | **5** | −2 | Contrast fixes hold, there is a "3D view" element with a model and selection summary and camera actions, and segments stack at large sizes. But on the iPad, Dynamic Type at accessibility sizes now makes sketch mode unusable in portrait (N02, P0). |
| Motion and interaction feel | 8 | +1 | 8 | +2 | The hint crossfades only when its context changes. Mac hover parity. **[code]** iPad orbit and pan coast with Apple's projection, are caught by the next touch and are off under Reduce Motion. The drawer has velocity-projected detents with rubber-banding and a selection haptic. I couldn't feel either in the simulator. |

**Shipping bar** (at least 7 on all dimensions): the Mac passes and is one bug from 8 everywhere. The iPad doesn't pass: Craft and Functionality are at 6, held there almost entirely by one layout bug (N02).

---

## Status of R01–R26

| ID | Status | How verified | Notes |
| --- | --- | --- | --- |
| R01 Sketch tools hidden on iPad | **Fixed in portrait and Split View; regressed in landscape and at accessibility sizes** | [screen] | All 10 tools and the finger toggle show in 12.9" portrait (`ipad-portrait-light/02a-drawing.png`) and at 700 pt (`ipad-narrow-light/02a-drawing.png`). The fold-into-"More shapes" logic never fires, though, so in landscape and at accessibility sizes the bar overflows the window. See N02. |
| R02 Camera ignores content | **Fixed** | [screen + harness check] | The sketch is framed in the clear area. The first and widened bodies are centred to within 1 % (`ipad-portrait-light/02a-drawing.png`, `…/05-fillet-editing.png`, `mac-light/comp/09-widened.png`). |
| R03 Undo looks disabled | **Fixed** | [screen + harness check] | Undo is enabled after edits; Undo then Redo flip the toolbar state correctly (`ipad-portrait-light/05-fillet-editing.png`). |
| R04 Tools look usable when they can't run | **Fixed** | [screen + code] | On an empty document, Extrude, Revolve and Fillet…Overhangs draw in disabled ink (`mac-light/comp/01-empty.png`). A tap shows a popover with the reason, which is also the tooltip and VoiceOver hint (`EditorView.swift` `ToolButton`). |
| R05 Failed steps barely signalled | **Fixed** | [screen + harness check] | The banner "Fillet 1 failed: … Show ×" stays until dismissed. The print check gains a "1 step failed · Show" row, Show opens the step and scrolls the timeline to it (`mac-light/comp/09b-failed-step.png`, `09c-show-failed.png`, `ipad-portrait-light/09b-failed-step.png`). |
| R06 "Tap" on the Mac | **Fixed** | [screen + code] | The Mac now says "Center rectangle · Click a corner" (`mac-light/comp/02a-drawing.png`). The em dashes are gone. |
| R07 Rollback not legible | **Fixed** | [screen] | The pill plus dashed, unfilled rolled-back chips with stronger hatching (`mac-light/comp/10-rolled-back.png`, `ipad-portrait-light/10-rolled-back.png`). |
| R08 No Mac hover | **Fixed** | [code] | `PointerHoverPlate` (`Theme.swift`). Primary and Secondary styles get hover states, and the view cube gets a face hover. A static capture can't show hover. |
| R09 Two Finish buttons | **Fixed** | [screen + marker check] | Exactly one in every layout. |
| R10 Picked edges invisible | **Partly fixed** | [screen] | Normally the picked edges are dashed, haloed and easy to read (`mac-light/comp/05-fillet-editing.png`). After a parametric change two of the four highlights land on the wrong edges. See N01. |
| R11 Brand bridge | **Fixed** | [screen] | Paper bed in light (`mac-light/comp/01-empty.png`), navy blueprint in dark (`mac-dark/comp/09b-failed-step.png`), view cube in theme colours. |
| R12 Grey on grey | **Fixed** | [screen] | Blue-grey model, contact shadow, an empty bed at about 70 %. |
| R13 No momentum | **Fixed** | [code] | `Momentum.flick` plus a `CADisplayLink` coast, caught on touch-down, skipped under Reduce Motion and after a pinch (`PlatformView+iOS.swift`). There are unit tests in `MomentumTests.swift`. |
| R14 Drawer not draggable | **Fixed** | [code + screen] | Three detents with velocity projection, rubber-banding, an adjustable action and a haptic (`InspectorView.swift` `InspectorDrawer`). Clipped rows fade out (`ipad-narrow-light/02a-drawing.png`). |
| R15 Hidden-body name 2.95:1 | **Fixed** | [code] | The row-level opacity is gone; the name is `inkSecondary` (5.37:1). |
| R16 Caliper 2.84:1 | **Fixed** | [code + measured] | `filletMark` is `#C94F0B` in light: 4.25:1 on the panel, 4.56:1 on white. |
| R17 Segmented controls | **Fixed** | [screen] | `ThemeSegmented`: equal widths on the Mac (`mac-light/comp/03-extrude-editing.png`), stacked at accessibility sizes (`ipad-a11y-portrait/03-extrude-editing.png`). |
| R18 "Line 3F2A" | **Fixed** | [code] | Now "Line 1, 2…". |
| R19 Accessibility-size inspector | **Fixed for feature editing; broken in sketch mode** | [screen] | Extrude at accessibility-large reads well: Clear under the text, a 380 pt inspector, stacked segments (`ipad-a11y-portrait/03-extrude-editing.png`). Sketch mode overflows (N02). |
| R20 Copy wraps | **Fixed** | [screen] | "Name a value, then use it in any field: `width / 2 + wall`"; the tip is rewritten. |
| R21 Double numbering | **Fixed** | [screen] | The ruler number shows only for the step being edited, or on hover. |
| R22 Projection button and flat cube | **Fixed** | [screen + code] | The cube tilts 15° in standard views (`ipad-portrait-light/02a-drawing.png`, TOP). The button is labelled by its action and has a value. |
| R23 Hint crossfade on every click | **Fixed** | [code] | Keyed on context (sketch, pick, start). |
| R24 3D view opaque to VoiceOver | **Fixed** | [code + harness check] | "3D view", value "1 body, 60 × 30 × 12 mm; 4 edges picked", plus actions. |
| R25 Disabled tools 2.08:1 | **Fixed** | [screen] | Full `inkTertiary` (3.85:1): readable as "off". |
| R26 Errors auto-dismiss | **Fixed** | [code + harness check] | Errors stay; info toasts pause on hover. |

**Summary:** 23 fixed, 2 partly fixed (R10, R19), and 1 fixed but regressed elsewhere (R01, through N02).

---

## New findings

**Severity:**

- **P0:** broken or inaccessible
- **P1:** clearly hurts the experience
- **P2:** polish
- **P3:** nice to have

| ID | Sev | Platform | Area | Observation and evidence | File:line | Concrete fix | Raises |
| --- | --- | --- | --- | --- | --- | --- | --- |
| N02 | **P0** (accessibility sizes) / **P1** (landscape) | iPad | Sketch bar layout | **[screen]** The sketch bar's variant chooser never folds tools into "More shapes". It reads `available` from `.frame(maxWidth: .infinity)` wrapped around the `.fixedSize()` bar, so the measured width is never smaller than the bar itself and variant 0 always "fits". When the full bar is wider than the viewport, the bar pushes the whole editor wider than the window, which then clips on both edges. The editor's width also feeds `EditorLayout`, which flips to `.regular` and moves Finish into the bar, making it wider still. **Landscape, normal text, light and dark:** "Browser", the sidebar text, the playback cluster and the inspector's toggle and Delete are cut at the edges (`crops/land-left-02a-drawing.png` vs `crops/land-left-07-pocket.png`; `crops/land-dark-02a-left.png`; `ipad-landscape-light/02a-drawing.png`). **Portrait at accessibility-large:** about 180 pt of overflow. The inspector's values, Snap value and Delete are off-screen, the hint is cut, and step back / to start are gone (`ipad-a11y-portrait/02a-drawing.png`, `ipad-a11y-portrait/06-sketch-on-face.png`). The harness misses this because its safe rect comes from the overflowed viewport. | `App/Sources/Views/EditorView.swift:671-680` (variant and measurement), `:200-203`, `:87` (`finishInBar` from `layout`), `:745` (`.fixedSize()`) | 1. Measure the room from a flexible view that doesn't contain the bar: `Color.clear.frame(maxWidth: .infinity, maxHeight: 0).onGeometryChange { available = $0.size.width }`, with the bar in an `.overlay(alignment: .leading)` of that view, so the bar can never widen its parent. 2. Choose `finishInBar` from the window size class or the measured window width, not from a width the content can inflate. 3. Add a harness check that `content.bounds.width == window width` and that the tool strip's leading item sits at x ≥ 0, in landscape and at `accessibility-large`. | Craft, Functionality, Accessibility (iPad) |
| N01 | P1 | both | Picked-edge preview | **[screen]** After the plate is widened from 60 to 80 mm through the timeline, opening Fillet 1 draws two of its four dashed "sharp edge" highlights at the *old* x = 60 position, through the pocket, instead of at the new right-hand corners. The fillet itself was correctly applied to the x = 80 corners (`mac-light/comp/09-widened.png`). The highlight resolves edge signatures with a different resolver than the kernel's, so after a parametric change it disagrees with what the feature actually rounds. Evidence: `mac-light/comp/09c-show-failed.png`, `ipad-portrait-light/09c-show-failed.png`. This is exactly the parametric workflow the owner cares about, and it makes the pick look broken. | `App/Sources/Session/EdgeHighlights.swift:15-22` | Draw what the kernel used: have the evaluator record the resolved input edge indices per edge feature (on success and on failure) and render `infos[i]` from that record, instead of re-resolving signatures in the UI. Add a harness check after `09-widened` that every highlighted edge is a vertical edge at a bounding-box corner. | Functionality, Craft |
| N03 | P2 | both | Bed label | **[screen + measured]** The "Bambu Lab A1 mini" label is centred on the bed's front-left corner, so the bed outline strikes through it (`mac-light/comp/01-empty.png`, `ipad-portrait-light/01-empty.png`). It is hard-coded `black.opacity(0.4)`: **2.79:1** on the paper, under 4.5:1 for 11 pt text. | `Sources/FilletViewport/ViewportView.swift:153-160` | Anchor the label *outside* the bed: project the corner, offset 8 pt along the bed's left edge direction, align it to that edge, and use `inkSecondary` (about 5:1 on paper) via the palette. Alternatively move it into the view-cube cluster as a small printer chip. | Craft, Accessibility |
| N04 | P3 | both | Segmented selection | **[measured]** In `ThemeSegmented` the selected segment's plate is `hairlineStrong` on `raised`, **1.47:1**. Selection rests mostly on semibold versus medium weight and ink versus `inkSecondary`. That is readable, but the plate is below the 3:1 non-text guideline for a state indicator. | `App/Sources/Views/InspectorView.swift` (`ThemeSegmented`) | Fill the selected plate with `Theme.ink.opacity(0.14)` and add a 1 pt `inkTertiary` border, or use `selectSoft` with `selectInk` text if it should read as a choice. | Craft, Accessibility |
| N05 | P3 | both (most visible in dark) | Sketch region fill | **[screen]** Closed sketch regions fill with the selection blue (`#2E9CFF` at 10 % in light, 14 % in dark). On the navy dark bed it reads as a saturated blue slab, and the picked blue circle sits on blue (`ipad-portrait-dark/02a-drawing.png`). Blue was meant to mean only "picked". | `Sources/FilletViewport/Palette.swift:86`, `:123` | Fill regions with ink at 6 % in light and with the paper colour at 8 % in dark. Keep blue for picked regions only (Extrude's profile pick). | Philosophy, Hierarchy |
| N06 | P3 | iPad | Copy at accessibility sizes | **[screen]** The "Construction" button hyphenates to "Con- / struction" at accessibility sizes (`ipad-a11y-landscape/02a-drawing.png`). | `App/Sources/Views/SketchInspector.swift:86-90` | At accessibility sizes stack Construction and Delete vertically at full width, or allow `.lineLimit(1).minimumScaleFactor(0.8)`. | Craft |

---

## What still holds each dimension below 8

### Mac

Only **Functionality (7)** is below 8.

1. **N01:** render picked-edge highlights from the edges the kernel actually resolved, and check it in the harness after the widening step. With that fixed, the Mac is 8 on all five dimensions.

### iPad 12.9"

**Craft (6) and Functionality (6):**

1. **N02:** measure the sketch bar's room from a flexible view that doesn't contain it, and take `finishInBar` from the window, not the inflated content width. Let "More shapes" actually fold. Add the window-width and leading-edge harness checks in landscape and at `accessibility-large`. This one fix lifts iPad Craft and Functionality to 7 and Accessibility back to at least 7.
2. **N01:** same fix as the Mac. With N02 that brings Functionality to 8.
3. **N06 and N03:** stack Construction and Delete at accessibility sizes, and move the bed label off the bed outline. With N02 this brings Craft to 8.

**Accessibility (5, supplementary):**

1. **N02** (the P0).
2. **N03** (2.79:1 label).
3. **N04** (selected-plate contrast).

The rest is already at 8.
