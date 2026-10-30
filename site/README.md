# Fillet Guide

The user guide for Fillet, built with [Astro](https://astro.build) and MDX. It has no docs theme: the layout, type and components are all in this folder.

## Run and build

```sh
cd site
pnpm install
pnpm dev        # http://127.0.0.1:4321, reloads as you edit
pnpm build      # static site in site/dist/
pnpm preview    # serve dist/ to check a build
```

To keep the dev server running in the background:

```sh
nohup pnpm exec astro dev --port 4321 --host 127.0.0.1 > ../build/docs-dev.log 2>&1 &
```

Astro 7 manages it as a daemon: `pnpm exec astro dev status`, `… dev logs` and `… dev stop`.

## Where things live

```
site/
  src/content/guides/<slug>.mdx   one file per guide (the URL is /guides/<slug>/)
  src/content.config.ts           the frontmatter schema
  src/data/groups.ts              hub sections, in order
  src/components/                 page building blocks (see "Writing a guide")
  src/components/glyphs.ts        the line icons for each guide
  src/layouts/Base.astro          header, footer, light/dark, the iPad/Mac switch
  src/layouts/Guide.astro         a guide page: title, lede, In this guide, body, related guides
  src/pages/index.astro           the hub
  src/pages/search.json.ts        the search index, built from every guide
  src/styles/global.css           every style, with colour tokens at the top
  src/assets/screens/<slug>/      screenshots and videos for each guide (see Screenshots)
  review/                         the dev-only review board, gitignored (see Progress board)
  public/brand/                   app icon sizes
```

## Writing a guide

A guide is an MDX file. A file with frontmatter and no body is a stub: it shows its `summary` as a "Being written" brief.

```mdx
---
title: "Drill holes for screws"
short: "Holes"                 # footer and tight lists
group: "Sketch & Model"        # one of src/data/groups.ts
order: 4                       # position within the group on the hub
blurb: "Clearance, counterbore, countersink and insert holes from M2 to M6."
lede: "One or two sentences under the title."
summary: "The writer's brief. Shown only while the body is empty."
related: ["parameters", "patterns", "selecting", "print-check-and-export"]
# glyph: "holes"               # defaults to the slug
# toc: false                   # hide "In this guide" (reference pages)
---

## Place the holes

One short paragraph that says what this section gets you.

1. Select the top face.
2. Tap <Ui icon="holes">Hole</Ui>, or press <Keys combo="H" />.
3. Tap where each screw goes.

<Figure src="/screens/holes/place.png" alt="Three centre marks on a plate" caption="Each tap adds a hole." />
```

Each `##` heading becomes a numbered section and an entry in **In this guide**. Steps are plain numbered lists. These components work in every guide without an import:

| Component | Use it for |
| --- | --- |
| `<Figure src alt caption />` | An iPad landscape screenshot on graph paper. Use `video` + `poster` for a clip, `device="mac"` for a Mac window, `width`/`height` for other sizes, `narrow` to keep it in the text column, `maxWidth` (CSS px) to cap a small crop, `phoneSrc`/`phoneWidth`/`phoneHeight` for a tighter crop on phones, `cutout` for a transparent cut-out (a popover with its own corners and shadow) that needs no frame, and `loop` with `video` for a short silent clip that repeats (`phoneSrc` is then the phone cut, `phonePoster` its poster). |
| `<Ui icon="holes">Hole</Ui>` | An app control named in the text, in bold, with an optional glyph. |
| `<Shot src alt />` | A bare screenshot (no figure frame), for pairs in a `fig-duo` or drawings in a `fig-anno` inside a `Figure`. |
| `<Keys combo="⇧⌘M" />` | Key caps. Use `"⌘Z / ⇧⌘Z"` for alternatives. |
| `<Tip title="Printing tip">…</Tip>` | A tip worth stopping for. |
| `<Note>…</Note>` | Small grey aside text, with no box. |
| `<Callout guide="parameters" />` | A card that links to another guide. Add `hash` to link to a section, or use `href`/`title`/`text` for any link. |
| `<CardGrid>…</CardGrid>` | Two callouts side by side. |
| `<Platforms><Platform name="iPad">…</Platform><Platform name="Mac">…</Platform></Platforms>` | An iPad / Mac switch. Every switch on the page stays in sync. |
| `<Shortcuts><Shortcut keys="⇧⌘K" note="…">New Sketch</Shortcut></Shortcuts>` | Shortcut tables. |
| `<FAQ><QA q="…">…</QA></FAQ>` | A question on the left with its answer on the right. |
| `<div class="split"><div>…</div><Figure … /></div>` | Steps beside a small crop (an inspector section). Stacks on phones. Set `--split` for the crop column (default 340px). |
| `<details class="ref"><summary>…</summary>…</details>` | A collapsed reference block, such as a size table. Wrap a wide table in `<div class="ref-scroll">`. |

`/guides/styleguide/` shows every component with sample content (source: `src/content/guides/styleguide.mdx`). It has `hidden: true`, which keeps it off the hub, the footer and search.

Voice: second person, plain and short. Use one point per paragraph and imperative steps ("Tap **Done**."), and spell control names the way the app shows them.

## Screenshots

- Put each guide's media in `src/assets/screens/<slug>/` with descriptive names such as `holes/preset-menu.png`. Reference them as `/screens/<slug>/<file>`.
- Screenshots are landscape iPad captures from the real app (`scripts/docs-shot.sh`, which runs headless on a simulator and writes to `build/docs-shots/`). Copy the frames you choose into `src/assets/screens/<slug>/`.
- Commit the full-quality PNG or JPEG. The build (Astro's image pipeline on sharp) turns every still into AVIF and WebP at 480–2400 px wide with a `srcset`, plus a PNG/JPEG fallback no wider than 1600 px, and video posters into WebP. A still's own file sets its `width` and `height`. Videos (`.mp4`) are copied as they are, so `Figure` needs their `width` and `height`.
- A path that doesn't match a file in `src/assets/screens/` fails the build, naming the path.
- Show the step first and the screenshot after it, as the Things guides do.

## Regenerating screenshots

Every published screenshot has a spec in `shots/<slug>/`: a JSON file that builds the scene through the app's agent tools, taps through the UI and names each capture. Fixtures (`.fillet` files) sit beside the specs in `fixtures/`. The full spec format is in `scripts/docs-shot.md`.

```sh
scripts/docs-shot-any.sh site/shots/holes/plate.json            # from the repo root
scripts/docs-shot-any.sh --build site/shots/holes/plate.json    # rebuild the app first
```

`docs-shot-any.sh` takes whichever of the four headless "Fillet Docs" simulators is free, so several specs can run at once. It never opens Simulator.app. Captures land in `build/docs-shots/<slug>/` at 2732×2048. A few slugs then need a second step, kept next to their specs:

- `crops.sh`, `crop.sh`, `publish.sh`: cut the full captures into the files in `src/assets/screens/<slug>/`.
- `record.sh`, `clip.py`, `*.clip.json`: record a spec's run and cut it into the looping videos and their posters.
- `sketching/hold-capture.sh`: grabs the shots that only exist while a finger is still down.

Where a slug has no crop script, the spec's capture names say which published file they become (for example `first-part.json`'s `fp-tour.png` becomes `window-tour.png`), and the crop is done by hand. A still's size comes from its file, so replacing it needs no other change. Only videos take `width` and `height` on their `Figure`.

## Progress board

`/progress` shows the docs review loop live and polls every 4 seconds. It exists only under `pnpm dev`, and only while `site/review/` is there: that folder is gitignored and holds the board (`progress.astro`, `progress-data.json.ts`, `integration.mjs`, which `astro.config.mjs` loads if present), its state (`review/data/<piece>.json`) and its images (`review/images/<piece>/`). A build never includes it.

```json
{ "piece": "holes", "status": "building", "round": 2,
  "history": [{ "round": 1, "verdict": "lose", "why": "…", "biggestGap": "…",
    "images": { "ours": { "desktop": "r1-desktop.png", "mobile": "r1-mobile.png" },
                "bar":  { "desktop": "/abs/path/bar-desktop.png", "mobile": "…" } } }] }
```

An image can be a file name in `review/images/<piece>/`, a `/progress/<piece>/<file>` path (the same folder), or an absolute path to a PNG, JPEG, WebP or GIF.

## Browser checks

Use headless Chrome only, for example with `agent-browser` in its own session, and never with `--headed`:

```sh
agent-browser --session docs set viewport 1440 900
agent-browser --session docs set media light
agent-browser --session docs open http://127.0.0.1:4321/
agent-browser --session docs screenshot --full hub-desktop.png
agent-browser --session docs close
```

Use 1440 px for desktop and 390 px for phones. The layout must not scroll sideways at 390 px.
