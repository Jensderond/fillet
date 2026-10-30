# Docs screenshots (iPad, landscape, headless)

`scripts/docs-shot.sh` takes screenshots of the real iPad app (the DocumentGroup window, not the
`FILLET_AUTOMATION` app) from a JSON spec. It runs the UI test
`App/UITests/DocsScreenshotUITests.swift` with `xcodebuild test-without-building`, which boots the
simulator headless. It never opens Simulator.app and sends no keystrokes or clicks to the Mac.

```sh
scripts/docs-shot.sh <spec.json> [simulator]     # simulator: 1-4, "Fillet Docs N" or a UDID (default 1)
scripts/docs-shot.sh --build <spec.json> 2       # rebuild first (otherwise only when sources changed)
scripts/docs-shot.sh --keep-app <spec.json> 3    # keep the installed app and its files (default: clean reinstall)
scripts/docs-shot.sh --setup                     # once: create the four simulators and warm them up
```

It prints each PNG it wrote as `<path> <width>x<height>`. Logs go to `build/docs-shots/logs/`. A
failed run keeps its result bundle in `build/docs-shots/results/` (screen recording, UI tree,
crash log), which you can read with `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`.

## Simulators

Use one simulator per writer. Simulators share the Mac's network, so each one has its own agent
(MCP) port. The wrapper chooses the port from the simulator's name.

| Name          | UDID                                   | MCP port |
|---------------|----------------------------------------|----------|
| Fillet Docs 1 | `24746C17-A294-44FA-978A-95BE26DE248B` | 7901     |
| Fillet Docs 2 | `47A8752B-EFC3-4984-8917-8E2696E6D7A1` | 7902     |
| Fillet Docs 3 | `4B388507-3A2C-436A-A591-D133A0025C7B` | 7903     |
| Fillet Docs 4 | `23E437AD-0F85-4A84-9C71-9D9C63F610CB` | 7904     |

All four are iPad Pro (12.9-inch) (6th generation) on iOS 26.5, the owner's iPad size: 1366×1024 pt
in landscape, so a full screenshot is **2732×2048 px**. Never run two specs on the same simulator
at the same time. Different simulators can run in parallel; three concurrent runs worked. The
simulators stay booted (headless) after a run. To free memory, run `xcrun simctl shutdown "Fillet Docs 1"`.

Each run sets the appearance (`light`, or the spec's `"appearance"`) and a 9:41 status bar (full
battery and Wi-Fi). It also reinstalls the app, so no files, Recents or settings carry over from
earlier runs, and copies the spec's `"fixture"` into the app's Documents.

## Spec

Relative paths resolve against the spec's folder. JSON doesn't allow comments.

```json
{
  "start": "new",
  "fixture": "fixtures/bracket.fillet",
  "appearance": "light",
  "port": 7901,
  "orientation": "landscape",
  "outDir": "../../build/docs-shots/sample",
  "launchArguments": ["-fingerDraws", "YES"],
  "steps": [
    {"do": "mcp", "tool": "fillet", "arguments": {"body": "Bracket", "edges": {"type": "line", "near": [-24, 0, 6], "limit": 1}, "radius": 6}, "timeout": 120, "allowError": false},
    {"do": "idle"},
    {"do": "tap", "label": "Step 3, Inner fillet"},
    {"do": "doubleTap", "x": 683, "y": 700},
    {"do": "longPress", "labelContains": "Inner fillet", "duration": 1},
    {"do": "drag", "from": {"x": 500, "y": 700}, "to": {"x": 650, "y": 650}, "press": 0.05, "velocity": 300, "hold": 0.1},
    {"do": "type", "into": {"labelContains": "Radius", "type": "textField"}, "text": "4.5", "clear": true},
    {"do": "key", "key": "return", "modifiers": []},
    {"do": "panel", "name": "browser", "show": false},
    {"do": "rotate", "to": "portrait"},
    {"do": "save"},
    {"do": "wait", "seconds": 1.5},
    {"do": "waitFor", "label": "Done", "timeout": 10, "gone": true},
    {"do": "screenshot", "path": "hero.png", "settle": true},
    {"do": "screenshot", "path": "step.png", "of": {"labelContains": ", Inner fillet", "padding": 8}},
    {"do": "dump", "path": "tree.txt"}
  ]
}
```

Top-level keys (all optional):

| Key | Meaning |
|---|---|
| `start` | `"new"` (default) taps New Design. `{"open": "name.fillet"}` opens that file from the launch browser. `"none"` stays on the launch screen, in portrait. |
| `fixture` | A `.fillet` file that the wrapper copies into the app's Documents before launch. Pair it with `{"open": …}`. |
| `fixtures` | More files to copy there, as a list: several designs for the browser, or a `.step` to import. |
| `appearance` | `light` (default) or `dark`. The wrapper reads it. |
| `port` | Overrides the per-simulator MCP port. |
| `appPort` | `true` forces no port: the app picks its own, as for a user (7878, then 7879–7888), so the Agents popover shows a real address. `mcp` steps can't reach the app then. |
| `orientation` | Applied after the document opens: `landscape` (default, = `landscapeLeft`), `landscapeRight` or `portrait`. |
| `outDir` | Base folder for relative screenshot and dump paths. Defaults to the spec's folder. |
| `launchArguments` | Extra app arguments, such as user defaults (`-fingerDraws YES`). |
| `clientName` | The MCP client name the harness sends (default `docs-shot`). The agent pill shows it, or "Claude" for any name containing "claude". |

Steps (`"do"`):

| Step | Fields |
|---|---|
| `mcp` | `tool`, `arguments`, `timeout` (s, default 120), `allowError`. Calls a tool on the app's agent server. A tool error fails the run. Tools: get_design, get_feature, list_faces, list_edges, measure, check_print, render_view, set_view, new_design, rename_design, list_designs, select_design, undo, redo, set_parameter, delete_parameter, create_sketch, add_sketch_shapes, extrude, revolve, primitive, loft, fillet, chamfer, shell, hole, press_pull, combine, move_bodies, scale_bodies, mirror, pattern, lay_flat, edit_feature, delete_feature, set_body_color, set_body_visibility, export (schemas: `Sources/FilletAgent`). |
| `idle` | Waits until the agent pill is gone (it stays 2.6 s after the last tool call) and "Updating" isn't shown, then 0.5 s more. |
| `tap`, `doubleTap`, `longPress` | A target. `longPress` takes `duration`. |
| `drag` | `from`/`to` targets, `press` (s held before moving), `velocity` (pt/s), `hold` (s at the end). |
| `type` | `text`, optional `into` target (tapped first), `clear` (empties the field first). |
| `key` | `key` (a character, or escape, return, delete, tab, space, up, down, left, right), `modifiers` (command, shift, option, control). |
| `panel` | `name`: `browser` or `overhangs` (tool strip toggles; any toggle label works), `show`: true/false. Taps the toggle only if needed. |
| `rotate` | `to`: an orientation as above. Waits 2 s. |
| `save` | Goes to the home screen and back, which makes the document save. Use it to make fixtures (see below). |
| `wait` | `seconds`. |
| `waitFor` | A target, `timeout`, `gone` (wait for it to disappear instead). |
| `screenshot` | `path`, `settle` (default true: runs `idle` first), `of` (a target to crop to, plus `padding` in pt). |
| `dump` | `path`. Writes the accessibility tree, which is how you find labels. |

A **target** is one of `{"id": …}`, `{"label": …}` (exact), `{"labelContains": …}`, or
`{"x": …, "y": …}`. Elements can be narrowed with `"type"` (button, staticText, textField, cell,
image, other) and `"index"`, and moved with `"dx"`/`"dy"` (pt from the centre). They are waited
for up to `"timeout"` s (default 10). Useful labels: tool strip buttons by title ("Sketch",
"Fillet", "Browser"), timeline steps as "Step 3, Inner fillet", "Play to end", "Done", "Cancel".

## Samples

`scripts/docs-shot-samples/`:

- `bracket.json`: a filleted bracket made over MCP, nothing selected, landscape.
- `rounded-block.json`: the browser hidden.
- `frog-fixture-dark.json`: a fixture (`Benchmarks/frog-wizard.fillet`) in dark mode, with a timeline crop.
- `warmup.json`: used by `--setup`.

Their output is in `build/docs-shots/sample/`.

## Timing

| Situation | Time |
|---|---|
| Warm simulator, no rebuild | 20–30 s per spec, including the clean reinstall |
| New Design hits DocumentManager error 1 | ~45–50 s (the harness recovers) |
| First run on a just-created simulator | ~100 s (boot, plus relaunches until the browser can open files) |
| Rebuild after a source change | ~55 s (incremental; one build at a time, other runs wait on a lock) |

## Gotchas

- **DocumentManager error 1.** In the simulator, New Design often creates `Untitled.fillet` but
  can't open it. The test dismisses the alert and taps the file in the browser. If that fails, it
  relaunches the app, up to three launches. On a newly created simulator, the browser can't open
  any file for the first minute or two. `--setup` does a warm-up run on each simulator. If a run
  still fails with "Couldn't open … after three launches", run it again.
- **Tap coordinates** are points in the current orientation (1366×1024 in landscape, 1024×1366 in
  portrait), from the top-left of the screen. Prefer labels. The launch screen's accessibility
  frames don't match its drawing, so the test taps New Design at a measured portrait point. That is
  why the app opens in portrait and rotates afterwards.
- **Waiting for recompute.** An `mcp` call returns once the step has been made, but the agent pill
  stays up 2.6 s and big recomputes show "Updating". `idle` (which every screenshot runs by default)
  waits for both. After loading a heavy fixture, or after a `tap` that changes the design, add an
  explicit `idle`.
- **Hide panels before framing.** `set_view` frames the part for the viewport as it is. Toggle the
  browser first, then call `set_view`.
- **Fixtures keep their rollback marker.** The frog benchmark opens at "Showing step 0 of 80". Tap
  `{"labelContains": "Play to end"}`.
- **Making a fixture:** build it over MCP, add `{"do": "save"}`, and keep the run's app with
  `--keep-app` on the next run, or copy the file out:
  `cp "$(xcrun simctl get_app_container 24746C17-A294-44FA-978A-95BE26DE248B app.fillet.Fillet data)/Documents/Bracket.fillet" …`.
  Without `save`, the file on disk is still empty when the test ends.
- **Typing** brings up the on-screen keyboard, and it shows in screenshots. Finish with "Done" or
  `key return` and wait before taking the shot.
- **Element crops** come from the full screenshot. An element that is scrolled off screen (a
  timeline step after Play to end, say) fails the step instead of giving a black image.
- **Status bar:** 09:41 (24-hour, following the Mac's locale) and "Sun 9 Jan". The simulator picks
  that weekday. iPadOS 26 also draws its window-resize grip in the bottom-right corner of every shot.
- **Rebuilds:** the wrapper rebuilds into `build/dd-docs` when anything in `App/Sources`,
  `App/UITests`, `App/Resources`, `Sources`, `Package.swift` or `App/project.yml` is newer than the
  built test bundle, and it runs `xcodegen generate` first. Pass `--build` to force a rebuild.
