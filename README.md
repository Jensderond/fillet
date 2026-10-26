# Fillet

Offline, parametric CAD for 3D-printable parts — native SwiftUI for iPad and Mac,
built on the OpenCascade 8 geometry kernel. Design with sketches and features on a
Fusion-style timeline, save as a normal `.fillet` file (Files / iCloud Drive), and
export 3MF for Bambu Studio.

![Fillet on macOS in light and dark mode: a filleted bracket in the viewport, with the browser, print check and timeline](docs/screenshots/mac-light-dark.png)

## Build

Requirements: Xcode 27, CMake (`brew install cmake`), XcodeGen (`brew install xcodegen`).

```sh
scripts/build-occt.sh          # once: builds OpenCascade for macOS, iOS and the iOS simulator (~30 min)
swift test                     # kernel, core and viewport tests
cd App && xcodegen generate    # creates App/Fillet.xcodeproj
open Fillet.xcodeproj          # pick the Fillet scheme, a Mac or your iPad, Run
```

To run on an iPad, put your team in `App/Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = ABCDE12345`.
A team picked under *Signing & Capabilities* is lost on the next `xcodegen generate`; this one isn't.

## Layout

| Path | What |
|---|---|
| `Sources/CFilletKernel` | C++ bridge to OpenCascade behind a small C API (`include/FilletKernel.h`) |
| `Sources/FilletKernel` | Swift wrapper: `Shape`, `SketchRegions`, `Mesh`, geometry types |
| `Sources/FilletCore` | Document model, expressions & parameters, sketch shapes & tools, persistent references, recompute engine, print analysis, 3MF/STL export |
| `Sources/FilletViewport` | Metal renderer, camera, picking, touch/Pencil/mouse input |
| `Sources/FilletAgent` | MCP server for AI agents: modelling tools, HTTP + stdio transports, headless workspace |
| `Sources/fillet-mcp` | The headless MCP command (stdio), and a bridge to the running app |
| `App/` | The SwiftUI app (XcodeGen `project.yml`) |
| `docs/design.md` | Design and architecture |
| `docs/icon/` | App icon sources (`build.sh` regenerates everything) |

## Agents (MCP)

AI agents can design in Fillet through its [MCP](https://modelcontextprotocol.io) server, while you
watch: every step lands in the open window and undoes like your own. The tools cover the whole
modelling workflow (sketch, extrude, revolve, loft, primitives, fillet, booleans, move/scale/mirror,
parameters, colours, print check, export) and `render_view` returns an image so the agent can look
at its work (`presentation: true` for a product-shot look). A step that fails or breaks later steps
is refused with the kernel's reason instead of being added. A change that still works but makes a
later fillet, chamfer, shell or lay-flat find its edges or faces somewhere else comes back with a
warning naming that step.

Faces and edges are picked by index or by a filter that survives renumbering, such as
`{"created_by": "Join arm"}`: what that step made (here the seam the join left, ready to fillet).

**Live, in the app.** Turn on *Design ▸ Allow Agent Connections* (or the ✦ toolbar button, which
also shows the setup command). Then, for Claude Code:

```sh
claude mcp add --transport http fillet http://127.0.0.1:7878/mcp
```

On iPad the server listens on the network and needs the token shown in the ✦ popover
(`--header "Authorization: Bearer …"`). `FILLET_MCP=1` turns the server on at launch and
`FILLET_MCP_PORT` picks another port. For stdio-only clients, `fillet-mcp --connect` bridges to the app.

**Headless**, no window, saving to a file after every step:

```sh
swift build -c release --product fillet-mcp
claude mcp add fillet-headless -- "$PWD/.build/release/fillet-mcp" ~/Designs/bracket.fillet
```

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
