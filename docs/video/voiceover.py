#!/usr/bin/env python3
"""The voice-over script, and its render: Fish Audio S2.1 Pro through OpenRouter,
or macOS `say` as the offline fallback.

Each line has the caption text (what the SRT shows, exactly), the text the voice
reads (spelled for the synthesiser: "three-D", "three M F"). Where each line
starts is decided in edit.py (`voice_starts`, anchored to the picture); this
file only renders them:

    python3 docs/video/voiceover.py OUT_DIR   ->  OUT_DIR/vo-01.wav … + vo.json (durations)

VO_ENGINE=openrouter (default) needs OPENROUTER_API_KEY; FISH_VOICE picks a Fish
voice ID (empty: the model's default voice). Fish's pace varies from take to take
(up to a second on a five-second line), so each line is rendered TAKES times and
the shortest take kept; edit.voice_tempo speeds up what still overruns. Responses
are cached by request and take in build/video/vo-cache, so a rebuild doesn't spend
requests again. VO_ENGINE=say renders with `say` instead.
"""
import hashlib, json, os, subprocess, sys, time, urllib.error, urllib.request

ENGINE = os.environ.get("VO_ENGINE", "openrouter")

VOICE = "Daniel"   # `say`: best English voice installed here (no Premium/Enhanced/Siri voices available to `say`)
RATE = 166          # `say`: words per minute, calm, unhurried

MODEL = "fish-audio/s2.1-pro-free:free"
FISH_VOICE = os.environ.get("FISH_VOICE", "")
TAKES = int(os.environ.get("FISH_TAKES", "3"))
INSTRUCTIONS = "Warm, confident product narration at a brisk, natural pace, like a polished Apple keynote voice-over."
CACHE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "build/video/vo-cache")

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

def fish(spoken, take=0):
    """One take of a line from Fish Audio via OpenRouter's /audio/speech, as an mp3 (cached by request and take)."""
    body = {"model": MODEL, "input": spoken, "instructions": INSTRUCTIONS, "response_format": "mp3"}
    if FISH_VOICE:
        body["voice"] = FISH_VOICE
    data = json.dumps(body, sort_keys=True).encode()
    path = os.path.join(CACHE, hashlib.sha256(data).hexdigest()[:16] + (f"-{take}" if take else "") + ".mp3")
    if os.path.exists(path):
        return path
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        raise SystemExit("OPENROUTER_API_KEY is not set (or render with VO_ENGINE=say)")
    req = urllib.request.Request("https://openrouter.ai/api/v1/audio/speech", data=data, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-Title": "Fillet announcement"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                audio = r.read()
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503) and attempt < 4:
                time.sleep(2 ** attempt * 3)
                continue
            raise SystemExit(f"OpenRouter {e.code}: {e.read().decode(errors='replace')}")
    os.makedirs(CACHE, exist_ok=True)
    with open(path, "wb") as f:
        f.write(audio)
    return path


def trim(src, wav):
    """Trim the synthesiser's leading/trailing silence so `start` is the first syllable; returns the duration."""
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-af",
                    "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                    "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                    "aresample=48000,pan=stereo|c0=c0|c1=c0",
                    "-c:a", "pcm_s16le", wav], check=True)
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
                                capture_output=True, text=True, check=True).stdout)


def render(out):
    os.makedirs(out, exist_ok=True)
    meta = []
    for i, (key, caption, spoken) in enumerate(LINES, 1):
        wav = os.path.join(out, f"vo-{i:02d}.wav")
        if ENGINE == "say":
            src = os.path.join(out, f"vo-{i:02d}.aiff")
            subprocess.run(["say", "-v", VOICE, "-r", str(RATE), "-o", src, spoken], check=True)
            dur = trim(src, wav)
            os.remove(src)
        else:
            takes = []
            for take in range(TAKES):
                t_wav = os.path.join(out, f"vo-{i:02d}.take{take}.wav")
                takes.append((trim(fish(spoken, take), t_wav), t_wav))
            dur, best = min(takes)
            os.replace(best, wav)
            for _, t_wav in takes:
                if os.path.exists(t_wav):
                    os.remove(t_wav)
        meta.append({"id": key, "duration": round(dur, 3), "caption": caption, "file": wav})
    voice = {"engine": "say", "voice": VOICE, "rate": RATE} if ENGINE == "say" else \
            {"engine": "openrouter", "model": MODEL, "voice": FISH_VOICE or "default", "instructions": INSTRUCTIONS, "takes": TAKES}
    with open(os.path.join(out, "vo.json"), "w") as f:
        json.dump({**voice, "lines": meta}, f, indent=1)
    return meta

if __name__ == "__main__":
    for m in render(sys.argv[1] if len(sys.argv) > 1 else "build/video/vo"):
        print(f"{m['id']:9s} {m['duration']:5.2f}s  {m['caption']}")
