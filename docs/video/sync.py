#!/usr/bin/env python3
"""Finds when the launch splash first shows in a demo recording, so beat times
(seconds since the demo started, logged by DemoDirector) map onto the video.

    python3 docs/video/sync.py build/video/raw/take.mp4   ->  prints the offset in seconds

The splash's paper (#F5EFE0) fills the screen on its first frames; the beat
'launch' is logged in the same run-loop turn the splash appears.
"""
import subprocess, sys
import numpy as np

def splash_offset(path, fps=60, w=16, h=21):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-t", "8", "-i", path, "-vf", f"fps={fps},scale={w}:{h}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3).astype(float)
    paper = np.array([0xF5, 0xEF, 0xE0], float)
    for i, f in enumerate(frames):
        centre = f[4:-4, 2:-2].reshape(-1, 3)
        if np.mean(np.abs(centre - paper).max(axis=1) < 14) > 0.6:
            return i / fps
    raise SystemExit("no splash found")

if __name__ == "__main__":
    print(f"{splash_offset(sys.argv[1]):.3f}")
