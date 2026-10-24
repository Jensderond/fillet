#!/usr/bin/env python3
"""Fillet app icon generator.

Generates SVG sources for the Fillet app icon (and the explored concepts)
from a tiny 3D model: a box whose top-front edge is rounded with a fillet,
projected orthographically. Render the SVGs with rsvg-convert
(`brew install librsvg`); see build.sh.

    python3 icon.py            # writes svg/*.svg
"""
import math
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
S = 1024  # canvas


# --------------------------------------------------------------------------
# small vector + colour helpers
# --------------------------------------------------------------------------
def norm(v):
    l = math.sqrt(sum(c * c for c in v))
    return tuple(c / l for c in v)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rgb2hex(c):
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(x * 255))) for x in c)


def mix(a, b, t):
    a, b = hex2rgb(a), hex2rgb(b)
    return rgb2hex(tuple(x + (y - x) * t for x, y in zip(a, b)))


def f(x):
    return ("%.2f" % x).rstrip("0").rstrip(".")


def pts(ps):
    return " ".join("%s,%s" % (f(x), f(y)) for x, y in ps)


# --------------------------------------------------------------------------
# camera: orthographic, looking from `eye` direction towards origin
# world: x right, y back (depth), z up
# --------------------------------------------------------------------------
class Cam:
    def __init__(self, eye, scale=1.0, cx=512, cy=512):
        self.v = norm(eye)  # towards viewer
        fwd = tuple(-c for c in self.v)
        self.right = norm(cross(fwd, (0, 0, 1)))
        self.up = cross(self.right, fwd)
        self.scale, self.cx, self.cy, self.ox, self.oy = scale, cx, cy, 0.0, 0.0

    def raw(self, p):
        return (dot(p, self.right), -dot(p, self.up))

    def __call__(self, p):
        x, y = self.raw(p)
        return (self.cx + (x - self.ox) * self.scale, self.cy + (y - self.oy) * self.scale)

    def fit(self, points, width, cx, cy):
        """Scale/centre so the projected points are `width` wide centred at cx,cy."""
        r = [self.raw(p) for p in points]
        xs, ys = [p[0] for p in r], [p[1] for p in r]
        self.scale = width / (max(xs) - min(xs))
        self.ox, self.oy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
        self.cx, self.cy = cx, cy


# --------------------------------------------------------------------------
# the part: box W x D x H with the top-front edge (y=0, z=H, along x) filleted
# --------------------------------------------------------------------------
class Part:
    def __init__(self, W, D, H, r, seg=48):
        self.W, self.D, self.H, self.r, self.seg = W, D, H, r, seg

    def arc(self, x, n=None):
        """Fillet profile at x, from front face (phi=0) to top face (phi=90)."""
        n = n or self.seg
        out = []
        for i in range(n + 1):
            ph = (math.pi / 2) * i / n
            out.append(((x, self.r * (1 - math.cos(ph)), self.H - self.r + self.r * math.sin(ph)), ph))
        return out

    def corners(self):
        W, D, H = self.W, self.D, self.H
        return [(x, y, z) for x in (0, W) for y in (0, D) for z in (0, H)]

    def faces(self):
        W, D, H, r = self.W, self.D, self.H, self.r
        left = [(0, D, 0), (0, 0, 0), (0, 0, H - r)] + [p for p, _ in self.arc(0)] + [(0, D, H)]
        return {
            "top": ([(0, r, H), (W, r, H), (W, D, H), (0, D, H)], (0, 0, 1)),
            "front": ([(0, 0, 0), (W, 0, 0), (W, 0, H - r), (0, 0, H - r)], (0, -1, 0)),
            "left": (left, (-1, 0, 0)),
            "right": ([(W, 0, 0), (W, D, 0), (W, D, H), (W, r, H)] + [p for p, _ in reversed(self.arc(W))] + [(W, 0, H - r)], (1, 0, 0)),
        }

    def fillet_poly(self):
        a = [p for p, _ in self.arc(0)]
        b = [p for p, _ in self.arc(self.W)]
        return a + list(reversed(b))


def lambert(base, n, light, amb=0.35, k=0.75, tint="#ffffff", spec=0.0, view=None, shin=40):
    d = max(0.0, dot(norm(n), norm(light)))
    c = hex2rgb(base)
    lvl = amb + k * d
    col = tuple(min(1.0, x * lvl) for x in c)
    if spec and view:
        h = norm(tuple(a + b for a, b in zip(norm(light), norm(view))))
        s = spec * max(0.0, dot(norm(n), h)) ** shin
        t = hex2rgb(tint)
        col = tuple(x + (y - x) * min(1, s) for x, y in zip(col, t))
    return rgb2hex(col)


def fillet_gradient(cam, part, gid, color_fn):
    """Exact linearGradient across the projected fillet (rulings are parallel)."""
    p0 = cam((0, 0, 0))
    p1 = cam((1, 0, 0))
    ax = norm((p1[0] - p0[0], p1[1] - p0[1], 0))
    perp = (-ax[1], ax[0])
    arc = part.arc(0, 64)
    start = cam(arc[0][0])
    ts = []
    for p, ph in arc:
        q = cam(p)
        ts.append(((q[0] - start[0]) * perp[0] + (q[1] - start[1]) * perp[1], ph))
    tmax = ts[-1][0]
    if tmax < 0:
        perp = (-perp[0], -perp[1])
        ts = [(-t, ph) for t, ph in ts]
        tmax = -tmax
    end = (start[0] + perp[0] * tmax, start[1] + perp[1] * tmax)
    stops = []
    for t, ph in ts:
        n = (0, -math.cos(ph), math.sin(ph))
        stops.append('<stop offset="%s" stop-color="%s"/>' % (f(t / tmax), color_fn(n, ph)))
    return ('<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="%s" y1="%s" x2="%s" y2="%s">%s</linearGradient>'
            % (gid, f(start[0]), f(start[1]), f(end[0]), f(end[1]), "".join(stops)))


# --------------------------------------------------------------------------
# shared pieces
# --------------------------------------------------------------------------
def svg_doc(defs, body, size=S):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 1024 1024">'
            '<defs>%s</defs>%s</svg>' % (size, size, "".join(defs), "".join(body)))


def screen_grid(step, major, color, opacity, major_opacity, width=2, major_width=3, offset=0):
    out = []
    n = int(S / step) + 2
    for i in range(-1, n):
        v = offset + i * step
        is_major = (i % major == 0)
        w = major_width if is_major else width
        o = major_opacity if is_major else opacity
        out.append('<line x1="%s" y1="0" x2="%s" y2="1024" stroke="%s" stroke-opacity="%s" stroke-width="%s"/>' % (f(v), f(v), color, o, w))
        out.append('<line x1="0" y1="%s" x2="1024" y2="%s" stroke="%s" stroke-opacity="%s" stroke-width="%s"/>' % (f(v), f(v), color, o, w))
    return "".join(out)


def ground_grid(cam, x0, x1, y0, y1, step, color, width, opacity, major=None, major_opacity=None, major_width=None):
    out = []
    i = 0
    x = x0
    while x <= x1 + 1e-6:
        mj = major and (round((x - x0) / step) % major == 0)
        a, b = cam((x, y0, 0)), cam((x, y1, 0))
        out.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s" stroke-opacity="%s"/>'
                   % (f(a[0]), f(a[1]), f(b[0]), f(b[1]), color, major_width if mj else width, major_opacity if mj else opacity))
        x += step
    y = y0
    while y <= y1 + 1e-6:
        mj = major and (round((y - y0) / step) % major == 0)
        a, b = cam((x0, y, 0)), cam((x1, y, 0))
        out.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s" stroke-opacity="%s"/>'
                   % (f(a[0]), f(a[1]), f(b[0]), f(b[1]), color, major_width if mj else width, major_opacity if mj else opacity))
        y += step
    return "".join(out)


def poly(ps, fill, extra=""):
    return '<polygon points="%s" fill="%s" %s/>' % (pts(ps), fill, extra)


def layer_lines(cam, part, pitch, color, opacity, width):
    """Constant-z contours on the visible side faces + fillet (3D print layers)."""
    out = []
    W, D, H, r = part.W, part.D, part.H, part.r
    z = pitch
    while z < H - 1e-6:
        if z <= H - r:
            segs = [((0, D, z), (0, 0, z)), ((0, 0, z), (W, 0, z))]
        else:
            ph = math.asin((z - (H - r)) / r)
            y = r * (1 - math.cos(ph))
            segs = [((0, D, z), (0, y, z)), ((0, y, z), (W, y, z))]
        for a, b in segs:
            pa, pb = cam(a), cam(b)
            out.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-opacity="%s" stroke-width="%s"/>'
                       % (f(pa[0]), f(pa[1]), f(pb[0]), f(pb[1]), color, opacity, width))
        z += pitch
    return "".join(out)


def solid(cam, part, pal, light, gid, view_spec=0.0, edge_hl=None, fillet_fn=None):
    """Return (defs, body) for the shaded part."""
    defs, body = [], []
    fc = part.faces()
    for name in ("left", "front", "top", "right"):
        poly3, n = fc[name]
        if dot(n, cam.v) <= 0:
            continue
        col = pal.get(name) or lambert(pal["base"], n, light)
        if isinstance(col, tuple):  # (gradient defs, fill url)
            defs.append(col[0])
            col = col[1]
        body.append(poly([cam(p) for p in poly3], col))
    fn = fillet_fn or (lambda n, ph: lambert(pal["fillet"], n, light, amb=0.45, k=0.6, spec=0.9, view=cam.v, shin=18))
    defs.append(fillet_gradient(cam, part, gid, fn))
    body.append(poly([cam(p) for p in part.fillet_poly()], "url(#%s)" % gid))
    return defs, body


def fit_part(cam, part, width, cx, cy):
    cam.fit(part.corners(), width, cx, cy)


def soft_shadow(cam, part, fid, opacity=0.45, blur=28, grow=0.0, dx=0, dy=24, color="#000"):
    W, D = part.W, part.D
    g = grow
    base = [cam((-g, -g, 0)), cam((W + g, -g, 0)), cam((W + g, D + g, 0)), cam((-g, D + g, 0))]
    d = ('<filter id="%s" x="-50%%" y="-50%%" width="200%%" height="200%%"><feGaussianBlur stdDeviation="%s"/></filter>' % (fid, blur))
    b = '<polygon points="%s" fill="%s" fill-opacity="%s" filter="url(#%s)" transform="translate(%s %s)"/>' % (pts(base), color, opacity, fid, dx, dy)
    return d, b


# --------------------------------------------------------------------------
# concepts
# --------------------------------------------------------------------------
def concept_blueprint(small=False):
    """A: blueprint navy, screen grid, white block, orange 'selected' fillet."""
    defs, body = [], []
    defs.append('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d4ed8"/><stop offset="1" stop-color="#0b2a7a"/></linearGradient>')
    defs.append('<radialGradient id="glow" cx="0.5" cy="0.42" r="0.6"><stop offset="0" stop-color="#60a5fa" stop-opacity="0.45"/><stop offset="1" stop-color="#60a5fa" stop-opacity="0"/></radialGradient>')
    body.append('<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>')
    if not small:
        body.append(screen_grid(64, 4, "#bfdbfe", 0.10, 0.22, 2, 3, offset=0))
    part = Part(W=1.0, D=0.78, H=0.62, r=0.30)
    cam = Cam((-0.62, -1.0, 0.78))
    fit_part(cam, part, 600, 512, 520)
    light = (-0.5, -0.9, 1.4)
    d, b = soft_shadow(cam, part, "sh", 0.45, 26, dy=30, color="#020b2e")
    defs.append(d); body.append(b)
    pal = {"base": "#ffffff", "top": "#ffffff", "front": "#cbd8ef", "left": "#9fb3d9", "fillet": "#ff8a3d"}
    d, b = solid(cam, part, pal, light, "fl",
                 fillet_fn=lambda n, ph: mix(mix("#f97316", "#ffb27a", ph / (math.pi / 2)), "#fff3e6", max(0, math.sin(2 * ph)) ** 6 * 0.6))
    defs += d; body += b
    return svg_doc(defs, body)


def concept_printbed(small=False):
    """B: graphite print-bed with iso ground grid, warm filament part with layer lines."""
    defs, body = [], []
    defs.append('<radialGradient id="bg" cx="0.5" cy="0.35" r="0.85"><stop offset="0" stop-color="#3a3f47"/><stop offset="1" stop-color="#121418"/></radialGradient>')
    body.append('<rect width="1024" height="1024" fill="url(#bg)"/>')
    part = Part(W=1.0, D=0.8, H=0.6, r=0.30)
    cam = Cam((-0.75, -1.0, 0.9))
    fit_part(cam, part, 560, 512, 540)
    if not small:
        defs.append('<radialGradient id="gm" cx="0.5" cy="0.6" r="0.55"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>')
        defs.append('<mask id="gmask"><rect width="1024" height="1024" fill="url(#gm)"/></mask>')
        body.append('<g mask="url(#gmask)">%s</g>' % ground_grid(cam, -2.0, 3.0, -2.0, 3.0, 0.25, "#9aa4b2", 2.2, 0.35, major=4, major_opacity=0.6, major_width=3))
    light = (-0.4, -1.0, 1.5)
    d, b = soft_shadow(cam, part, "sh", 0.6, 22, dy=18)
    defs.append(d); body.append(b)
    pal = {"base": "#ff7a1a"}
    d, b = solid(cam, part, pal, light, "fl",
                 fillet_fn=lambda n, ph: lambert("#ff7a1a", n, light, amb=0.42, k=0.62, spec=1.0, view=cam.v, shin=14, tint="#ffe2c4"))
    defs += d; body += b
    if not small:
        body.append(layer_lines(cam, part, 0.04, "#000", 0.13, 1.6))
    return svg_doc(defs, body)


def concept_profile(small=False):
    """C: flat 2D sketch profile: white shape with one filleted corner, radius callout."""
    defs, body = [], []
    defs.append('<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2563eb"/><stop offset="1" stop-color="#1e3a8a"/></linearGradient>')
    body.append('<rect width="1024" height="1024" fill="url(#bg)"/>')
    if not small:
        body.append(screen_grid(64, 4, "#dbeafe", 0.10, 0.22, 2, 3))
    x0, y0, x1, y1, r = 256, 256, 768, 768, 300
    # shape: square with top-right corner filleted
    path = "M%d %d H%d A%d %d 0 0 1 %d %d V%d H%d Z" % (x0, y0, x1 - r, r, r, x1, y0 + r, y1, x0)
    defs.append('<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>')
    body.append('<path d="%s" fill="#0a1a52" opacity="0.45" filter="url(#ds)" transform="translate(0 22)"/>' % path)
    defs.append('<linearGradient id="fg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#dbe6fb"/></linearGradient>')
    body.append('<path d="%s" fill="url(#fg)"/>' % path)
    # arc highlight
    body.append('<path d="M%d %d A%d %d 0 0 1 %d %d" fill="none" stroke="#ff7a1a" stroke-width="34" stroke-linecap="round"/>' % (x1 - r, y0, r, r, x1, y0 + r))
    if not small:
        cxp, cyp = x1 - r, y0 + r
        body.append('<line x1="%d" y1="%d" x2="%s" y2="%s" stroke="#2563eb" stroke-width="10" stroke-dasharray="22 16" stroke-linecap="round"/>'
                    % (cxp, cyp, f(cxp + r * math.cos(math.pi / 4) - 24), f(cyp - r * math.sin(math.pi / 4) + 24)))
        body.append('<circle cx="%d" cy="%d" r="16" fill="#2563eb"/>' % (cxp, cyp))
    return svg_doc(defs, body)


def concept_light(small=False):
    """D: light 'paper' background with fine blue grid; deep blue block, glowing cyan fillet."""
    defs, body = [], []
    defs.append('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e6ecf5"/></linearGradient>')
    body.append('<rect width="1024" height="1024" fill="url(#bg)"/>')
    part = Part(W=1.0, D=0.78, H=0.62, r=0.32)
    cam = Cam((-0.62, -1.0, 0.78))
    fit_part(cam, part, 600, 512, 520)
    if not small:
        defs.append('<radialGradient id="gm" cx="0.5" cy="0.55" r="0.6"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>')
        defs.append('<mask id="gmask"><rect width="1024" height="1024" fill="url(#gm)"/></mask>')
        body.append('<g mask="url(#gmask)">%s</g>' % ground_grid(cam, -2.5, 3.5, -2.5, 3.5, 0.25, "#3b82f6", 2, 0.22, major=4, major_opacity=0.45, major_width=3))
    light = (-0.5, -0.9, 1.4)
    d, b = soft_shadow(cam, part, "sh", 0.30, 24, dy=26, color="#0f2a5e")
    defs.append(d); body.append(b)
    pal = {"top": "#3b6fe0", "front": "#1f45b5", "left": "#173690"}
    d, b = solid(cam, part, pal, light, "fl",
                 fillet_fn=lambda n, ph: mix(mix("#22d3ee", "#a5f3fc", ph / (math.pi / 2)), "#ffffff", max(0, math.sin(2 * ph)) ** 8 * 0.7))
    defs += d; body += b
    return svg_doc(defs, body)


def concept_extrude(small=False, eye=(-1.0, -0.55, 0.62), dims=(1.15, 0.8, 0.8, 0.42), width=620, cy=530,
                    bg=("#2563eb", "#1e3a8a"), name=None):
    """E: the fillet profile, extruded: profile face toward viewer, fillet as orange band."""
    defs, body = [], []
    defs.append('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>' % bg)
    defs.append('<radialGradient id="glow" cx="0.5" cy="0.38" r="0.62"><stop offset="0" stop-color="#93c5fd" stop-opacity="0.35"/><stop offset="1" stop-color="#93c5fd" stop-opacity="0"/></radialGradient>')
    body.append('<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>')
    if not small:
        body.append(screen_grid(64, 4, "#dbeafe", 0.09, 0.2, 2, 3))
    W, D, H, r = dims
    # here the extrusion runs along y (depth) and the profile lies in the x-z plane? keep Part:
    part = Part(W=W, D=D, H=H, r=r)
    cam = Cam(eye)
    fit_part(cam, part, width, 512, cy)
    light = (-1.0, -0.5, 1.3)
    d, b = soft_shadow(cam, part, "sh", 0.5, 26, dy=30, color="#06144a")
    defs.append(d); body.append(b)
    pal = {"left": "#ffffff", "front": "#b9c8e8", "top": "#dbe5f7"}
    d, b = solid(cam, part, pal, light, "fl",
                 fillet_fn=lambda n, ph: mix(mix("#f2600c", "#ff9a52", ph / (math.pi / 2)), "#fff1e3", max(0, math.sin(2 * ph)) ** 6 * 0.55))
    defs += d; body += b
    return svg_doc(defs, body)



# --------------------------------------------------------------------------
# FINAL: refined version of concept E ("extruded fillet profile on blueprint")
# --------------------------------------------------------------------------
FINAL = dict(
    eye=(-1.0, -0.58, 0.66),        # view direction (towards viewer)
    dims=(1.12, 0.82, 0.82, 0.44),  # extrusion length, profile depth, height, fillet radius
    width=600, cy=528,              # projected part width / vertical centre (px on 1024)
    bg_top="#2f6bf0", bg_bot="#1236a6", glow="#9cc3ff",
    grid=True, grid_color="#d6e6ff", grid_op=0.10, grid_major_op=0.22,
    callout=True, layers=False,
    face="#ffffff", face_bot="#e9effb",          # profile face (lit)
    side="#b4c6ec", side_bot="#8fa8dc",          # front face (in shade)
    top="#dce7fb", top_back="#c7d6f4",           # top strip
    f_lo="#ea5a0c", f_hi="#ff9d55", f_spec="#fff3e6",  # fillet
    callout_color="#2f6bf0", callout_op=0.38,
    shadow_color="#061445", shadow_op=0.6,
    small_scale=1.2,                 # the 16/32 px variant: bigger part, no grid/callout
)


def fillet_icon(small=False, layer="all", **over):
    """layer: "all" (flat icon), or for Icon Composer: "background" (glow + grid,
    transparent) / "part" (the solid, shadow and construction lines, transparent)."""
    o = dict(FINAL)
    o.update(over)
    defs, body = [], []
    defs.append('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>' % (o["bg_top"], o["bg_bot"]))
    defs.append('<radialGradient id="glow" cx="0.5" cy="0.36" r="0.6"><stop offset="0" stop-color="%s" stop-opacity="0.38"/><stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient>' % (o["glow"], o["glow"]))
    if layer == "all":
        body.append('<rect width="1024" height="1024" fill="url(#bg)"/>')
    if layer in ("all", "background"):
        body.append('<rect width="1024" height="1024" fill="url(#glow)"/>')
    if o["grid"] and not small and layer in ("all", "background"):
        defs.append('<radialGradient id="gfade" cx="0.5" cy="0.5" r="0.72"><stop offset="0.35" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0.35"/></radialGradient>')
        defs.append('<mask id="gmask"><rect width="1024" height="1024" fill="url(#gfade)"/></mask>')
        body.append('<g mask="url(#gmask)">%s</g>' % screen_grid(64, 4, o["grid_color"], o["grid_op"], o["grid_major_op"], 2, 3))

    if layer == "background":
        return svg_doc(defs, body)
    W, D, H, r = o["dims"]
    part = Part(W=W, D=D, H=H, r=r, seg=64)
    cam = Cam(o["eye"])
    fit_part(cam, part, o["width"] * (o["small_scale"] if small else 1.0), 512, o["cy"])
    light = (-1.0, -0.5, 1.3)

    # shadows: wide soft + tight contact
    if layer == "all":  # Icon Composer adds its own group shadow
        d, b = soft_shadow(cam, part, "sh1", o["shadow_op"], 58, dy=50, grow=-0.10, color=o["shadow_color"])
        defs.append(d); body.append(b)
        d, b = soft_shadow(cam, part, "sh2", 0.4, 9, dy=6, grow=-0.02, color=o["shadow_color"])
        defs.append(d); body.append(b)

    fc = part.faces()
    P = lambda p: cam(p)

    def vgrad(gid, a3, b3, c0, c1):
        a, b = P(a3), P(b3)
        defs.append('<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="%s" y1="%s" x2="%s" y2="%s"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
                    % (gid, f(a[0]), f(a[1]), f(b[0]), f(b[1]), c0, c1))
        return "url(#%s)" % gid

    # profile face (x=0)
    body.append(poly([P(p) for p in fc["left"][0]], vgrad("gl", (0, 0, H), (0, 0, 0), o["face"], o["face_bot"])))
    # front face (y=0)
    body.append(poly([P(p) for p in fc["front"][0]], vgrad("gf", (0, 0, H - r), (W, 0, 0), o["side"], o["side_bot"])))
    # top face
    body.append(poly([P(p) for p in fc["top"][0]], vgrad("gt", (0, r, H), (0, D, H), o["top"], o["top_back"])))
    # fillet
    q = math.pi / 2
    fn = lambda n, ph: mix(mix(o["f_lo"], o["f_hi"], (ph / q) ** 0.8), o["f_spec"], max(0.0, math.sin(2 * ph + 0.25)) ** 10 * 0.7)
    defs.append(fillet_gradient(cam, part, "fl", fn))
    body.append(poly([P(p) for p in part.fillet_poly()], "url(#fl)"))

    if o["layers"] and not small:
        defs.append('<clipPath id="pc"><polygon points="%s"/></clipPath>' % pts([P(p) for p in fc["left"][0]]))
        lines = []
        z = 0.035
        while z < H:
            a, b = P((0, -1, z)), P((0, D + 1, z))
            lines.append('<line x1="%s" y1="%s" x2="%s" y2="%s"/>' % (f(a[0]), f(a[1]), f(b[0]), f(b[1])))
            z += 0.035
        body.append('<g clip-path="url(#pc)" stroke="#1d3d8f" stroke-opacity="0.07" stroke-width="2">%s</g>' % "".join(lines))

    # edge highlights: crisp light rims on the convex edges
    arc0 = [P(p) for p, _ in part.arc(0)]
    rim = [P((0, 0, 0)), P((0, 0, H - r))] + arc0 + [P((0, D, H))]
    sw = 6 if small else 3.5
    body.append('<polyline points="%s" fill="none" stroke="#ffffff" stroke-opacity="0.9" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % (pts(rim), sw))
    arcW = [P(p) for p, _ in part.arc(W)]
    body.append('<polyline points="%s" fill="none" stroke="#ffffff" stroke-opacity="0.35" stroke-width="%s" stroke-linecap="round"/>' % (pts(arcW), sw * 0.7))

    if o["callout"] and not small:
        # CAD construction geometry on the profile face: the rest of the
        # fillet's circle (dashed) and its centre point.
        cc = o["callout_color"]
        circ = []
        for i in range(0, 97):
            ph = q + (3 * q) * i / 96  # from top tangent point round to front tangent point
            circ.append(P((0, r - r * math.cos(ph), H - r + r * math.sin(ph))))
        defs.append('<clipPath id="pc2"><polygon points="%s"/></clipPath>' % pts([P(p) for p in fc["left"][0]]))
        body.append('<g clip-path="url(#pc2)"><polyline points="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="4.5" stroke-dasharray="16 13" stroke-linecap="round"/></g>'
                    % (pts(circ), cc, o["callout_op"]))
        c = P((0, r, H - r))
        m = P((0, r * (1 - math.cos(q / 2)), H - r + r * math.sin(q / 2)))
        body.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="6" stroke-linecap="round"/>'
                    % (f(c[0]), f(c[1]), f(m[0]), f(m[1]), cc))
        body.append('<circle cx="%s" cy="%s" r="11" fill="%s"/>' % (f(c[0]), f(c[1]), cc))
        body.append('<circle cx="%s" cy="%s" r="11" fill="%s"/>' % (f(m[0]), f(m[1]), o["f_lo"]))
    return svg_doc(defs, body)


def macos_wrap(inner_svg, size=S):
    """Place a full-bleed icon SVG into Apple's macOS icon grid: 824px rounded
    rect (r=185.4) centred on the 1024 canvas, with the template drop shadow."""
    import re
    m = re.match(r'<svg[^>]*><defs>(.*?)</defs>(.*)</svg>$', inner_svg, re.S)
    idefs, ibody = m.group(1), m.group(2)
    k = 824 / 1024
    defs = [idefs,
            '<clipPath id="macshape"><rect x="0" y="0" width="1024" height="1024" rx="230.4" ry="230.4"/></clipPath>',
            '<filter id="macshadow" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur in="SourceAlpha" stdDeviation="10"/>'
            '<feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer></filter>']
    body = ['<rect x="100" y="100" width="824" height="824" rx="185.4" ry="185.4" fill="#000" filter="url(#macshadow)"/>',
            '<g transform="translate(100 100) scale(%s)"><g clip-path="url(#macshape)">%s</g></g>' % (k, ibody)]
    return svg_doc(defs, body, size)


VARIANTS = {
    # alternative colourway kept for reference (not shipped)
    "alt-navy": dict(bg_top="#1b2a55", bg_bot="#0a1126", glow="#5b8cff", grid_color="#9db9ff", grid_op=0.10, grid_major_op=0.2, callout_color="#3b6fe0"),
}

CONCEPTS = {
    "concept-a-blueprint": concept_blueprint,
    "concept-b-printbed": concept_printbed,
    "concept-c-profile": concept_profile,
    "concept-d-light": concept_light,
    "concept-e-extrude": concept_extrude,
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in CONCEPTS.items():
        for small in (False, True):
            with open(os.path.join(OUT, name + ("-small" if small else "") + ".svg"), "w") as fh:
                fh.write(fn(small))
    for name, kw in VARIANTS.items():
        for small in (False, True):
            with open(os.path.join(OUT, name + ("-small" if small else "") + ".svg"), "w") as fh:
                fh.write(fillet_icon(small, **kw))
    # deliverable masters
    with open(os.path.join(OUT, "fillet-ios.svg"), "w") as fh:
        fh.write(fillet_icon(False))
    with open(os.path.join(OUT, "fillet-macos.svg"), "w") as fh:
        fh.write(macos_wrap(fillet_icon(False)))
    with open(os.path.join(OUT, "fillet-macos-small.svg"), "w") as fh:
        fh.write(macos_wrap(fillet_icon(True)))
    for layer in ("background", "part"):
        with open(os.path.join(OUT, "layer-%s.svg" % layer), "w") as fh:
            fh.write(fillet_icon(False, layer=layer))
    print("wrote", OUT)
