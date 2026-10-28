# Fillet

Offline, parametric CAD for 3D-printable parts — native SwiftUI for iPad and Mac,
built on the OpenCascade 8 geometry kernel. Design with sketches and features on a
Fusion-style timeline, save as a normal `.fillet` file (Files / iCloud Drive), and
export 3MF for Bambu Studio.

![Fillet on macOS in light and dark mode: a filleted bracket in the viewport, with the browser, print check and timeline](docs/screenshots/mac-light-dark.png)

## Build

Requirements: Xcode 27, CMake (`brew install cmake`), XcodeGen (`brew install xcodegen`).

```sh
scripts/build-occt.sh          # once: builds OpenCascade as OCCT.framework for macOS, iOS and the iOS simulator (~30 min)
swift test                     # kernel, core and viewport tests
cd App && xcodegen generate    # creates App/Fillet.xcodeproj
open Fillet.xcodeproj          # pick the Fillet scheme, a Mac or your iPad, Run
```

To run on an iPad, put your team in `App/Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = ABCDE12345`.
A team picked under *Signing & Capabilities* is lost on the next `xcodegen generate`; this one isn't.

`scripts/release.sh 0.2.0` builds the Mac release: `build/release/Fillet-0.2.0.dmg`, with the
`fillet-mcp` helper inside the app (set the version in `App/project.yml` first).

### OpenCascade

Fillet uses [Open CASCADE Technology](https://github.com/Open-Cascade-SAS/OCCT) 8.0.1 under the
GNU LGPL 2.1 with the Open CASCADE exception. To keep it replaceable, `scripts/build-occt.sh` links
all of OCCT into one dynamic framework, `vendor/OCCT.xcframework` (`@rpath/OCCT.framework/OCCT`,
arm64 only, with a dSYM per platform), which the app embeds in `Contents/Frameworks` (Mac) or
`Frameworks` (iPad). The script resets `vendor/occt-src` to a clean `V8_0_1` tree and applies
Fillet's changes to OCCT from [`scripts/occt-patches`](scripts/occt-patches/README.md) before
every build. The app shows the licence texts under *Fillet ▸ Acknowledgements* (Mac) and on the
launch screen (iPad).

### Updates (Mac)

The Mac app updates itself from this repository's GitHub releases. Once a day (while *Check for
updates automatically* is on) and from *Fillet ▸ Check for Updates…*, it looks for the newest
release with a version above its own: a `v0.3.2` tag (prereleases count) with the DMG attached.
A new version shows as an orange *Update* button in the window toolbar. *Install Update* downloads
the DMG, checks it against the SHA-256 GitHub lists for the asset, and stages the new app; it
replaces the old one when Fillet quits (*Relaunch Now* quits and reopens). The swap is done by
`FilletUpdater.xpc` (`App/Updater`), which runs outside the app's sandbox. Where Fillet can't
replace itself (run from the DMG or a folder it can't write to, or macOS's App Management
refuses), the DMG opens for the usual drag to Applications. Offline, checks fail quietly.

To publish an update: run `scripts/release.sh`, then attach the DMG to a (pre)release tagged
`v<version>`. Release notes come from the release body; its *Install* and *Checksum* sections are left
out of the in-app notes. `FILLET_UPDATE_AS_VERSION=0.3.0` makes a build act as that version, to try an update.

## Layout

| Path | What |
|---|---|
| `Sources/CFilletKernel` | C++ bridge to OpenCascade behind a small C API (`include/FilletKernel.h`) |
| `Sources/FilletKernel` | Swift wrapper: `Shape`, `SketchRegions`, `Mesh`, geometry types |
| `Sources/FilletCore` | Document model, expressions & parameters, sketch shapes & tools, persistent references, recompute engine, print analysis, 3MF/STL export |
| `Sources/FilletViewport` | Metal renderer, camera, picking, touch/Pencil/mouse input |
| `Sources/FilletAgent` | MCP server for AI agents: modelling tools, HTTP + stdio transports, headless workspace |
| `Sources/fillet-mcp` | The headless MCP command (stdio), and a bridge to the running app |
| `App/` | The SwiftUI app (XcodeGen `project.yml`); `App/Updater` is the Mac updater's XPC service |
| `docs/design.md` | Design and architecture |
| `docs/icon/` | App icon sources (`build.sh` regenerates everything) |

## Agents (MCP)

AI agents can design in Fillet through its [MCP](https://modelcontextprotocol.io) server, while you
watch: every step lands in the open window and undoes like your own. The tools cover the whole
modelling workflow (sketch, extrude, revolve, loft, primitives, fillet, booleans, move/scale/mirror,
parameters, colours, print check, export) and `render_view` returns an image so the agent can look
at its work (`presentation: true` for a product-shot look; `target` and `size` for a close-up,
`projection: "orthographic"`, and a `section` cut that shows how parts fit inside). Agents can hide
bodies like the eye in the browser (`set_body_visibility`), or give `check_print` and `export` a
`bodies` list. A step that fails or breaks later steps
is refused with the kernel's reason instead of being added, and so is one that leaves a body that
isn't a valid closed solid (a failed cut also says whether cutting the other way round works). A change that still works but makes a
later fillet, chamfer, shell or lay-flat find its edges or faces somewhere else comes back with a
warning naming that step; `edit_feature` with `edges` or `faces` points it at the right ones again,
picked on the body as it is just before that step. A fillet or chamfer that fails says which edges can't take the size and
the largest size the others take. `undo` and `redo` say exactly what they took back (a new step, an
edit, a parameter…), take an optional `expect: "Edit Hat"` guard, and never undo one of your own
changes in the app unless the agent names it. `scale_bodies` can scale along turned axes (the
inspector then shows the turn under *Axes turned about*). `hole` takes screw presets (`"preset": "m3-clearance"`;
M2–M6 clearance, counterbore, countersink, tap or heat-set insert); clearance fits add the design's `clearance`
parameter (0.2 mm to start), so setting it once fits every screw hole to your printer.

Faces and edges are picked by index or by a filter that survives renumbering, such as
`{"created_by": "Join arm"}`: what that step made (here the seam the join left, ready to fillet).
Edges can also be picked as `{"chain_of": 12}` (edge 12's tangent chain, like a tap in Fillet),
`{"loop_of_face": 4}` (the face's outer boundary; `"loop": 1` for its first hole), or any filter
with `"tangent_chain": true`.

**Live, in the app.** Turn on *Design ▸ Allow Agent Connections* (or the ✦ toolbar button, whose
popover shows the setup for your copy). Then connect an agent:

- **Claude Code** talks to the app over HTTP:

  ```sh
  claude mcp add --transport http fillet http://127.0.0.1:7878/mcp
  ```

- **Claude Desktop** (stdio only) uses the helper inside the app, which bridges to the running
  Fillet. *Copy Claude Desktop config* in the ✦ popover copies the entry for
  `claude_desktop_config.json` (Settings ▸ Developer ▸ Edit Config):

  ```json
  {"mcpServers":{"fillet":{"command":"/Applications/Fillet.app/Contents/Helpers/fillet-mcp","args":["--connect"]}}}
  ```

The server prefers port 7878. When that is taken (another app, or a second copy of Fillet) it
uses the first free port of 7879–7888 and remembers it for the next launch; the popover always
shows the actual address. `fillet-mcp --connect` finds the app by itself: it reads the endpoint
the Mac app writes to its Application Support folder, then looks on 127.0.0.1:7878–7888, then for
an iPad over Bonjour. `--connect http://…/mcp` connects to an exact address.
`FILLET_MCP=1` turns the server on at launch and `FILLET_MCP_PORT` forces one port (no fallback).

On iPad the server listens on the network and needs the token shown in the ✦ popover
(`--header "Authorization: Bearer …"`, or `--token` / `FILLET_MCP_TOKEN` for `fillet-mcp --connect`).

**Headless**, no window, saving to a file after every step, with the helper from the app:

```sh
claude mcp add fillet-headless -- /Applications/Fillet.app/Contents/Helpers/fillet-mcp ~/Designs/bracket.fillet
```

The helper isn't sandboxed, so it can open and save `.fillet` files anywhere. From a checkout,
`swift build -c release --product fillet-mcp` builds the same command as `.build/release/fillet-mcp`.

The tools live in `Sources/FilletAgent` (protocol, transports, tools, headless workspace);
the app hosts them in `App/Sources/Agent`.

## End-to-end check (Mac)

A debug build can drive a full workflow (sketch → extrude → fillet → sketch on
face → pocket → parametric change → export) through the real UI code paths and
snapshot every step:

```sh
FILLET_AUTOMATION=1 build/dd/Build/Products/Debug/Fillet.app/Contents/MacOS/Fillet
# results: ~/Library/Containers/app.fillet.Fillet/Data/tmp/fillet-automation/
```

`FILLET_SCENARIO=selection` runs only the selection checks (tangent chains, loops, click and tap
rules, window and crossing boxes); `FILLET_SCENARIO=featurePattern` only the feature pattern.
