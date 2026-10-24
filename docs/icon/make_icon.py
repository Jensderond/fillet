#!/usr/bin/env python3
"""Assemble the Icon Composer bundle (AppIcon.icon) for the flat Fillet icon.

    python3 make_icon.py <out.icon> [--fillet-glass] [--outline-glass] [--shadow neutral|none]

Layers (front to back): orange fillet, ink outline, paper + grid background.
Light/dark variants use `*-specializations` (appearance "dark"): navy paper with
light line work in dark mode. Layer PNGs are rendered from svg/final-layer-*.svg
(run flat.py first).
"""
import argparse
import json
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "svg")


def srgb(h):
    h = h.lstrip("#")
    return "srgb:" + ",".join("%.5f" % (int(h[i:i + 2], 16) / 255) for i in (0, 2, 4)) + ",1.00000"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--fillet-glass", action="store_true")
    ap.add_argument("--outline-glass", action="store_true")
    ap.add_argument("--shadow", default="none")
    a = ap.parse_args()

    from flat import PAPER

    if os.path.isdir(a.out):
        shutil.rmtree(a.out)
    assets = os.path.join(a.out, "Assets")
    os.makedirs(assets)
    for name in ("background", "background-dark", "outline", "outline-dark", "fillet"):
        src = os.path.join(SVG, "final-layer-%s.svg" % name)
        subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", src, "-o", os.path.join(assets, name + ".png")], check=True)

    def spec(light, dark):
        return [{"value": light}, {"appearance": "dark", "value": dark}]

    doc = {
        "fill-specializations": spec({"solid": srgb(PAPER["light"]["paper"])}, {"solid": srgb(PAPER["dark"]["paper"])}),
        "groups": [
            {
                "layers": [
                    {"name": "fillet", "image-name": "fillet.png", "glass": a.fillet_glass},
                    {"name": "outline", "image-name-specializations": spec("outline.png", "outline-dark.png"), "glass": a.outline_glass},
                ],
                "shadow": {"kind": a.shadow, "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            },
            {
                "layers": [
                    {"name": "background", "image-name-specializations": spec("background.png", "background-dark.png"), "glass": False},
                ],
                "shadow": {"kind": "none", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(a.out, "icon.json"), "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
