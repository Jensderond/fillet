# Fillet announcement — edit decision list

60.3 s, 30 fps. Deliverables: `Fillet-Announcement-16x9.mp4` (1920×1080), `Fillet-Announcement-Square.mp4`
(1080×1080), `Fillet-Announcement.srt`, `Fillet-Announcement-poster.png` (1920×1080).
Contact sheet: [`contact-sheet.png`](contact-sheet.png) (one frame a second, 16:9).

All app footage is one take of the DEBUG demo mode (`FILLET_DEMO=1`, `App/Sources/Debug/DemoDirector.swift`)
on the **iPad Pro 12.9" (6th gen) simulator**, iPadOS 26.5, portrait 2048×2732, light appearance, status bar
9:41. Times below are output times; "src" is time in the recording (`build/video/raw/take3.mp4`). The demo logs
every beat, tap, snap and camera swing with wall-clock times; `edit.py` maps them onto the output timeline,
so titles, voice-over, music cues and effects all follow the picture.

## Rebuild

```sh
docs/video/record-demo.sh build/video/raw/take3.mp4   # record the demo (≈70 s); writes take3.beats.txt
# set OFFSET in edit.py: recording time of the demo's t=0 (frame where the first rectangle lands − its beat)
python3 docs/video/build.py                           # plan, device clip, voice, music, mix, picture, SRT, poster (≈1.5 min)
docs/video/qc.sh                                      # contact sheet, loudness, stream checks
```

| File | Role |
|---|---|
| `record-demo.sh` | Builds the Debug app, prepares the 12.9" simulator, records the demo with `simctl io recordVideo` |
| `sync.py` | Rough finder for the splash's first frame in a take (the final OFFSET was checked by eye) |
| `edit.py` | The edit: segments, speeds, titles, callout, VO anchors, music cues, effect events |
| `voiceover.py` | The voice-over script (captions and spoken text) and its `say` render |
| `audio.py` | Original music bed and effects, synthesised with numpy |
| `compositor/main.swift` | Draws every frame (CoreGraphics + SwiftUI text); compiled with the app's splash sources |
| `build.py` | Runs everything above with ffmpeg and writes the deliverables to `build/video/out/` |
| `qc.sh` | Contact sheet, EBU R128 and clipping checks |

## Shots

| Out (s) | Shot | Source | Notes |
|---|---|---|---|
| 0.00–3.00 | Opener: the app's own launch splash, full frame | rendered by `SplashArtwork` | Slowed ×1.7 (resting frame at 2.3 s), dissolves into the same graph paper |
| 3.05–5.95 | Problem statement on paper | — | Kinetic title, strong ease-out |
| 6.00–15.79 | iPad enters; launch splash on device; Sketch on the bed: rectangle dragged out with the Pencil (snaps to the origin, live "53 mm × 26 mm" dims), Ø14 hole | src 2.42–12.21, ×1.0 | Device rises 90 px, 0.96→1 scale, 0.85 s ease-out |
| 15.49–21.45 | Extrude: camera swings to 3D, pick the plate profile, drag the arrow 1→12 mm, Done | src 13.51–20.66, ×1.2 | 0.3 s crossfade in |
| 21.15–26.50 | Fillet: tap the four vertical edges, Fillet, radius eases 1→5 mm, Done | src 21.03–27.45, ×1.2 | crossfade |
| 26.20–33.89 | Sketch on the top face: slot (three Pencil taps), Extrude → Cut, drag to −6 mm, back to 3D | src 27.67–41.51, ×1.8 | crossfade |
| 33.59–37.17 | Hero, set-up: tap Sketch 1 on the ruler, Select, tap the rectangle, orbit to ¾ | src 41.69–46.52, ×1.35 | crossfade |
| 37.17–42.56 | **Hero:** Width 60 → 80 mm; fillets and pocket follow live; Finish sketch | src 46.52–51.91, ×1.0 | Real time; big counter 60→80 beside it |
| 42.56–46.73 | Caliper scrubbed back to step 2 (later steps hatched), then forward step by step | src 51.91–57.54, ×1.35 | continuous |
| 46.73–51.88 | Print check: slow orbit, Overhangs on/off; card magnified beside the device | src 57.54–63.47, ×1.15 | Callout: screen pts (716,168) 296×372 at 1.55× |
| 51.88–56.03 | Export 3MF → system save sheet ("Save as Pen holder", iCloud Drive / On My iPad) | src 63.47–66.02 + 1.6 s hold | continuous |
| 55.88–60.28 | End card: icon, "Fillet", "Parametric CAD for the things you print.", "iPad and Mac" | — | Device exits 0.32 s; card staggers in 80 ms apart |

Square cut: the same timeline, device centred at the top (720 px tall), titles in a caption band below,
the hero counter on a paper chip over the device's lower-left, the print card magnified over the inspector.

## On-screen titles (16:9 left column, square caption band)

| In–out (s) | Eyebrow | Headline | Sub |
|---|---|---|---|
| 3.05–5.95 | — | CAD for 3D printing shouldn't need an account, or a connection. | — |
| 6.35–10.88 | Fillet | Parametric CAD for iPad and Mac. | Works fully offline. No account. |
| 11.08–15.59 | 01 Sketch | Sketch with Apple Pencil. | Live dimensions, grid snapping. |
| 15.84–21.25 | 02 Extrude | Pull a profile into a solid. | Drag the arrow, or type the distance. |
| 21.50–26.30 | 03 Fillet | Round the edges. | Four edges, 5 mm. |
| 26.55–33.69 | 04 Sketch on a face | Cut a pocket. | A slot on the top face, 6 mm deep. |
| 33.94–42.82 | 05 Timeline | Change one step. The rest follows. | Sketch 1, width — **60 → 80 mm** counter (37.84–39.29) |
| 42.97–47.14 | 05 Timeline | Roll back to any step. | Drag the caliper along the ruler. |
| 47.49–51.98 | 06 Print check | Ready for the printer. | (magnified print check card) |
| 52.33–55.83 | 07 Export | 3MF for Bambu Studio and PrusaSlicer. | STL and STEP too. One design is one .fillet file in Files or iCloud Drive. |

Lines enter 0.6 s with cubic-bezier(0.23, 1, 0.32, 1), 75 ms apart, rising 22 px; they leave in 0.26 s.

## Voice-over (macOS `say`, voice Daniel, en_GB, 166 wpm)

| In–out (s) | Line (caption text) |
|---|---|
| 3.20–6.94 | CAD for 3D printing shouldn't need an account, or a connection. |
| 7.19–11.45 | Fillet is parametric CAD for iPad and Mac. It works fully offline. |
| 11.70–16.01 | Sketch with Apple Pencil. Dimensions are live, and shapes snap to the grid. |
| 16.26–18.99 | Pick the profile, and pull it up into a solid. |
| 21.37–23.40 | Pick four edges, and round them. |
| 26.51–28.83 | Sketch on a face, and cut a pocket. |
| 33.65–38.36 | Every step lands on the timeline. Make the first sketch 80 mm wide, |
| 38.66–40.70 | and every step after it follows. |
| 43.02–45.06 | Roll back to any step with the caliper. |
| 47.14–51.75 | Check it before you print: it fits the bed, no overhangs, watertight. |
| 52.43–56.22 | Export 3MF for Bambu Studio or PrusaSlicer. |
| 56.63–59.81 | Fillet. Parametric CAD for the things you print. |

Sync checks: the Pencil's first stroke starts at 11.8 (line at 11.70); the profile pick lands at 17.1 ("Pick the
profile" 16.26–17.3); the width grows 37.8–39.3 as "…eighty millimetres wide" ends (38.36), and the counter tracks the field (checked frame by frame against the app's Width field);
the caliper starts moving at 42.9; the print check card is on screen through the whole print line. Spoken
spellings differ from captions only in "three-D", "eighty millimetres" and "three M F".

## Music cues (original, `audio.py`)

D major, 93.1 bpm (bar 2.577 s, chosen so downbeats land on the hero and on the end card).
Progression D – Bm – G – A, reset to D on the hero; plagal G → D into the end card.

| Time (s) | Cue |
|---|---|
| 0.0 | Soft pad fades in (1 s) under the opener; pencil-on-paper texture and a small swell as the splash fillet runs |
| 6.0 | iPad enters: pluck arpeggio in eighths, pad opens up |
| ≈7.5 | Sub bass enters |
| 33.6 | Timeline section: arpeggio in sixteenths, soft pulse on 1 and 3, shaker off-beats |
| 35.3–37.8 | Noise riser into the hero |
| 37.84 | **Hero downbeat** on D: tonic voiced an octave up, full pulse |
| 47.2 | Settles for print check and export: eighths again, pulse out |
| 55.88 | End card: everything else fades in 0.3 s; Dmaj9 rings with a rising pluck figure |
| 58.9–60.3 | Fade out |

## Effects (`audio.py`, all synthesised)

31 finger taps (soft 1.5 kHz tick), 5 Pencil touches (lighter 2.6 kHz tick), 8 snaps (tiny 3.4 kHz tick, the
same moments the app gives haptic alignment feedback), 6 caliper detents, 4 whooshes on camera swings
(15.9 into 3D, 32.9 back to 3D after the pocket, 36.2 the hero orbit, 47.2 the print-check orbit), and a
two-partial chime (D6 + A6) at 56.13 on the end card.

## Mix

Voice gained to about −16 LUFS, music to about −24.5 LUFS and ducked under the voice with
`sidechaincompress` (threshold 0.02, ratio 4, attack 25 ms, release 450 ms), effects −3 dB, music
high-passed at 35 Hz; then two-pass `loudnorm` (I −14, TP −1.5, linear). Measured on the final MP4s
(AAC 256 kb/s, 48 kHz stereo) with `ebur128=peak=true`: **−14.3 LUFS integrated, LRA 5.5 LU, true peak
−1.3 dBTP**, sample peak −1.28 dBFS, no clipped samples (flat factor 0). Voice is present in every
section; between lines the bed sits about 8–10 dB under the voice.
