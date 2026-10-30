#!/usr/bin/env python3
"""Finds when each logged action of a section take shows in the picture.

    python3 docs/video/section/sync.py build/video/section/raw/take.mp4   -> prints a table, writes <take>.sync.json

The beat log (<take>.beats.txt, from DemoDirector) carries wall-clock times; the take's first
frame comes some time after <take>.start.txt. For every action that changes the viewport (the
cut opening, a flip, 2D, ...) this looks for the first frame, at 60 fps, where the screen
changes (0.4 % of the pixels by more than 12 levels: a camera starting
to move, a switch, a cut opening; a touch marker is smaller than that) within 0.6 s of the logged time, and takes the median lag over them as the
take's offset, and the frame where the screen changes most (the cut opening rather than the
button that asked for it), which edit.py starts a shot on. Small actions (a press, the arrow starting to move) are placed with that offset.
"""
import json, re, subprocess, sys
import numpy as np

FPS = 60
W, H = 192, 256  # the 2048 × 2732 portrait screen, small
# Actions whose picture change is large and immediate: they measure the take's offset.
VISIBLE = ["section-tool", "reveal", "flip", "untilt", "2d", "section-only", "3d", "off"]


def load_beats(path):
    out = []
    for line in open(path):
        m = re.match(r"beat (\S+) t=([\d.]+) epoch=([\d.]+)", line)
        if m:
            out.append((m[1], float(m[2]), float(m[3])))
    return out


def frames(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={FPS}:start_time=0:round=up,scale={W}:{H}:flags=area",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    # Frame i is the latest frame of the (variable rate) take at or before i / 60 s, as edit.py cuts it.
    return np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)


def change(f):
    """Fraction of pixels that change by more than 12 levels from one frame to the next (index i: frame i vs i-1)."""
    d = np.abs(np.diff(f, axis=0)) > 12
    return np.concatenate([[0.0], d.mean(axis=(1, 2))])


def onset(ch, t0, t1, thresh=0.004):
    a, b = max(int(t0 * FPS), 1), min(int(t1 * FPS), len(ch) - 1)
    for i in range(a, b):
        if ch[i] > thresh:
            return i / FPS
    return None


def biggest(ch, t0, t1):
    """The frame of the largest change in a window (the cut opening, not the button that asked for it)."""
    a, b = max(int(t0 * FPS), 1), min(int(t1 * FPS), len(ch) - 1)
    return (a + int(np.argmax(ch[a:b]))) / FPS


def analyse(take):
    base = take[:-4]
    beats = load_beats(base + ".beats.txt")
    start = float(open(base + ".start.txt").read())
    f = frames(take)
    ch = change(f)
    # Rough lag first (simctl starts writing about 1.6 s after the start time is noted).
    lags = []
    for name, _, epoch in beats:
        if name in VISIBLE:
            guess = epoch - start
            o = onset(ch, guess + 0.8, guess + 3.0)
            if o is not None:
                lags.append(o - guess)
    rough = float(np.median(lags))
    found, main = {}, {}
    for name, _, epoch in beats:
        if name in VISIBLE:
            t = epoch - start + rough
            o = onset(ch, t - 0.25, t + 0.6)
            found[name] = None if o is None else o - (epoch - start)
            main[name] = biggest(ch, t - 0.25, t + 0.6) - (epoch - start)
    lag = float(np.median([v for v in found.values() if v is not None]))
    rows = []
    for name, tt, epoch in beats:
        rows.append(dict(name=name, demo=tt, take=round(epoch - start + lag, 4),
                         seen=None if found.get(name) is None else round(epoch - start + found[name], 4),
                         main=None if name not in main else round(epoch - start + main[name], 4)))
    grid = next((float(m[1]) for m in re.finditer(r"beat grid t=\S+ epoch=([\d.]+) bpm=([\d.]+)", open(base + ".beats.txt").read())), None)
    bpm = float(re.search(r"bpm=([\d.]+)", open(base + ".beats.txt").read())[1])
    out = dict(take=take, lag=round(lag, 4), grid_take=round(grid - start + lag, 4), bpm=bpm, frames=len(f), events=rows,
               lags={k: (None if v is None else round(v, 4)) for k, v in found.items()})
    json.dump(out, open(base + ".sync.json", "w"), indent=1)
    return out


if __name__ == "__main__":
    out = analyse(sys.argv[1])
    beat = 60 / out["bpm"]
    print(f"lag {out['lag']:.3f} s, grid starts at {out['grid_take']:.3f} s of the take, beat {beat:.4f} s")
    for e in out["events"]:
        if e["name"] in ("touch",):
            continue
        k = (e["take"] - out["grid_take"]) / beat
        seen = "" if e["seen"] is None else (f"  seen {e['seen']:7.3f} ({(e['seen'] - out['grid_take']) / beat:6.2f} beats),"
                                             f" most {e['main']:7.3f} ({(e['main'] - out['grid_take']) / beat:6.2f} beats)")
        print(f"{e['name']:14s} take {e['take']:7.3f}  beat {k:6.2f}{seen}")
