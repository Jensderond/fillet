"""The Section view film's beat grid: one place for the tempo, the bar every key moment lands
on, and the titles, shared by the edit (edit.py), the music (music.py) and the check
(beatcheck.py). The demo (`FILLET_DEMO=section` in DemoDirector) acts on the same bars.

112.5 bpm: a beat is 0.5333 s, exactly 16 frames at 30 fps, so every beat and half-beat
falls on a frame. Bar b starts at b × 2.1333 s of the film.
"""
BPM = 112.5
FPS = 30
BEAT = 60 / BPM              # 0.53333 s
BAR = 4 * BEAT               # 2.13333 s
BARS = 19
TOTAL = BARS * BAR           # 40.533 s
FRAMES_PER_BEAT = round(BEAT * FPS)  # 16


def t(bar, beat=0.0):
    """Film time of beat `beat` (0…3, halves allowed) of bar `bar`."""
    return (bar * 4 + beat) * BEAT


# The demo's actions (beat names in its log) and where they land, as (bar, beat).
# `key` ones are the story's moments and land on downbeats.
ACTIONS = {
    "orbit":         (2, 0, False),
    "section-tool":  (3, 2, False),
    "reveal":        (5, 0, True),
    "arrow-press":   (7, 0, False),
    "arrow-move":    (7, 1, False),
    "arrow-stop":    (8, 0, False),
    "arrow-release": (8, 3.5, False),
    "tilt-press":    (9, 0, False),
    "tilt-move":     (9, 1, False),
    "tilt-release":  (10, 0, False),
    "flip":          (11, 0, True),
    "untilt":        (11, 2, False),
    "2d":            (12, 0, True),
    "section-only":  (14, 0, True),
    "3d":            (15, 0, False),
    "off":           (16, 0, False),
}

OPENER_BARS = 2              # the title on paper; the device comes in on bar 2
END_CARD_BAR = 17

# Titles: (key, bar in, bar out, eyebrow, headline, sub lines). Lines land 75 ms apart from the
# downbeat they start on and leave just before the next title's downbeat.
TITLES = [
    ("solid", 2.5, 5, "Section view", "It looks solid.", ["A rotor and a pin, printed in place", "inside a closed housing."]),
    ("inside", 5, 6, "Section view", "See inside.", ["Pick a plane. The cut opens."]),
    ("bodies", 6, 7, "Section view", "Every body,\nits own colour.", ["Housing, rotor, pin: 0.2 mm apart."]),
    ("slide", 7, 9, "Slide", "Drag the arrow.", ["The cut follows, live to 0.1 mm."]),
    ("tilt", 9, 11, "Tilt", "Turn a grip.", ["Any angle, about the cut's own centre."]),
    ("flip", 11, 12, "Flip", "Either side.", ["Flip, and untilt in one tap."]),
    ("2d", 12, 14, "2D section", "Straight at the cut.", ["Flat, hatched, outlined,", "true to size."]),
    ("only", 14, 16, "Section only", "Just the cut faces.", ["In 2D or 3D."]),
    ("view", 16, 17, "View, not a step", "Nothing to undo.", ["The cut never touches the design."]),
]

# "60 fps" lands under the slide title on bar 8, as the arrow turns back.
STAT = dict(title="slide", bar=8, text="60", unit="fps", note="while you drag")
