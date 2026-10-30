"""The Section view film's edit: which frames of the take go where, the framing of each shot,
and the titles, all on the beat grid (timeline.py).

The demo acts on the same bars as the film (bar b of its grid is bar b of the film), so most of
the film is the take played straight, offset by where its grid starts (`grid_take`, from
sync.py). Shots cut on downbeats to a new framing of the device. The cut that opens the part is
the one place the picture lags its beat (the scene is rebuilt with the section: about 65 ms in
the simulator), so the shot that starts on bar 5 starts on the frame where the cut opens, and
lasts a bar (nothing happens on bar 6, where the next shot goes back to the take straight).
Turning it off lags a little too (a frame at 60 fps) and starts the last shot the same way.

Times are in frames of the take resampled at 60 fps (the latest frame at or before each tick),
and every output frame n of a shot shows take frame start + 2n, so nothing drifts.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import timeline as tl

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
B = os.path.join(ROOT, "build/video/section")
TAKE = os.environ.get("SECTION_TAKE", os.path.join(B, "raw/take.mp4"))
SRC_FPS = 60

T = tl.t
FPS = tl.FPS


def sync():
    path = TAKE[:-4] + ".sync.json"
    if not os.path.exists(path):
        raise SystemExit(f"no {path}: run docs/video/section/sync.py {TAKE} first")
    return json.load(open(path))


S = sync()
GRID = S["grid_take"]


def seen(name, key="main"):
    """When the take shows an action: where the screen changes most ("main"), or first ("seen")."""
    for e in S["events"]:
        if e["name"] == name and e.get(key) is not None:
            return e[key]
    raise SystemExit(f"{name} isn't seen in the take")


def logged(name, nth=0):
    hits = [e["take"] for e in S["events"] if e["name"] == name]
    return hits[nth]


# Shots: (label, first bar, last bar (exclusive), anchor) — anchor None: the take straight
# (grid-aligned), or an action whose first visible frame starts the shot.
SHOTS = [
    ("solid",  2, 5, None),
    ("reveal", 5, 6, "reveal"),
    ("bodies", 6, 7, None),
    ("slide",  7, 9, None),
    ("tilt",   9, 11, None),
    ("flip",   11, 12, None),
    ("2d-in",  12, 13, None),
    ("2d",     13, 14, None),
    ("only",   14, 15, None),
    ("3d",     15, 16, None),
    ("off",    16, 17, "off"),
]

# The iPad's portrait screen, in points (1024 × 1366), as the take shows it: the viewport is
# x 0…706 (the panel is to its right), the part's middle in 3D and in 2D.
PART = (340, 735)
PART_2D = (352, 712)
VIEWPORT_RIGHT = 706
K = 916 * 1024 / 1366 / 1024   # output pixels per screen point at scale 1 (the device is 960 px tall, 22 px bezel)


def close(scale, focus=PART):
    """The part, big: the frame's right edge on the viewport's right edge (the panel just out of
    shot), the part at mid-height."""
    return dict(scale=scale, fx=focus[0], fy=focus[1], ax=1920 + 2 - scale * (VIEWPORT_RIGHT - focus[0]) * K, ay=560)


def medium(scale=1.45):
    """The whole width of the screen, for taps in the panel."""
    return dict(scale=scale, fx=512, fy=715, ax=1385, ay=540)


WIDE = None

# Framing per shot: a cut to the first on the shot's downbeat, then a slow push to the second over the shot.
FRAMES = {
    "solid":  (WIDE, WIDE),
    "reveal": (close(1.75), close(1.82)),
    "bodies": (close(2.15, (340, 712)), close(2.25, (340, 712))),
    "slide":  (close(1.9, (330, 760)), close(1.98, (330, 760))),
    "tilt":   (close(2.05), close(2.15)),
    "flip":   (medium(1.45), medium(1.48)),
    "2d-in":  (medium(1.45), medium(1.48)),
    "2d":     (close(1.9, PART_2D), close(2.0, PART_2D)),
    "only":   (medium(1.45), medium(1.48)),
    "3d":     (close(2.2), close(2.3)),
    "off":    (WIDE, WIDE),
}


def frame(t):
    return round(t * FPS)


def shots():
    out = []
    for label, a, b, anchor in SHOTS:
        out_start, out_end = frame(T(a)), frame(T(b))
        # Take time shown at the shot's first frame.
        src = seen(anchor) if anchor else GRID + T(a)
        s0 = round(src * SRC_FPS)
        out.append(dict(label=label, out_start=out_start / FPS, out_end=out_end / FPS, out_frames=out_end - out_start,
                        src_frame=s0, src_start=round(s0 / SRC_FPS, 4), src_end=round((s0 + 2 * (out_end - out_start)) / SRC_FPS, 4),
                        anchor=anchor))
    return out


SHOT_LIST = shots()
DEVICE_IN = T(tl.OPENER_BARS)
END_CARD = T(tl.END_CARD_BAR)


def out_time(src):
    """Film time at which take time `src` shows (the first frame on or after it), or None if cut."""
    f = round(src * SRC_FPS)
    for s in SHOT_LIST:
        if s["src_frame"] <= f < s["src_frame"] + 2 * s["out_frames"]:
            k = -(-(f - s["src_frame"]) // 2)  # ceil: the first output frame showing it
            return s["out_start"] + k / FPS
    return None


def zoom_keys():
    keys = []
    for s in SHOT_LIST:
        a, b = FRAMES[s["label"]]
        t0 = s["out_start"]
        if a is None:
            keys.append(dict(t=t0, dur=0, scale=1.0, fx=512, fy=683, ax=1352, ay=540))
            continue
        keys.append(dict(t=t0, dur=0, **a))
        keys.append(dict(t=t0, dur=s["out_end"] - t0, curve="sine", **b))
    # The identity at 1.0 maps the screen's centre onto the device's centre: no move.
    return keys


def titles():
    out = [dict(key="open", start=T(0, 2), end=T(2) - 0.02, style="hero", eyebrow="NEW IN FILLET", headline="Section view",
                sub=["See inside what you make."], line_starts=[T(0, 1), T(1, 0), T(1, 2)])]
    for key, bar_in, bar_out, eyebrow, headline, sub in tl.TITLES:
        start = T(int(bar_in), (bar_in % 1) * 4)
        starts = [start, start] + [start + tl.BEAT / 2 * (i + 1) for i in range(len(sub))]
        out.append(dict(key=key, start=start, end=T(bar_out) - 0.02, eyebrow=eyebrow, headline=headline, sub=sub, line_starts=starts))
    return out


def stat():
    s = tl.STAT
    return dict(title=s["title"], start=T(s["bar"]), text=s["text"], unit=s["unit"], note=s["note"])


def plan():
    return dict(fps=FPS, total=tl.TOTAL, opener=0, opener_draw=1, device_in=DEVICE_IN, device_out=END_CARD, end_card=END_CARD,
                end_card_delay=0, segments=[dict(label=s["label"], out_start=s["out_start"], out_end=s["out_end"]) for s in SHOT_LIST],
                titles=titles(), callouts={}, zoom=zoom_keys(), stat=stat(),
                end_lines=["Fillet", "Section view: see inside what you make.", "iPad and Mac"],
                poster_lines=["Section view", "See inside\nwhat you make.", "A colour per body. 2D sections. 60 fps.", "Fillet · iPad and Mac"],
                poster_zoom=dict(t=0, dur=0, **close(1.7)))


def cuts():
    """Every cut in the film: (time, what)."""
    c = [(DEVICE_IN, "opener → device")]
    for s in SHOT_LIST[1:]:
        c.append((s["out_start"], f"→ {s['label']} shot"))
    c.append((END_CARD, "→ end card"))
    return c


if __name__ == "__main__":
    for s in SHOT_LIST:
        print(f"{s['label']:7s} out {s['out_start']:6.3f}-{s['out_end']:6.3f}  take {s['src_start']:7.3f}-{s['src_end']:7.3f}  {s['anchor'] or ''}")
    print("total", tl.TOTAL)
