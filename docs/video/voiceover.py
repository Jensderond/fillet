#!/usr/bin/env python3
"""The voice-over script, and its render with macOS `say`.

Each line has the caption text (what the SRT shows, exactly), the text the voice
reads (spelled for the synthesiser: "three-D", "three M F"). Where each line
starts is decided in edit.py (`voice_starts`, anchored to the picture); this
file only renders them:

    python3 docs/video/voiceover.py OUT_DIR   ->  OUT_DIR/vo-01.wav … + vo.json (durations)
"""
import json, os, subprocess, sys

VOICE = "Daniel"   # best English voice installed here (no Premium/Enhanced/Siri voices available to `say`)
RATE = 166          # words per minute: calm, unhurried

LINES = [
    # id, caption (exactly what the SRT shows), spoken
    ("problem", "CAD for 3D printing shouldn't need an account, or a connection.",
                       "CAD for three-D printing shouldn't need an account, or a connection."),
    ("intro", "Fillet is parametric CAD for iPad and Mac. It works fully offline.",
                       "Fillet is parametric CAD for iPad and Mac. It works fully offline."),
    ("sketch", "Sketch with Apple Pencil. Dimensions are live, and shapes snap to the grid.",
                       "Sketch with Apple Pencil. Dimensions are live, and shapes snap to the grid."),
    ("extrude", "Pick the profile, and pull it up into a solid.",
                       "Pick the profile, and pull it up into a solid."),
    ("fillet", "Pick four edges, and round them.",
                       "Pick four edges, and round them."),
    ("pocket", "Sketch on a face, and cut a pocket.",
                       "Sketch on a face, and cut a pocket."),
    ("hero", "Every step lands on the timeline. Make the first sketch 80 mm wide,",
                       "Every step lands on the timeline. Make the first sketch eighty millimetres wide,"),
    ("follows", "and every step after it follows.",
                       "and every step after it follows."),
    ("rollback", "Roll back to any step with the caliper.",
                       "Roll back to any step with the caliper."),
    ("print", "Check it before you print: it fits the bed, no overhangs, watertight.",
                       "Check it before you print: it fits the bed, no overhangs, watertight."),
    ("export", "Export 3MF for Bambu Studio or PrusaSlicer.",
                       "Export three M F for Bambu Studio, or Prusa Slicer."),
    ("end", "Fillet. Parametric CAD for the things you print.",
                       "Fillet. Parametric CAD, for the things you print."),
]

def render(out):
    os.makedirs(out, exist_ok=True)
    meta = []
    for i, (key, caption, spoken) in enumerate(LINES, 1):
        aiff = os.path.join(out, f"vo-{i:02d}.aiff")
        wav = os.path.join(out, f"vo-{i:02d}.wav")
        subprocess.run(["say", "-v", VOICE, "-r", str(RATE), "-o", aiff, spoken], check=True)
        # Trim the synthesiser's leading/trailing silence so `start` is the first syllable.
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", aiff, "-af",
                        "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                        "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                        "aresample=48000,pan=stereo|c0=c0|c1=c0",
                        "-c:a", "pcm_s16le", wav], check=True)
        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
                                   capture_output=True, text=True, check=True).stdout)
        meta.append({"id": key, "duration": round(dur, 3), "caption": caption, "file": wav})
        os.remove(aiff)
    with open(os.path.join(out, "vo.json"), "w") as f:
        json.dump({"voice": VOICE, "rate": RATE, "lines": meta}, f, indent=1)
    return meta

if __name__ == "__main__":
    for m in render(sys.argv[1] if len(sys.argv) > 1 else "build/video/vo"):
        print(f"{m['id']:9s} {m['duration']:5.2f}s  {m['caption']}")
