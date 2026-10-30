#!/usr/bin/env python3
"""Builds the Section view film from a take of the paced demo.

    docs/video/section/record.sh build/video/section/raw/take.mp4   # once: record the demo on the 12.9" simulator
    python3 docs/video/section/sync.py build/video/section/raw/take.mp4
    python3 docs/video/section/build.py                              # everything below
    python3 docs/video/section/beatcheck.py                          # cuts and actions against the beat grid
    docs/video/section/qc.sh                                         # contact sheets, loudness, streams

1. plan.json: the edit (edit.py) — shots, framing, titles, all on the beat grid (timeline.py)
2. device.mp4: the take cut to the shots, frame-exact (each output frame is every other 60 fps frame)
3. music.wav (music.py, numpy), mastered with two-pass loudnorm to -16 LUFS, -1.5 dBTP
4. picture: the shared compositor (../compositor/main.swift) at 1920x1080, x264 High
5. Fillet-Section-View.mp4 (AAC 256 kb/s) and Fillet-Section-View-poster.png

Everything goes to build/video/section/ (gitignored); the deliverables to build/video/section/out/.
`--stage device|audio|picture|poster` reruns part of it.
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import edit
import timeline as tl

ROOT = edit.ROOT
B = edit.B
OUT = os.path.join(B, "out")
APP = os.path.join(ROOT, "App/Sources")
ICON = os.path.join(ROOT, "docs/icon/final-1024.png")
NAME = "Fillet-Section-View"
LUFS, TP = -16.0, -1.5


def run(cmd, **kw):
    print("+", " ".join(cmd) if isinstance(cmd, list) else cmd, file=sys.stderr)
    return subprocess.run(cmd, check=True, **kw)


def write_plan():
    os.makedirs(B, exist_ok=True)
    plan = edit.plan()
    with open(os.path.join(B, "plan.json"), "w") as f:
        json.dump(plan, f, indent=1)
    with open(os.path.join(B, "shots.json"), "w") as f:
        json.dump(edit.SHOT_LIST, f, indent=1)
    return plan


def device_clip():
    shots = edit.SHOT_LIST
    n = len(shots)
    parts = [f"[0:v]fps={edit.SRC_FPS}:start_time=0:round=up,split={n}" + "".join(f"[r{i}]" for i in range(n))]
    for i, s in enumerate(shots):
        a = s["src_frame"]
        parts.append(f"[r{i}]trim=start_frame={a}:end_frame={a + 2 * s['out_frames']},setpts=PTS-STARTPTS,framestep=2,"
                     f"setpts=N/({tl.FPS}*TB),scale=1536:2048:flags=lanczos,setsar=1,format=yuv420p[s{i}]")
    parts.append("".join(f"[s{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0[v]")
    out = os.path.join(B, "device.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-i", edit.TAKE, "-filter_complex", ";".join(parts), "-map", "[v]", "-r", str(tl.FPS),
         "-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", out])
    frames = int(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v", "-show_entries", "stream=nb_read_frames",
                                 "-of", "csv=p=0", out], capture_output=True, text=True).stdout.strip())
    want = sum(s["out_frames"] for s in shots)
    print(f"device clip: {frames} frames (planned {want})", file=sys.stderr)
    if frames != want:
        raise SystemExit("device clip has the wrong number of frames")
    return out


def loudness(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    s = r.stderr[r.stderr.rfind("Summary:"):]
    return dict(I=float(re.search(r"I:\s+(-?[\d.]+) LUFS", s)[1]), LRA=float(re.search(r"LRA:\s+(-?[\d.]+) LU", s)[1]),
                TP=float(re.search(r"Peak:\s+(-?[\d.inf]+) dBFS", s)[1]))


def audio():
    adir = os.path.join(B, "audio")
    run([sys.executable, os.path.join(HERE, "music.py"), adir])
    raw = os.path.join(adir, "music.wav")
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", raw, "-af",
                        f"loudnorm=I={LUFS}:TP={TP}:LRA=11:print_format=json", "-f", "null", "-"], capture_output=True, text=True)
    m = json.loads(r.stderr[r.stderr.rfind("{"):r.stderr.rfind("}") + 1])
    final = os.path.join(adir, "mix.wav")
    run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-af",
         f"loudnorm=I={LUFS}:TP={TP}:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
         f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true,"
         f"aresample=48000,atrim=0:{tl.TOTAL}", "-c:a", "pcm_s24le", final])
    print("mix", loudness(final), file=sys.stderr)
    return final


def compositor():
    exe = os.path.join(B, "compositor")
    sources = [os.path.join(HERE, "../compositor/main.swift"), os.path.join(APP, "Theme/Theme.swift"),
               os.path.join(APP, "Splash/Theme+Splash.swift"), os.path.join(APP, "Splash/SplashArtwork.swift"),
               os.path.join(APP, "Splash/SplashGeometry.swift"), os.path.join(APP, "Splash/SplashTimeline.swift")]
    if not os.path.exists(exe) or any(os.path.getmtime(s) > os.path.getmtime(exe) for s in sources):
        run(["swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", exe, *sources])
    return exe


def picture():
    exe = compositor()
    out = os.path.join(B, "16x9-video.mp4")
    comp = subprocess.Popen([exe, os.path.join(B, "plan.json"), os.path.join(B, "device.mp4"), ICON, "1920", "1080"], stdout=subprocess.PIPE)
    run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "1920x1080", "-r", str(tl.FPS),
         "-i", "-", "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
         "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-movflags", "+faststart", out], stdin=comp.stdout)
    comp.wait()
    if comp.returncode:
        raise SystemExit("compositor failed")
    return out


def mux(video, mix):
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, f"{NAME}.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", mix, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
         "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-shortest", "-movflags", "+faststart", out])
    return out


def poster():
    exe = compositor()
    # The part just cut open: three bodies, three colours, the handles up.
    t = tl.t(6, 2) - edit.DEVICE_IN
    out = os.path.join(OUT, f"{NAME}-poster.png")
    os.makedirs(OUT, exist_ok=True)
    run([exe, os.path.join(B, "plan.json"), os.path.join(B, "device.mp4"), ICON, "1920", "1080", "--poster", f"{t:.3f}", out])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="all", choices=["all", "device", "audio", "picture", "poster"])
    args = ap.parse_args()
    write_plan()
    if args.stage in ("all", "device"):
        device_clip()
    if args.stage in ("all", "audio"):
        audio()
    if args.stage in ("all", "picture"):
        mux(picture(), os.path.join(B, "audio/mix.wav"))
    if args.stage in ("all", "picture", "poster"):
        poster()
    final = os.path.join(OUT, f"{NAME}.mp4")
    if os.path.exists(final):
        print(NAME, loudness(final))


if __name__ == "__main__":
    main()
