#!/usr/bin/env python3
"""Cuts a recorded spec run (record.sh) into a short looping web clip, with touch marks.

    python3 clip.py <name>          # reads <name>.clip.json next to this script

The clip spec (all coordinates in points of the 1366x1024 landscape screen, times in seconds of
the recording; "step": N means "when step N started", from <rec>.steps):

{
  "rec": "pick-edges",                       # build/docs-shots/fillet-chamfer-shell/<rec>.mov/.steps
  "segments": [[{"step": 12, "dt": -0.6}, {"step": 15, "dt": 0}], ...],   # kept, in order
  "touches": [{"step": 12, "dt": 0.3, "at": [656, 563], "hold": 0.35}],
  "drags":   [{"step": 17, "dt": 0.3, "from": [..], "to": [..], "dur": 1.2, "down": 16.2}],
                                             # "down": when the finger lands, if before the move
  "hold": 1.6,                               # freeze the last frame this long before looping
  "crop": [x, y, w, h],                      # the desktop cut
  "width": 1600,                             # desktop output width in px
  "phone": [[x, y, w, h], ...],              # crops stacked top to bottom for phones
  "phoneWidth": 720,
  "out": "pick-edges"                        # src/assets/screens/fillet-chamfer-shell/<out>.mp4,
}                                            #   <out>-phone.mp4, <out>.jpg (poster: last frame)
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
REC = os.path.join(ROOT, 'build/docs-shots/fillet-chamfer-shell/r2')
PUB = os.path.join(ROOT, 'site/src/assets/screens/fillet-chamfer-shell')
FPS = 30
S = 2  # px per pt


def main(name):
    spec = json.load(open(os.path.join(HERE, name + '.clip.json')))
    rec = spec['rec']
    steps = {}
    for line in open(os.path.join(REC, rec + '.steps')):
        n, _, t = line.split()
        steps.setdefault(int(n), float(t))

    def at(ref):
        if isinstance(ref, (int, float)):
            return float(ref)
        if 't' in ref:  # a time read off the recording's frames (the step log can lag)
            return float(ref['t'])
        return steps[ref['step']] + ref.get('dt', 0)

    segs = [(at(a), at(b)) for a, b in spec['segments']]
    touch = os.path.join(HERE, 'touch.png')
    inputs = ['-i', os.path.join(REC, rec + '.mov')]
    chains = [f'[0:v]fps={FPS},format=rgba[v0]']
    cur = 'v0'
    k = 0
    D = 88  # touch mark diameter in px (44 pt)

    def mark(start, end, xexpr, yexpr):
        nonlocal cur, k
        k += 1
        inputs.extend(['-loop', '1', '-t', f'{end + 1:.2f}', '-i', touch])
        fi = min(0.08, (end - start) / 3)
        chains.append(f'[{k}:v]format=rgba,scale={D}:{D},colorchannelmixer=aa=0.8,'
                      f'fade=in:st={start:.3f}:d={fi:.3f}:alpha=1,'
                      f'fade=out:st={end - 0.15:.3f}:d=0.15:alpha=1[m{k}]')
        chains.append(f"[{cur}][m{k}]overlay=x='{xexpr}':y='{yexpr}':"
                      f"enable='between(t,{start:.3f},{end:.3f})':eof_action=pass[v{k}]")
        cur = f'v{k}'

    for t in spec.get('touches', []):
        s = at(t)
        x, y = t['at']
        mark(s, s + t.get('hold', 0.4), f'{x * S - D / 2:.0f}', f'{y * S - D / 2:.0f}')
    for d in spec.get('drags', []):
        s = at(d)
        dur = d['dur']
        (x0, y0), (x1, y1) = d['from'], d['to']
        p = f'min(max((t-{s:.3f})/{dur:.3f},0),1)'
        mark(at(d['down']) if 'down' in d else s, s + dur + d.get('hold', 0.25),
             f'{x0 * S - D / 2:.0f}+({(x1 - x0) * S:.0f})*{p}',
             f'{y0 * S - D / 2:.0f}+({(y1 - y0) * S:.0f})*{p}')

    sel = '+'.join(f'between(t,{a:.3f},{b:.3f})' for a, b in segs)
    hold = spec.get('hold', 1.6)
    chains.append(f"[{cur}]select='{sel}',setpts=N/{FPS}/TB,"
                  f"tpad=stop_mode=clone:stop_duration={hold},format=yuv420p,split=2[d][p]")
    x, y, w, h = [v * S for v in spec['crop']]
    W = spec.get('width', 1600)
    chains.append(f'[d]crop={w}:{h}:{x}:{y},scale={W}:-2:flags=lanczos[desk]')
    phone = spec.get('phone')
    PW = spec.get('phoneWidth', 720)
    if phone:
        n = len(phone)
        chains.append(f'[p]split={n}' + ''.join(f'[p{i}]' for i in range(n)) if n > 1 else '[p]null[p0]')
        for i, (px, py, pw, ph) in enumerate(phone):
            sep = f',pad=iw:ih+6:0:0:color=0xD9D6CF' if i < n - 1 else ''  # a hairline between the crops
            chains.append(f'[p{i}]crop={pw * S}:{ph * S}:{px * S}:{py * S},scale={PW}:-2:flags=lanczos{sep}[q{i}]')
        if n > 1:
            chains.append(''.join(f'[q{i}]' for i in range(n)) + f'vstack={n}[ph]')
        else:
            chains.append('[q0]null[ph]')
    else:
        chains.append('[p]nullsink')

    out = os.path.join(PUB, spec['out'])
    os.makedirs(PUB, exist_ok=True)
    enc = ['-c:v', 'libx264', '-preset', 'slow', '-crf', '24', '-pix_fmt', 'yuv420p',
           '-movflags', '+faststart', '-an']
    cmd = ['ffmpeg', '-v', 'error', '-y', *inputs, '-filter_complex', ';'.join(chains),
           '-map', '[desk]', *enc, out + '.mp4']
    if phone:
        cmd += ['-map', '[ph]', *enc, out + '-phone.mp4']
    subprocess.run(cmd, check=True)
    # Poster: the last frame (the result), as JPEG.
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-sseof', '-0.2', '-i', out + '.mp4',
                    '-frames:v', '1', '-q:v', '3', out + '.jpg'], check=True)
    if phone:
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-sseof', '-0.2', '-i', out + '-phone.mp4',
                        '-frames:v', '1', '-q:v', '3', out + '-phone.jpg'], check=True)
    for f in [out + '.mp4', out + '-phone.mp4', out + '.jpg', out + '-phone.jpg']:
        if os.path.exists(f):
            r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'stream=width,height:format=duration',
                                '-of', 'csv=p=0', f], capture_output=True, text=True).stdout.split()
            print(f, os.path.getsize(f) // 1024, 'KB', ' '.join(r))


if __name__ == '__main__':
    main(sys.argv[1])
