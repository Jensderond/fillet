"""The edit: which parts of the demo recording go where, and everything timed to them.

Times in the recording come from the beat log DemoDirector writes (seconds since
the demo started) plus OFFSET, the recording time of the demo's first beat
(measured on the take: the frame where the first rectangle lands, minus its beat).
Everything downstream (titles, voice-over, music cues, effects) is placed on the
output timeline through `out()`, so a new take only needs a new OFFSET.
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TAKE = os.path.join(ROOT, "build/video/raw/take3.mp4")
BEATS = os.path.join(ROOT, "build/video/raw/take3.beats.txt")
OFFSET = 2.12
FPS = 30

OPENER = 3.0          # full-frame splash drawing
OPENER_DRAW = 2.3     # the splash reaches its resting frame (1.34 s of app time) after this long
OPENER_SLOW = OPENER_DRAW / 1.34
PROBLEM = 3.0         # problem statement, then the iPad comes in
DEVICE_IN = OPENER + PROBLEM   # 6.1
END_CARD_LEN = 4.4
XFADE = 0.3


def load_beats(path=BEATS):
    beats = []
    for line in open(path):
        parts = dict(p.split("=") for p in line.split()[2:])
        beats.append((line.split()[1], float(parts["t"])))
    return beats


BEATS_LIST = load_beats()


def beat(name, nth=0):
    hits = [t for n, t in BEATS_LIST if n == name]
    return hits[nth] + OFFSET


def events(name):
    return [t + OFFSET for n, t in BEATS_LIST if n == name]


# Segments of the recording: (label, source start, source end, speed, join with the previous)
# join "cut" crossfades XFADE seconds; "cont" continues the same footage at a new speed.
SEGMENTS = [
    ("launch",   beat("launch") + 0.3,             beat("circle-done") + 0.3,  1.0,  None),
    ("extrude",  beat("extrude") - 0.25,          beat("extruded") + 0.35,    1.2,  "cut"),
    ("fillet",   beat("fillet") - 0.2,             beat("filleted") + 0.3,     1.2,  "cut"),
    ("pocket",   beat("face-sketch") - 0.1,        beat("pocketed") + 0.7,     1.8,  "cut"),
    ("hero-in",  beat("hero") - 0.15,              beat("hero-width") - 0.05,  1.35, "cut"),
    ("hero",     beat("hero-width") - 0.05,        beat("hero-done") + 0.35,   1.0,  "cont"),
    ("rollback", beat("hero-done") + 0.35,         beat("rollback-done") + 0.3, 1.35, "cont"),
    ("print",    beat("rollback-done") + 0.3,      beat("export") - 0.2,       1.15, "cont"),
    ("export",   beat("export") - 0.2,             None,                       1.0,  "cont"),
]
EXPORT_HOLD = 1.6   # the save sheet is still; the recording stops writing frames once it settles


def take_duration():
    import subprocess
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", TAKE],
                                capture_output=True, text=True, check=True).stdout)


def layout_segments():
    """Output start/end of every segment (device timeline starts at DEVICE_IN)."""
    out, t = [], DEVICE_IN
    end_of_take = take_duration() - 0.05
    for label, a, b, speed, join in SEGMENTS:
        b = end_of_take if b is None else b
        if join == "cut":
            t -= XFADE
        length = (b - a) / speed
        out.append(dict(label=label, src_start=round(a, 3), src_end=round(b, 3), speed=speed, join=join,
                        out_start=round(t, 3), out_end=round(t + length, 3)))
        t += length
    out[-1]["hold"] = EXPORT_HOLD
    out[-1]["out_end"] = round(out[-1]["out_end"] + EXPORT_HOLD, 3)
    return out


SEGS = layout_segments()
DEVICE_OUT = SEGS[-1]["out_end"]
END_CARD = DEVICE_OUT - 0.15
TOTAL = round(END_CARD + END_CARD_LEN, 3)


def out(src):
    """Output time of a recording time (the first segment that shows it; None if cut)."""
    for s in SEGS:
        if s["src_start"] - 1e-6 <= src <= s["src_end"] + 1e-6:
            return s["out_start"] + (src - s["src_start"]) / s["speed"]
    return None


def device_time_map():
    return SEGS


# On-screen titles: (key, in, out, eyebrow, headline, sub lines)
def titles():
    b = beat
    return [
        dict(key="problem", start=OPENER + 0.05, end=DEVICE_IN - 0.05, style="statement", eyebrow="",
             headline="CAD for 3D printing shouldn't need an account, or a connection.", sub=[]),
        dict(key="intro", start=DEVICE_IN + 0.35, end=out(b("pencil")) - 0.9, style="brand", eyebrow="Fillet",
             headline="Parametric CAD for iPad and Mac.", sub=["Works fully offline. No account."]),
        dict(key="sketch", start=out(b("pencil")) - 0.7, end=SEGS[1]["out_start"] + 0.1, eyebrow="01  Sketch",
             headline="Sketch with Apple Pencil.", sub=["Live dimensions, grid snapping."]),
        dict(key="extrude", start=SEGS[1]["out_start"] + 0.35, end=SEGS[2]["out_start"] + 0.1, eyebrow="02  Extrude",
             headline="Pull a profile into a solid.", sub=["Drag the arrow, or type the distance."]),
        dict(key="fillet", start=SEGS[2]["out_start"] + 0.35, end=SEGS[3]["out_start"] + 0.1, eyebrow="03  Fillet",
             headline="Round the edges.", sub=["Four edges, 5 mm."]),
        dict(key="pocket", start=SEGS[3]["out_start"] + 0.35, end=SEGS[4]["out_start"] + 0.1, eyebrow="04  Sketch on a face",
             headline="Cut a pocket.", sub=["A slot on the top face, 6 mm deep."]),
        dict(key="hero", start=SEGS[4]["out_start"] + 0.35, end=out(b("rollback")) - 0.1, eyebrow="05  Timeline",
             headline="Change one step.\nThe rest follows.", sub=["Sketch 1, width"], counter=dict(
                 start=out(b("hero-width") + 0.62), end=out(b("hero-width") + 0.62 + 1.45), a=60, b=80, unit="mm")),
        dict(key="rollback", start=out(b("rollback")) + 0.05, end=out(b("print-check")) - 0.05, eyebrow="05  Timeline",
             headline="Roll back to any step.", sub=["Drag the caliper along the ruler."]),
        dict(key="print", start=out(b("print-check")) + 0.3, end=out(b("export")) - 0.1, eyebrow="06  Print check",
             headline="Ready for the printer.", sub=[], callout="print-card"),
        dict(key="export", start=out(b("export")) + 0.25, end=END_CARD - 0.05, eyebrow="07  Export",
             headline="3MF for Bambu Studio\nand PrusaSlicer.", sub=["STL and STEP too.", "One design is one .fillet file", "in Files or iCloud Drive."]),
    ]


# Magnified crops of the iPad screen, in screen points (1024 × 1366): the print check card.
CALLOUTS = {
    "print-card": dict(rect=[716, 168, 296, 372], scale=1.55),
}


def voice_starts(vo):
    """Where each voice-over line starts, anchored to what the picture shows."""
    b = beat
    starts = {
        "problem": OPENER + 0.2,
        "intro": DEVICE_IN + 0.55,
        "sketch": out(b("pencil")) - 0.55,
        "extrude": out(b("touch", 5)) - 0.95,
        "fillet": out(b("fillet")) + 0.05,
        "pocket": out(b("face-sketch")) + 0.25,
        "hero": out(b("hero")) - 0.05,
        "follows": None,  # right after "hero"
        "rollback": out(b("rollback")) + 0.1,
        "print": out(b("print-check")) - 0.05,
        "export": out(b("export")) + 0.35,
        "end": END_CARD + 0.75,
    }
    placed, prev_end = {}, 0
    for line in vo:
        s = starts[line["id"]]
        if s is None:
            s = prev_end + 0.3
        s = max(s, prev_end + 0.25)
        placed[line["id"]] = round(s, 3)
        prev_end = s + line["duration"]
    return placed


def sfx_events():
    """(time, kind) for every kept tap, Pencil touch, snap, caliper detent and camera swing."""
    ev = []
    for kind in ["touch", "pencil", "snap", "detent", "whoosh"]:
        for t in events(kind):
            o = out(t)
            if o is not None:
                ev.append((round(o, 3), kind))
    ev.append((round(END_CARD + 0.25, 3), "chime"))
    return sorted(ev)


def music_cues():
    b = beat
    return dict(
        total=TOTAL,
        device_in=DEVICE_IN,
        build=SEGS[4]["out_start"],                 # timeline beat: start building
        hero=out(b("hero-width") + 0.62),          # the width starts growing
        settle=out(b("print-check")),              # back to calm for print and export
        end_card=END_CARD,
    )


def plan():
    return dict(fps=FPS, total=TOTAL, opener=OPENER, opener_draw=OPENER_DRAW, device_in=DEVICE_IN, device_out=DEVICE_OUT, end_card=END_CARD,
                segments=SEGS, titles=titles(), callouts=CALLOUTS)


if __name__ == "__main__":
    print(json.dumps(plan(), indent=1))
    for s in SEGS:
        print(f"{s['label']:9s} src {s['src_start']:6.2f}-{s['src_end']:6.2f} x{s['speed']}  out {s['out_start']:6.2f}-{s['out_end']:6.2f}")
    print("total", TOTAL)
