#!/usr/bin/env python3
"""Flattens Bambu Studio system presets (their "inherits" chains) into stand-alone JSON files the
Bambu Studio CLI can load with --load-settings / --load-filaments.

    scripts/bambu-profiles.py OUT_DIR [--machine NAME] [--process NAME] [--filament NAME]

Writes OUT_DIR/machine.json, process.json, filament.json and prints their paths.
"""
import argparse
import json
import os
import sys

PROFILES = "/Applications/BambuStudio.app/Contents/Resources/profiles/BBL"


def index(kind):
    by_name = {}
    folder = os.path.join(PROFILES, kind)
    for root, _, files in os.walk(folder):
        for f in files:
            if not f.endswith(".json"):
                continue
            path = os.path.join(root, f)
            try:
                with open(path) as fh:
                    data = json.load(fh)
            except Exception:
                continue
            if isinstance(data, dict) and "name" in data:
                by_name[data["name"]] = data
    return by_name


def flatten(name, presets, depth=0):
    if depth > 20 or name not in presets:
        raise SystemExit(f"preset not found: {name}")
    data = presets[name]
    parent = data.get("inherits")
    merged = flatten(parent, presets, depth + 1) if parent else {}
    merged.update({k: v for k, v in data.items() if k != "inherits"})
    return merged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--machine", default="Bambu Lab A1 mini 0.4 nozzle")
    ap.add_argument("--process", default="0.20mm Standard @BBL A1M")
    ap.add_argument("--filament", default="Bambu PLA Basic @BBL A1M")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for kind, name, file in (("machine", a.machine, "machine.json"), ("process", a.process, "process.json"),
                             ("filament", a.filament, "filament.json")):
        data = flatten(name, index(kind))
        data["from"] = "system"
        data.setdefault("type", kind)
        if kind == "filament":
            data.setdefault("filament_settings_id", [name])
        if kind == "process":
            data.setdefault("print_settings_id", name)
        path = os.path.join(a.out, file)
        with open(path, "w") as fh:
            json.dump(data, fh, indent=1)
        print(path)


if __name__ == "__main__":
    sys.exit(main())
