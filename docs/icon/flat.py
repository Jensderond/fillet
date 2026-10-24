#!/usr/bin/env python3
"""Fillet app icon: FLAT / "prototype" concept round.

Flat fills and line work only (no gradients, specular or drop shadows).
Reuses the geometry helpers (camera, filleted box) from icon.py.

    python3 flat.py        # writes svg/flat-XX-name.svg
    ./flat-sheet.sh        # renders concepts-flat.png
"""
import math
import os

from icon import Cam, Part, f, pts, mix, svg_doc, screen_grid, macos_wrap, OUT

FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def rect_bg(c):
    return '<rect width="1024" height="1024" fill="%s"/>' % c


def line(a, b, stroke, w, extra=""):
    cap = "" if "stroke-linecap" in extra else ' stroke-linecap="round"'
    return ('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"%s %s/>'
            % (f(a[0]), f(a[1]), f(b[0]), f(b[1]), stroke, w, cap, extra))


def polyline(ps, stroke, w, extra=""):
    return ('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round" %s/>'
            % (pts(ps), stroke, w, extra))


def poly(ps, fill, extra=""):
    return '<polygon points="%s" fill="%s" %s/>' % (pts(ps), fill, extra)


def arrow(tip, frm, size, fill):
    """Filled arrowhead at `tip`, pointing away from `frm`."""
    dx, dy = tip[0] - frm[0], tip[1] - frm[1]
    l = math.hypot(dx, dy)
    ux, uy = dx / l, dy / l
    px, py = -uy, ux
    b = (tip[0] - ux * size, tip[1] - uy * size)
    return poly([tip, (b[0] + px * size * 0.42, b[1] + py * size * 0.42), (b[0] - px * size * 0.42, b[1] - py * size * 0.42)], fill)


def text(x, y, s, size, fill, anchor="middle", weight=600, rot=None):
    t = ' transform="rotate(%s %s %s)"' % (rot, f(x), f(y)) if rot is not None else ""
    return ('<text x="%s" y="%s" font-family="%s" font-size="%s" font-weight="%s" fill="%s" text-anchor="%s"%s>%s</text>'
            % (f(x), f(y), FONT, size, weight, fill, anchor, t, s))


def cross_mark(c, s, stroke, w):
    return line((c[0] - s, c[1]), (c[0] + s, c[1]), stroke, w) + line((c[0], c[1] - s), (c[0], c[1] + s), stroke, w)


def profile_path(x0, y0, x1, y1, r):
    """Rectangle with its top-right corner filleted (screen coords)."""
    return "M%s %s H%s A%s %s 0 0 1 %s %s V%s H%s Z" % (f(x0), f(y0), f(x1 - r), f(r), f(r), f(x1), f(y0 + r), f(y1), f(x0))


def dot_grid(step, r, color, op, offset=0):
    out = []
    n = int(1024 / step) + 1
    for i in range(n + 1):
        for j in range(n + 1):
            out.append('<circle cx="%s" cy="%s" r="%s"/>' % (f(offset + i * step), f(offset + j * step), r))
    return '<g fill="%s" fill-opacity="%s">%s</g>' % (color, op, "".join(out))


# --------------------------------------------------------------------------
# isometric part as line drawing / flat faces
# --------------------------------------------------------------------------
class Iso:
    def __init__(self, eye=(-1.0, -0.78, 0.82), dims=(1.15, 0.8, 0.72, 0.4), width=600, cx=512, cy=530, seg=48):
        W, D, H, r = dims
        self.W, self.D, self.H, self.r = W, D, H, r
        self.part = Part(W, D, H, r, seg)
        self.cam = Cam(eye)
        self.cam.fit(self.part.corners(), width, cx, cy)

    def P(self, p):
        return self.cam(p)

    def arc(self, x, n=48):
        return [self.P(p) for p, _ in self.part.arc(x, n)]

    def visible_edges(self):
        W, D, H, r, P = self.W, self.D, self.H, self.r, self.P
        return [
            [P((0, D, H)), P((0, D, 0)), P((0, 0, 0)), P((0, 0, H - r))] + self.arc(0) + [P((0, D, H))],  # left face loop
            [P((0, 0, 0)), P((W, 0, 0)), P((W, 0, H - r))] + self.arc(W) + [P((W, D, H)), P((0, D, H))],  # front + top silhouette
        ]

    def tangent_edges(self):
        W, H, r, P = self.W, self.H, self.r, self.P
        return [[P((0, 0, H - r)), P((W, 0, H - r))], [P((0, r, H)), P((W, r, H))]]

    def hidden_edges(self):
        W, D, H, P = self.W, self.D, self.H, self.P
        return [[P((W, D, 0)), P((W, D, H))], [P((0, D, 0)), P((W, D, 0))], [P((W, 0, 0)), P((W, D, 0))]]

    def faces(self):
        fc = self.part.faces()
        return {k: [self.P(p) for p in fc[k][0]] for k in ("left", "front", "top")}

    def fillet(self):
        return [self.P(p) for p in self.part.fillet_poly()]

    def fillet_bands(self, n):
        """The fillet split into n flat facets (STL-style), front to top."""
        out = []
        for i in range(n):
            a0, a1 = (math.pi / 2) * i / n, (math.pi / 2) * (i + 1) / n
            def pt(x, a):
                return self.P((x, self.r * (1 - math.cos(a)), self.H - self.r + self.r * math.sin(a)))
            out.append([pt(0, a0), pt(self.W, a0), pt(self.W, a1), pt(0, a1)])
        return out


def iso_lines(iso, ink, w, accent=None, aw=None, hidden=True, hidden_color=None, tangent=True, fillet_fill=None, fillet_op=1.0,
              faces=None):
    body = []
    if faces:
        fc = iso.faces()
        for k in ("left", "front", "top"):
            if faces.get(k):
                body.append(poly(fc[k], faces[k]))
    if hidden:
        for e in iso.hidden_edges():
            body.append(polyline(e, hidden_color or ink, w * 0.45, 'stroke-dasharray="%s %s" stroke-opacity="0.55"' % (f(w * 1.6), f(w * 1.4))))
    if fillet_fill:
        body.append(poly(iso.fillet(), fillet_fill, 'fill-opacity="%s"' % fillet_op))
    if tangent:
        for e in iso.tangent_edges():
            body.append(polyline(e, ink, w * 0.45, 'stroke-opacity="0.6"'))
    for e in iso.visible_edges():
        body.append(polyline(e, ink, w))
    if accent:
        body.append(polyline(iso.arc(0), accent, aw or w * 1.3))
        body.append(polyline(iso.arc(iso.W), accent, aw or w * 1.3))
    return "".join(body)


# --------------------------------------------------------------------------
# concepts
# --------------------------------------------------------------------------
def c01_blueprint_profile():
    """Blueprint drawing of the fillet profile with radius dimension."""
    bg, ink, acc = "#1f4fc4", "#ffffff", "#ff8a2a"
    b = [rect_bg(bg), screen_grid(64, 4, "#ffffff", 0.10, 0.22, 2, 3)]
    x0, y0, x1, y1, r = 256, 256, 768, 768, 288
    cx, cy = x1 - r, y0 + r
    b.append('<path d="%s" fill="#ffffff" fill-opacity="0.08" stroke="%s" stroke-width="24" stroke-linejoin="round"/>' % (profile_path(x0, y0, x1, y1, r), ink))
    # construction circle (rest of the fillet circle), dashed
    b.append('<path d="M%s %s A%s %s 0 1 0 %s %s" fill="none" stroke="%s" stroke-width="6" stroke-opacity="0.5" stroke-dasharray="18 14"/>'
             % (f(x1 - r), f(y0), f(r), f(r), f(x1), f(y0 + r), ink))
    b.append('<path d="M%s %s A%s %s 0 0 1 %s %s" fill="none" stroke="%s" stroke-width="34" stroke-linecap="round"/>' % (f(x1 - r), f(y0), f(r), f(r), f(x1), f(y0 + r), acc))
    b.append(cross_mark((cx, cy), 22, ink, 6))
    a = math.radians(45)
    tip = (cx + (r - 22) * math.cos(a), cy - (r - 22) * math.sin(a))
    b.append(line((cx, cy), tip, ink, 7))
    b.append(arrow(tip, (cx, cy), 40, ink))
    b.append(text(cx + 30, cy + 76, "R12", 64, ink, "start", 700))
    # width dimension below
    yd = y1 + 72
    b.append(line((x0, y1 + 24), (x0, yd + 24), ink, 5, 'stroke-opacity="0.7"'))
    b.append(line((x1, y1 + 24), (x1, yd + 24), ink, 5, 'stroke-opacity="0.7"'))
    b.append(line((x0 + 30, yd), (x1 - 30, yd), ink, 5, 'stroke-opacity="0.7"'))
    b.append(arrow((x0 + 4, yd), (x1, yd), 32, ink))
    b.append(arrow((x1 - 4, yd), (x0, yd), 32, ink))
    return svg_doc([], b)


def c02_graph_paper_iso():
    """Ink isometric line drawing on cream engineering paper, orange fillet."""
    bg, ink, acc = "#f5efe0", "#1d2b4a", "#ff6a1a"
    b = [rect_bg(bg), screen_grid(32, 5, "#4f8fb0", 0.16, 0.34, 2, 3, offset=12)]
    iso = Iso(width=640, cy=520)
    b.append(iso_lines(iso, ink, 16, fillet_fill=acc, hidden_color=ink))
    return svg_doc([], b)


def c03_cutting_mat():
    """Cutting-mat green, white flat profile, yellow fillet arc, mat rulers."""
    bg, acc = "#1f7356", "#ffd23f"
    b = [rect_bg(bg), screen_grid(64, 4, "#e6fff2", 0.16, 0.34, 2, 4)]
    b.append(line((0, 1024), (1024, 0), "#e6fff2", 3, 'stroke-opacity="0.22"'))
    # ruler ticks along top & left
    for i in range(0, 1025, 32):
        L = 44 if i % 128 == 0 else (28 if i % 64 == 0 else 16)
        b.append(line((i, 0), (i, L), "#e6fff2", 4, 'stroke-opacity="0.6" stroke-linecap="butt"'))
        b.append(line((0, i), (L, i), "#e6fff2", 4, 'stroke-opacity="0.6" stroke-linecap="butt"'))
    x0, y0, x1, y1, r = 272, 272, 784, 784, 300
    b.append('<path d="%s" fill="#f8f6ee"/>' % profile_path(x0, y0, x1, y1, r))
    b.append('<path d="M%s %s A%s %s 0 0 1 %s %s" fill="none" stroke="%s" stroke-width="30" stroke-linecap="round"/>' % (f(x1 - r), f(y0), f(r), f(r), f(x1), f(y0 + r), acc))
    b.append(cross_mark((x1 - r, y0 + r), 26, "#1f7356", 8))
    return svg_doc([], b)


def c04_neon_wireframe():
    """Dark slate, cyan wireframe with dashed hidden edges, magenta fillet rulings."""
    bg, ink, acc = "#121820", "#46e3ff", "#ff4fd2"
    b = [rect_bg(bg), screen_grid(64, 4, "#8fb3d9", 0.07, 0.14, 2, 3)]
    iso = Iso(width=620, cy=520)
    # fillet rulings
    for i in range(1, 8):
        a = (math.pi / 2) * i / 8
        p0 = iso.P((0, iso.r * (1 - math.cos(a)), iso.H - iso.r + iso.r * math.sin(a)))
        p1 = iso.P((iso.W, iso.r * (1 - math.cos(a)), iso.H - iso.r + iso.r * math.sin(a)))
        b.append(line(p0, p1, acc, 7, 'stroke-opacity="0.8"'))
    b.append(iso_lines(iso, ink, 15, accent=acc, aw=19, tangent=True))
    return svg_doc([], b)


def c05_green_flat_solid():
    """Black bed, flat green solid in three tones, stepped fillet."""
    bg = "#121212"
    b = [rect_bg(bg), screen_grid(64, 4, "#ffffff", 0.05, 0.10, 2, 3)]
    iso = Iso(width=620, cy=530)
    fc = iso.faces()
    b.append(poly(fc["left"], "#00ae42"))
    b.append(poly(fc["front"], "#00813a"))
    b.append(poly(fc["top"], "#38d66f"))
    tones = ["#0b9a40", "#16b54c", "#5be38a", "#36cf69"]
    for t, band in zip(tones, iso.fillet_bands(4)):
        b.append(poly(band, t, 'stroke="%s" stroke-width="1.5"' % t))
    return svg_doc([], b)


def c06_mono_symbol():
    """Mono black on white: one big fillet corner with radius dimension, drafting style."""
    bg, ink = "#f7f7f5", "#111111"
    b = [rect_bg(bg)]
    r = 330
    x1, y0 = 800, 224  # outer corner
    cx, cy = x1 - r, y0 + r
    b.append('<circle cx="%s" cy="%s" r="%s" fill="none" stroke="%s" stroke-width="6" stroke-opacity="0.28" stroke-dasharray="18 15"/>' % (f(cx), f(cy), r, ink))
    # construction lines through the centre, extended
    b.append(line((cx, cy), (cx, y0 - 50), ink, 4, 'stroke-opacity="0.3"'))
    b.append(line((cx, cy), (x1 + 50, cy), ink, 4, 'stroke-opacity="0.3"'))
    b.append('<path d="M%s %s H%s A%s %s 0 0 1 %s %s V%s" fill="none" stroke="%s" stroke-width="52" stroke-linecap="round" stroke-linejoin="round"/>'
             % (f(190), f(y0), f(x1 - r), r, r, f(x1), f(y0 + r), f(840), ink))
    b.append(cross_mark((cx, cy), 28, ink, 8))
    a = math.radians(45)
    tip = (cx + (r - 34) * math.cos(a), cy - (r - 34) * math.sin(a))
    b.append(line((cx, cy), tip, ink, 10))
    b.append(arrow(tip, (cx, cy), 56, ink))
    b.append(text(cx - 40, cy + 150, "R", 150, ink, "end", 700))
    return svg_doc([], b)


def c07_dot_paper_orange():
    """Light dot-grid paper, flat grey iso solid with ink outline, two-tone orange fillet."""
    bg, ink = "#ededeb", "#222222"
    b = [rect_bg(bg), dot_grid(48, 4, "#555", 0.35, offset=8)]
    iso = Iso(width=620, cy=525)
    b.append(iso_lines(iso, ink, 12, faces={"left": "#ffffff", "front": "#cfcfcf", "top": "#f2f2f2"}, hidden=True, tangent=False))
    bands = iso.fillet_bands(2)
    b.append(poly(bands[0], "#ff5f0f") + poly(bands[1], "#ff8a3c"))
    # outline again on top of the fillet bands
    for e in iso.visible_edges():
        b.append(polyline(e, ink, 12))
    return svg_doc([], b)


def c08_pencil_sketch():
    """Graphite sketch on paper with overshooting construction lines, red-pencil fillet."""
    bg, ink, acc = "#f3eee3", "#3a3a3d", "#e4472b"
    b = [rect_bg(bg)]
    iso = Iso(width=580, cy=530)
    W, D, H, r, P = iso.W, iso.D, iso.H, iso.r, iso.P
    # long faint construction lines along the iso axes through key corners
    for p, d in [((0, 0, 0), (1, 0, 0)), ((0, 0, 0), (0, 1, 0)), ((0, 0, 0), (0, 0, 1)), ((0, D, H), (1, 0, 0)), ((W, 0, 0), (0, 0, 1)),
                 ((0, 0, H - r), (1, 0, 0)), ((0, r, H), (1, 0, 0))]:
        a = P(tuple(pp - dd * 0.5 for pp, dd in zip(p, d)))
        c = P(tuple(pp + dd * 1.8 for pp, dd in zip(p, d)))
        b.append(line(a, c, ink, 3, 'stroke-opacity="0.18"'))
    # edges with overshoot
    def over(a, c, k=26):
        dx, dy = c[0] - a[0], c[1] - a[1]
        l = math.hypot(dx, dy)
        ux, uy = dx / l, dy / l
        return line((a[0] - ux * k, a[1] - uy * k), (c[0] + ux * k, c[1] + uy * k), ink, 12)
    straight = [((0, D, H), (0, D, 0)), ((0, D, 0), (0, 0, 0)), ((0, 0, 0), (0, 0, H - r)), ((0, r, H), (0, D, H)),
                ((0, 0, 0), (W, 0, 0)), ((W, 0, 0), (W, 0, H - r)), ((W, r, H), (W, D, H)), ((W, D, H), (0, D, H))]
    for a, c in straight:
        b.append(over(P(a), P(c)))
    for e in iso.tangent_edges():
        b.append(polyline(e, ink, 4, 'stroke-opacity="0.45"'))
    for e in iso.hidden_edges():
        b.append(polyline(e, ink, 4, 'stroke-opacity="0.35" stroke-dasharray="14 12"'))
    b.append(poly(iso.fillet(), acc, 'fill-opacity="0.28"'))
    b.append(polyline(iso.arc(0), acc, 17))
    b.append(polyline(iso.arc(W), acc, 17))
    return svg_doc([], b)


def c09_faceted_mesh():
    """Blueprint blue, flat faces + faceted (STL-like) orange fillet with mesh lines."""
    bg = "#2156d9"
    b = [rect_bg(bg), screen_grid(64, 4, "#ffffff", 0.08, 0.18, 2, 3)]
    iso = Iso(width=620, cy=525)
    fc = iso.faces()
    b.append(poly(fc["left"], "#ffffff"))
    b.append(poly(fc["front"], "#a9c0f2"))
    b.append(poly(fc["top"], "#d7e3fb"))
    tones = ["#e8590c", "#f76b15", "#ff8433", "#ff9c55", "#ff8a3d"]
    bands = iso.fillet_bands(5)
    for t, band in zip(tones, bands):
        b.append(poly(band, t, 'stroke="%s" stroke-width="1.5"' % t))
    mesh = "#1a3f9c"
    for band in bands:
        b.append(line(band[0], band[2], "#9a3a05", 2.5, 'stroke-opacity="0.45"'))
        b.append(line(band[2], band[3], "#9a3a05", 2.5, 'stroke-opacity="0.45"'))
    for k, c in (("left", 0.18), ("front", 0.18), ("top", 0.18)):
        ps = fc[k]
        b.append(polyline(ps + [ps[0]], mesh, 3, 'stroke-opacity="%s"' % c))
    return svg_doc([], b)


def c10_first_layer():
    """Top view of the part as a first-layer toolpath on a dark print bed."""
    bg, acc = "#1c1e21", "#ff7a1a"
    b = [rect_bg(bg), screen_grid(64, 4, "#ffffff", 0.05, 0.11, 2, 3)]
    x0, y0, x1, y1, r = 248, 248, 776, 776, 300
    lw, gap = 22, 30
    defs = []
    for i in range(3):
        d = i * gap
        b.append('<path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round"/>'
                 % (profile_path(x0 + d, y0 + d, x1 - d, y1 - d, r - d), acc if i == 0 else mix(acc, bg, 0.12 * i), lw))
    d = 3 * gap - 6
    defs.append('<clipPath id="inf"><path d="%s"/></clipPath>' % profile_path(x0 + d, y0 + d, x1 - d, y1 - d, r - d))
    inf = []
    for k in range(-1024, 1024, 34):
        inf.append(line((k, 1024 + 0), (k + 1024, 0), mix(acc, bg, 0.3), 18, 'stroke-linecap="butt"'))
    b.append('<g clip-path="url(#inf)">%s</g>' % "".join(inf))
    # nozzle marker on the fillet arc
    a = math.radians(45)
    cx, cy = x1 - r, y0 + r
    n = (cx + r * math.cos(a), cy - r * math.sin(a))
    b.append('<circle cx="%s" cy="%s" r="26" fill="#ffffff"/>' % (f(n[0]), f(n[1])))
    b.append('<circle cx="%s" cy="%s" r="10" fill="%s"/>' % (f(n[0]), f(n[1]), acc))
    return svg_doc(defs, b)


CONCEPTS = [
    ("01", "blueprint-profile", "Blueprint profile", c01_blueprint_profile),
    ("02", "graph-paper-iso", "Graph paper iso", c02_graph_paper_iso),
    ("03", "cutting-mat", "Cutting mat", c03_cutting_mat),
    ("04", "neon-wireframe", "Neon wireframe", c04_neon_wireframe),
    ("05", "green-solid", "Green flat solid", c05_green_flat_solid),
    ("06", "mono-symbol", "Mono fillet symbol", c06_mono_symbol),
    ("07", "dot-paper", "Dot paper + orange", c07_dot_paper_orange),
    ("08", "pencil-sketch", "Pencil sketch", c08_pencil_sketch),
    ("09", "faceted-mesh", "Faceted mesh", c09_faceted_mesh),
    ("10", "first-layer", "First layer", c10_first_layer),
]

# --------------------------------------------------------------------------
# FINAL (chosen: 02 graph paper iso) — full, small and Icon Composer layers
# --------------------------------------------------------------------------
PAPER = dict(light=dict(paper="#f5efe0", grid="#4f8fb0", grid_op=0.15, grid_major_op=0.32, ink="#1d2b4a"),
             dark=dict(paper="#14203a", grid="#8fb6d8", grid_op=0.13, grid_major_op=0.28, ink="#eef1f7"))
ORANGE = "#ff6a1a"


def final02(small=False, layer="all", theme="light", tiny=False):
    """layer: all | background | outline | fillet.   small: 32-64 px artwork, tiny: 16 px."""
    small = small or tiny
    t = PAPER[theme]
    ink = t["ink"]
    b, defs = [], []
    if layer in ("all", "background"):
        b.append(rect_bg(t["paper"]))
        if small:
            pass  # plain paper: a grid turns to mush at 16-64 px
        else:
            b.append(screen_grid(32, 4, t["grid"], t["grid_op"], t["grid_major_op"], 2, 3))
    if layer == "background":
        return svg_doc(defs, b)
    iso = Iso(width=700 if tiny else (640 if small else 584), cy=516 if small else 514)
    w = 72 if tiny else (44 if small else 17)
    if layer in ("all", "fillet"):
        b.append(poly(iso.fillet(), ORANGE))
    if layer in ("all", "outline"):
        if not small:
            # hidden edges, masked out where they pass behind the fillet
            defs.append('<mask id="hid"><rect width="1024" height="1024" fill="#fff"/>%s</mask>'
                        % poly(iso.fillet(), "#000", 'stroke="#000" stroke-width="%s" stroke-linejoin="round"' % f(w * 0.8)))
            hid = "".join(polyline(e, ink, w * 0.42, 'stroke-dasharray="%s %s" stroke-opacity="0.5"' % (f(w * 1.5), f(w * 1.3)))
                          for e in iso.hidden_edges())
            b.append('<g mask="url(#hid)">%s</g>' % hid)
            for e in iso.tangent_edges():
                b.append(polyline(e, ink, w * 0.42))
        for e in iso.visible_edges():
            b.append(polyline(e, ink, w))
    return svg_doc(defs, b)


def write_final():
    out = {}
    out["final-ios"] = final02()
    out["final-small"] = final02(small=True)
    out["final-dark"] = final02(theme="dark")
    out["final-macos"] = macos_wrap(final02())
    out["final-macos-small"] = macos_wrap(final02(small=True))
    out["final-macos-tiny"] = macos_wrap(final02(tiny=True))
    for lay in ("background", "outline", "fillet"):
        out["final-layer-%s" % lay] = final02(layer=lay)
        out["final-layer-%s-dark" % lay] = final02(layer=lay, theme="dark")
    for k, v in out.items():
        with open(os.path.join(OUT, k + ".svg"), "w") as fh:
            fh.write(v)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for num, slug, _, fn in CONCEPTS:
        with open(os.path.join(OUT, "flat-%s-%s.svg" % (num, slug)), "w") as fh:
            fh.write(fn())
    print("wrote %d flat concepts to %s" % (len(CONCEPTS), OUT))
    write_final()

