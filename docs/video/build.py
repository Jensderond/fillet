#!/usr/bin/env python3
"""Builds the Fillet announcement from a demo recording.

    docs/video/record-demo.sh build/video/raw/take3.mp4   # once: record the paced demo on the 12.9" simulator
    python3 docs/video/build.py                            # everything below

1. plan.json: the edit (edit.py) — segments, titles, callouts, all timed to the beat log
2. device.mp4: the recording cut to the edit (constant 30 fps, crossfades at cuts)
3. voice-over (voiceover.py, macOS `say`), music and effects (audio.py, numpy)
4. the mix: music ducked under the voice (sidechaincompress), effects, two-pass
   loudnorm to -14 LUFS / -1.5 dBTP, verified with ebur128 after AAC encoding
5. picture: the Swift compositor (compositor/main.swift + the app's splash code)
   renders 1920x1080 and 1080x1080 frames, piped into x264 (High profile)
6. Fillet-Announcement.srt and the poster

Media goes to build/video/ (gitignored). `--stage picture|audio|all` reruns part of it.
"""
import argparse, json, os, re, subprocess, sys, textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import edit
import voiceover

ROOT = edit.ROOT
B = os.path.join(ROOT, "build/video")
OUT = os.path.join(B, "out")
APP = os.path.join(ROOT, "App/Sources")
ICON = os.path.join(ROOT, "docs/icon/final-1024.png")


def run(cmd, **kw):
    print("+", " ".join(cmd) if isinstance(cmd, list) else cmd, file=sys.stderr)
    return subprocess.run(cmd, check=True, **kw)


def probe_duration(path):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                capture_output=True, text=True, check=True).stdout)


# MARK: Plan and device clip

def write_plan():
    os.makedirs(B, exist_ok=True)
    plan = edit.plan()
    with open(os.path.join(B, "plan.json"), "w") as f:
        json.dump(plan, f, indent=1)
    return plan


def device_clip(plan):
    """The recording cut to the edit at 1536x2048, 30 fps."""
    segs = plan["segments"]
    fps = plan["fps"]
    parts = [f"[0:v]fps=60,split={len(segs)}" + "".join(f"[r{i}]" for i in range(len(segs)))]
    for i, s in enumerate(segs):
        parts.append(f"[r{i}]trim=start={s['src_start']}:end={s['src_end']},setpts=(PTS-STARTPTS)/{s['speed']},"
                     f"fps={fps},scale=1536:2048:flags=lanczos,setsar=1,format=yuv420p[s{i}]")
    acc, length = "s0", (segs[0]["src_end"] - segs[0]["src_start"]) / segs[0]["speed"]
    for i, s in enumerate(segs[1:], 1):
        seg_len = (s["src_end"] - s["src_start"]) / s["speed"]
        if s["join"] == "cut":
            parts.append(f"[{acc}][s{i}]xfade=transition=fade:duration={edit.XFADE}:offset={length - edit.XFADE:.4f}[j{i}]")
            length += seg_len - edit.XFADE
        else:
            parts.append(f"[{acc}][s{i}]concat=n=2:v=1:a=0[j{i}]")
            length += seg_len
        acc = f"j{i}"
    hold = segs[-1].get("hold", 0)
    parts.append(f"[{acc}]tpad=stop_mode=clone:stop_duration={hold}[v]")
    out = os.path.join(B, "device.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-i", edit.TAKE, "-filter_complex", ";".join(parts), "-map", "[v]",
         "-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", out])
    print(f"device clip {probe_duration(out):.2f}s (planned {plan['device_out'] - plan['device_in']:.2f}s)", file=sys.stderr)
    return out


# MARK: Audio

def loudness(path, extra=""):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", f"{extra}ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    s = r.stderr[r.stderr.rfind("Summary:"):]
    I = float(re.search(r"I:\s+(-?[\d.]+) LUFS", s).group(1))
    lra = float(re.search(r"LRA:\s+(-?[\d.]+) LU", s).group(1))
    tp = float(re.search(r"Peak:\s+(-?[\d.inf]+) dBFS", s).group(1))
    return dict(I=I, LRA=lra, TP=tp)


def audio(plan):
    vo_dir = os.path.join(B, "vo")
    lines = voiceover.render(vo_dir)
    starts = edit.voice_starts(lines)
    for l in lines:
        l["start"] = starts[l["id"]]
    json.dump(lines, open(os.path.join(vo_dir, "placed.json"), "w"), indent=1)
    run([sys.executable, os.path.join(HERE, "audio.py"), os.path.join(B, "audio")])
    total = plan["total"]

    # The voice on its own track.
    inputs, chains = [], []
    for i, l in enumerate(lines):
        inputs += ["-i", l["file"]]
        ms = int(round(l["start"] * 1000))
        chains.append(f"[{i}:a]adelay={ms}|{ms}[d{i}]")
    vo = os.path.join(B, "audio/vo.wav")
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex",
         ";".join(chains) + ";" + "".join(f"[d{i}]" for i in range(len(lines))) +
         f"amix=inputs={len(lines)}:normalize=0,apad=whole_dur={total},atrim=0:{total}[v]",
         "-map", "[v]", "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", vo])

    # Gain staging: voice about 9 LU over the bed, effects tucked in.
    lv = loudness(vo)["I"]
    lm = loudness(os.path.join(B, "audio/music.wav"))["I"]
    g_vo = -16.0 - lv
    g_music = -24.5 - lm
    mix = os.path.join(B, "audio/mix-pre.wav")
    fc = (f"[0:a]volume={g_vo:.2f}dB,asplit[vo][key];"
          f"[1:a]highpass=f=35,volume={g_music:.2f}dB[m];"
          f"[m][key]sidechaincompress=threshold=0.02:ratio=4:attack=25:release=450:makeup=1[md];"
          f"[2:a]volume=-3dB[fx];"
          f"[md][fx][vo]amix=inputs=3:normalize=0[a]")
    run(["ffmpeg", "-v", "error", "-y", "-i", vo, "-i", os.path.join(B, "audio/music.wav"), "-i", os.path.join(B, "audio/sfx.wav"),
         "-filter_complex", fc, "-map", "[a]", "-c:a", "pcm_f32le", mix])

    # Two-pass loudnorm to -14 LUFS, true peak -1.5 dBTP (headroom for the AAC encode).
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", mix, "-af",
                        "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"], capture_output=True, text=True)
    m = json.loads(r.stderr[r.stderr.rfind("{"):r.stderr.rfind("}") + 1])
    final = os.path.join(B, "audio/mix.wav")
    run(["ffmpeg", "-v", "error", "-y", "-i", mix, "-af",
         f"loudnorm=I=-14:TP=-1.5:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
         f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true,"
         "aresample=48000", "-c:a", "pcm_s24le", final])
    return final, lines


# MARK: Picture

def compositor():
    exe = os.path.join(B, "compositor")
    sources = [os.path.join(HERE, "compositor/main.swift"), os.path.join(APP, "Theme/Theme.swift"),
               os.path.join(APP, "Splash/Theme+Splash.swift"), os.path.join(APP, "Splash/SplashArtwork.swift"),
               os.path.join(APP, "Splash/SplashGeometry.swift"), os.path.join(APP, "Splash/SplashTimeline.swift")]
    if not os.path.exists(exe) or any(os.path.getmtime(s) > os.path.getmtime(exe) for s in sources):
        run(["swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", exe, *sources])
    return exe


def picture(plan, size, name):
    exe = compositor()
    w, h = size
    out = os.path.join(B, f"{name}-video.mp4")
    comp = subprocess.Popen([exe, os.path.join(B, "plan.json"), os.path.join(B, "device.mp4"), ICON, str(w), str(h)],
                            stdout=subprocess.PIPE)
    run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", f"{w}x{h}", "-r", str(plan["fps"]),
         "-i", "-", "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
         "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-movflags", "+faststart", out],
        stdin=comp.stdout)
    comp.wait()
    if comp.returncode:
        raise SystemExit("compositor failed")
    return out


def mux(video, audio_path, out):
    run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", audio_path, "-map", "0:v", "-map", "1:a",
         "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-shortest",
         "-movflags", "+faststart", out])


def poster(plan):
    exe = compositor()
    # The widened part, back in 3D, just before the rollback scrub.
    t = edit.out(edit.beat("hero-done") + 0.3) - plan["device_in"]
    out = os.path.join(OUT, "Fillet-Announcement-poster.png")
    run([exe, os.path.join(B, "plan.json"), os.path.join(B, "device.mp4"), ICON, "1920", "1080", "--poster", f"{t:.3f}", out])
    return out


# MARK: Captions

def balance(text, width=42):
    """One line if it fits, else two lines split near the middle, preferring a break after punctuation."""
    if len(text) <= width:
        return text
    keep = [m.start() + len(w) for w in ("Bambu", "Apple", "iCloud", "80") for m in re.finditer(w + " ", text)]
    spaces = [i for i, c in enumerate(text) if c == " " and i not in keep]
    def cost(i):
        a, b = text[:i], text[i + 1:]
        over = max(len(a), len(b)) > width
        return (over, abs(len(a) - len(b)) - (20 if a.endswith((".", ":")) else 10 if a.endswith(",") else 0))
    i = min(spaces, key=cost)
    return text[:i] + "\n" + text[i + 1:]


def srt(lines, path):
    def ts(x):
        ms = int(round(x * 1000))
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
    cues = []
    for l in lines:
        start, end = l["start"], l["start"] + l["duration"] + 0.25
        wrapped = textwrap.wrap(l["caption"], 42)
        if len(wrapped) > 2 and len(l["caption"]) > 80:  # two lines at most: split into consecutive cues at the sentence break
            parts = re.split(r"(?<=[.:]) ", l["caption"], maxsplit=1)
            share = len(parts[0]) / len(l["caption"])
            mid = start + (end - start) * share
            cues += [(start, mid, "\n".join(textwrap.wrap(parts[0], 42))), (mid, end, "\n".join(textwrap.wrap(parts[1], 42)))]
        else:
            cues.append((start, end, balance(l["caption"])))
    # Never overlap the next cue.
    fixed = []
    for i, (a, b, text) in enumerate(cues):
        if i + 1 < len(cues):
            b = min(b, cues[i + 1][0] - 0.05)
        fixed.append((a, b, text))
    with open(path, "w") as f:
        for i, (a, b, text) in enumerate(fixed, 1):
            f.write(f"{i}\n{ts(a)} --> {ts(b)}\n{text}\n\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="all", choices=["all", "picture", "audio", "device", "poster"])
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    plan = write_plan()
    if args.stage in ("all", "device"):
        device_clip(plan)
    if args.stage in ("all", "audio"):
        mix, lines = audio(plan)
        srt(lines, os.path.join(OUT, "Fillet-Announcement.srt"))
    mix = os.path.join(B, "audio/mix.wav")
    if args.stage in ("all", "picture"):
        for size, name in [((1920, 1080), "16x9"), ((1080, 1080), "Square")]:
            v = picture(plan, size, name)
            mux(v, mix, os.path.join(OUT, f"Fillet-Announcement-{name}.mp4"))
    if args.stage in ("all", "picture", "poster"):
        poster(plan)
    for name in ["16x9", "Square"]:
        p = os.path.join(OUT, f"Fillet-Announcement-{name}.mp4")
        if os.path.exists(p):
            print(name, loudness(p))


if __name__ == "__main__":
    main()
