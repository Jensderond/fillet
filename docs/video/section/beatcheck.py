#!/usr/bin/env python3
"""Checks the Section view film against its beat grid (timeline.py: 112.5 bpm, 16 frames a beat).

    python3 docs/video/section/beatcheck.py [film.mp4]     # default build/video/section/out/Fillet-Section-View.mp4

Lists, with each one's error in ms from where it should land:
  - every cut (the device coming in, each new shot, the end card): on a downbeat
  - every title line coming in: on a beat or a half-beat
  - every action of the demo, as its beat log places it through the edit, and, for those that
    change the picture, the first frame of the film that shows it (from the take, through the
    edit); key moments on downbeats, the rest on beats or half-beats
  - the same picture changes measured again in the finished film (the first frame, in the
    device, that changes)
  - the music's hits on the key downbeats and taps, found in the film's audio (the hits' own
    stem cross-correlated with it), so encoding and muxing are checked too
Fails (exit 1) when anything is more than one frame (33.3 ms) off.
"""
import json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import edit
import timeline as tl

FRAME = 1 / tl.FPS
LIMIT = FRAME * 1000 + 0.05  # ms
FLIGHTS = {"3d"}  # actions that start a camera flight (back from 2D)
FILM = sys.argv[1] if len(sys.argv) > 1 else os.path.join(edit.B, "out/Fillet-Section-View.mp4")
rows, failures = [], []


def where(t):
    """(bar, beat) of t, and the error from the nearest beat and half-beat, in ms."""
    k = t / tl.BEAT
    return int(k // 4), k % 4, (t - round(k) * tl.BEAT) * 1000, (t - round(k * 2) * tl.BEAT / 2) * 1000


def row(kind, what, t, should, err):
    ok = abs(err) <= LIMIT
    bar, beat, _, _ = where(t)
    rows.append((kind, what, t, f"{bar}.{beat:.2f}".rstrip("0").rstrip("."), should, err, ok))
    if not ok:
        failures.append(f"{kind} {what}: {err:+.1f} ms")


def grid_error(t, on):
    """Error from the nearest downbeat, beat or half-beat."""
    step = {"downbeat": tl.BAR, "beat": tl.BEAT, "half-beat": tl.BEAT / 2}[on]
    return (t - round(t / step) * step) * 1000


# Cuts.
for t, what in edit.cuts():
    row("cut", what, t, "downbeat", grid_error(t, "downbeat"))
    if abs(t * tl.FPS - round(t * tl.FPS)) > 1e-6:
        failures.append(f"cut {what} isn't on a frame")

# Title lines.
plan = edit.plan()
for title in plan["titles"]:
    for i, s in enumerate(title["line_starts"][: 2 + len(title["sub"]) - (0 if title["eyebrow"] else 1)]):
        row("title", f"{title['key']} line {i + 1}", s, "half-beat", grid_error(s, "half-beat"))
if plan.get("stat"):
    row("title", "60 fps", plan["stat"]["start"], "downbeat", grid_error(plan["stat"]["start"], "downbeat"))
row("title", "end card", plan["end_card"] + plan["end_card_delay"], "downbeat", grid_error(plan["end_card"] + plan["end_card_delay"], "downbeat"))

# Actions: logged, and seen in the take, through the edit.
for name, (bar, beat, key) in tl.ACTIONS.items():
    want = tl.t(bar, beat)
    should = "downbeat" if key else ("beat" if beat == int(beat) else "half-beat")
    hits = [e for e in edit.S["events"] if e["name"] == name]
    if not hits:
        failures.append(f"{name}: not in the beat log")
        continue
    e = hits[0]
    o = edit.out_time(e["take"])
    anchored = next((sh for sh in edit.SHOT_LIST if sh["anchor"] == name), None)
    if o is None and anchored:
        # The shot starts on the frame the picture first shows it, after the logged instant: the
        # cut skips the frames in between (the picture's lag in the take).
        lag = (e["main"] - e["take"]) * 1000
        row("action", f"{name} (logged; shot starts {lag:.0f} ms on)", anchored["out_start"], f"{should} {bar}.{beat:g}",
            (anchored["out_start"] - want) * 1000)
    elif o is None:
        failures.append(f"{name}: cut out of the film")
        continue
    else:
        row("action", f"{name} (logged)", o, f"{should} {bar}.{beat:g}", (o - want) * 1000)
    if e["seen"] is not None:
        o2 = edit.out_time(e["seen"])
        if o2 is None and anchored:  # the first, small change (a button) is in the frames the cut skips
            o2 = anchored["out_start"]
        row("picture", f"{name} (take, first change)", o2, f"{should} {bar}.{beat:g}", (o2 - want) * 1000)
        # A camera flight changes most in its middle: only its start is the action's moment.
        if name not in FLIGHTS:
            o3 = edit.out_time(e["main"])
            row("picture", f"{name} (take, biggest change)", o3, f"{should} {bar}.{beat:g}", (o3 - want) * 1000)


# Picture changes measured in the film: the first frame after an action's beat (within ±3
# frames) where the device's screen changes, for actions that don't start a shot.
def film_frames(path, w=320, h=180):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={w}:{h}:flags=area", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(np.int16)


f = film_frames(FILM)
change = np.concatenate([[0.0], (np.abs(np.diff(f[:, :, 150:], axis=0)) > 12).mean(axis=(1, 2))])
shot_starts = {round(s["out_start"] * tl.FPS) for s in edit.SHOT_LIST}
for name, (bar, beat, key) in tl.ACTIONS.items():
    if name not in ("section-tool", "untilt", "flip", "2d", "section-only", "3d", "reveal", "off"):
        continue
    n = round(tl.t(bar, beat) * tl.FPS)
    if n in shot_starts:
        continue  # a cut lands here too: the shot starts on the frame the take first shows it (the "picture" row)
    # A slow push moves edges a little most frames: count a frame as changed when it changes
    # twice as much as any of the frames before the beat (and at least 0.4 %).
    base = float(np.max(change[n - 10:n - 3]))
    found = None
    for i in range(n - 3, n + 4):
        if change[i] > max(0.004, 2 * base):
            found = i
            break
    if found is None:
        failures.append(f"film {name}: no change near frame {n}")
        continue
    row("film", f"{name}", found / tl.FPS, f"{'downbeat' if key else 'beat'} {bar}.{beat:g}", (found - n) / tl.FPS * 1000)


# Music: the attack of the hits on the key downbeats, in the film's audio.
def audio(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "48000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32)


a = audio(FILM).astype(float)


def wav_mono(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "48000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(float)


# Each hit, found in the film's audio: the hits' own stem (music.py writes drums and effects
# alone) around the beat, cross-correlated with the film's audio within ±60 ms; the best lag is
# where that hit sits in the film. Kicks, booms, the flip and 2D hits, the end card, and the
# blips on the taps.
hits = wav_mono(os.path.join(edit.B, "audio/hits.wav"))
SR = 48000
for what, bar, beat in [("first downbeat of the groove", 2, 0), ("impact: the cut opens", 5, 0), ("arrow pressed", 7, 0),
                        ("grip pressed", 9, 0), ("flip hit", 11, 0), ("2D lift", 12, 0), ("section only", 14, 0),
                        ("groove back (3D)", 15, 0), ("turned off", 16, 0), ("end card", 17, 0),
                        ("tap: section tool", 3, 2), ("tap: untilt", 11, 2)]:
    want = tl.t(bar, beat)
    i0, i1 = int((want - 0.08) * SR), int((want + 0.25) * SR)
    ref = hits[i0:i1] - hits[i0:i1].mean()
    best, lag = -1.0, 0
    for d in range(-int(0.06 * SR), int(0.06 * SR) + 1, 4):
        x = a[i0 + d:i1 + d]
        c = float(np.dot(ref, x - x.mean()) / (np.linalg.norm(ref) * np.linalg.norm(x - x.mean()) + 1e-12))
        if c > best:
            best, lag = c, d
    for d in range(lag - 4, lag + 5):  # to the sample
        x = a[i0 + d:i1 + d]
        c = float(np.dot(ref, x - x.mean()) / (np.linalg.norm(ref) * np.linalg.norm(x - x.mean()) + 1e-12))
        if c > best:
            best, lag = c, d
    row("audio", f"{what} (r {best:.2f})", want + lag / SR, f"downbeat {bar}.{beat:g}" if beat == 0 else f"beat {bar}.{beat:g}",
        lag / SR * 1000)

print(f"{'kind':8s} {'what':34s} {'time s':>8s}  {'bar.beat':8s} {'should be on':18s} {'error ms':>9s}")
for kind, what, t, bb, should, err, ok in rows:
    print(f"{kind:8s} {what:34s} {t:8.3f}  {bb:8s} {should:18s} {err:+9.1f}  {'ok' if ok else 'OFF'}")
worst = max(abs(r[5]) for r in rows)
print(f"\n{len(rows)} checks, worst {worst:.1f} ms (limit one frame, {LIMIT - 0.05:.1f} ms)")
if failures:
    print("FAILED:\n  " + "\n  ".join(failures))
    sys.exit(1)
print("all on the grid")
