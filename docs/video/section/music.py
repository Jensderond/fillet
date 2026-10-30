#!/usr/bin/env python3
"""Original music for the Section view film, synthesised with numpy (nothing sampled).

    python3 docs/video/section/music.py OUT_DIR   ->  OUT_DIR/music.wav (48 kHz stereo, 24-bit), OUT_DIR/music.json

Dark, precise and futuristic, in D minor at 112.5 bpm (timeline.py), 19 bars:

  0–1   airy pad and a sub swell; a filtered pulse arpeggio wakes up under the title
  2–4   the device comes in: gated bass pulse, a soft kick, the filter opening; bar 4 is the
        riser (noise sweep, pitch riser, snare roll, reversed swell) into
  5     the IMPACT as the cut opens the part: boom, crash, full groove (four on the floor,
        claps on 2 and 4, sixteenth hats, sidechained pad and bass)
  7–8   scanner textures follow the arrow out and back: a swept band of noise, data blips
  9–10  a glide rises with the grip's angle
  11    a reversed hit into the flip, a blip on the untilt
  12–13 2D section: an Ebmaj7 lift (Phrygian), half-time drums, crystal bells
  14    Section only: stripped to the bass pulse, the arpeggio and ticks
  15–16 the groove comes back; a roll into
  17    the end card: D major (a Picardy third), boom, bells, a long tail

The chord changes and every hit fall on the beat grid, so they land with the picture.
"""
import json, os, sys, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import timeline as tl

SR = 48000
RNG = np.random.default_rng(1125)
N = int(tl.TOTAL * SR)


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def T(bar, beat=0.0):
    return tl.t(bar, beat)


def secs(n):
    return np.arange(int(n * SR)) / SR


# MARK: DSP

def fft_filter(x, response):
    """Filters x with a magnitude response given as a function of frequency (Hz)."""
    n = len(x)
    size = 1 << int(np.ceil(np.log2(max(n, 2))))
    X = np.fft.rfft(x, size)
    f = np.fft.rfftfreq(size, 1 / SR)
    return np.fft.irfft(X * response(f), size)[:n]


def lp(cut, order=4):
    return lambda f: 1 / np.sqrt(1 + (f / cut) ** (2 * order))


def hp(cut, order=4):
    return lambda f: 1 / np.sqrt(1 + (cut / np.maximum(f, 1e-3)) ** (2 * order))


def bp(lo, hi, order=3):
    return lambda f: lp(hi, order)(f) * hp(lo, order)(f)


def resonant_lp(cut, q=2.0):
    """A low-pass with a resonant bump at the cutoff (the squelch of an analogue filter)."""
    return lambda f: 1 / np.sqrt((1 - (f / cut) ** 2) ** 2 + (f / (cut * q)) ** 2) / np.sqrt(1 + (f / cut) ** 4)


def stft_filter(x, cutoff_at, kind="lp", q=1.5, frame=2048, hop=512):
    """Time-varying filter: each overlapping frame gets the response for the cutoff at its centre
    (cutoff_at(t) -> Hz, or (lo, hi) for a band-pass)."""
    win = np.hanning(frame)
    pad = np.concatenate([np.zeros(frame), x, np.zeros(frame)])
    out = np.zeros_like(pad)
    norm = np.zeros_like(pad)
    f = np.fft.rfftfreq(frame, 1 / SR)
    for i in range(0, len(pad) - frame, hop):
        c = cutoff_at((i + frame / 2 - frame) / SR)
        if kind == "lp":
            r = resonant_lp(c, q)(f)
        else:
            r = bp(c[0], c[1], 2)(f)
        seg = np.fft.irfft(np.fft.rfft(pad[i:i + frame] * win) * r, frame)
        out[i:i + frame] += seg * win
        norm[i:i + frame] += win ** 2
    return (out / np.maximum(norm, 1e-6))[frame:frame + len(x)]


def saw(freq, t, phase=0.0):
    """Band-limited sawtooth by additive partials up to 16 kHz."""
    s = np.zeros_like(t)
    k = 1
    while k * freq < 16000 and k < 60:
        s += np.sin(2 * np.pi * k * freq * t + phase * k) / k
        k += 1
    return s * (2 / np.pi)


def pulse(freq, t, width=0.3):
    """Band-limited pulse: the difference of two saws."""
    return saw(freq, t) - saw(freq, t, phase=2 * np.pi * width)


def env(n, a, d, s, r, sr=SR):
    a, d, r = max(int(a * sr), 1), int(d * sr), int(r * sr)
    e = np.full(n + r, s, float)
    e[:a] = np.linspace(0, 1, a)
    if d:
        k = min(d, max(len(e) - a, 0))
        e[a:a + k] = s + (1 - s) * np.exp(-np.linspace(0, 5, k))
    if r:
        e[n:] = e[n - 1 if n else 0] * np.exp(-np.linspace(0, 7, r))
    return e


def place(buf, start, sig, gain=1.0, pan=0.0):
    i = int(round(start * SR))
    if sig.ndim == 1:
        sig = np.stack([sig * np.sqrt(0.5 * (1 - pan)) * 1.414, sig * np.sqrt(0.5 * (1 + pan)) * 1.414], axis=1)
    if i < 0:
        sig, i = sig[-i:], 0
    j = min(len(buf), i + len(sig))
    if j > i:
        buf[i:j] += sig[: j - i] * gain


def reverb(stereo, seconds=2.4, mix=0.3, predelay=0.025, bright=6000, seed=3):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.empty_like(stereo)
    for ch in range(2):
        ir = rng.standard_normal(n) * np.exp(-t * 6.9 / seconds)
        ir = fft_filter(ir, lp(bright, 2))
        ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
        ir /= np.sqrt(np.sum(ir ** 2))
        size = 1 << int(np.ceil(np.log2(len(stereo) + len(ir))))
        wet = np.fft.irfft(np.fft.rfft(stereo[:, ch], size) * np.fft.rfft(ir, size), size)[: len(stereo)]
        out[:, ch] = stereo[:, ch] * (1 - mix) + wet * mix
    return out


def pingpong(stereo, delay, feedback=0.4, mix=0.3, taps=6):
    out = stereo.copy()
    d = int(delay * SR)
    for k in range(1, taps + 1):
        g = mix * feedback ** (k - 1)
        src = stereo.sum(axis=1) * 0.5
        ch = k % 2
        if d * k < len(out):
            out[d * k:, ch] += src[: len(out) - d * k] * g
    return out


def stereo(x):
    return np.stack([x, x], axis=1)


# MARK: The arrangement

CHORDS = {  # pad voicing (midi), bass root (midi, octave 2), arpeggio tones (midi)
    "Dm":  ([50, 53, 57, 64], 38, [62, 65, 69, 72, 74, 77]),
    "Bb":  ([46, 53, 58, 62], 34, [58, 62, 65, 70, 74, 77]),
    "Gm":  ([43, 50, 55, 58, 62], 31, [55, 58, 62, 67, 70, 74]),
    "A":   ([45, 52, 57, 61, 64], 33, [57, 61, 64, 69, 73, 76]),
    "Eb":  ([51, 55, 58, 62], 39, [63, 67, 70, 74, 75, 79]),
    "C":   ([48, 55, 60, 64], 36, [60, 64, 67, 72, 76, 79]),
    "D":   ([50, 54, 57, 62, 66], 38, [62, 66, 69, 74, 78, 81]),
}
BARS = ["Dm", "Dm", "Bb", "Gm", "A", "Dm", "Bb", "Gm", "A", "Dm", "Bb", "Gm", "Eb", "C", "Dm", "Bb", "A", "D", "D"]
FULL = {5, 6, 7, 8, 9, 10, 11, 15}         # four on the floor, claps, sixteenth hats
HALF = {12, 13}                            # 2D: half-time
LIGHT = {2, 3}                             # the device comes in: kick on 1 (and 3)
BASS_PULSE = set(range(2, 17)) - {4}       # gated sixteenth bass
ARP = set(range(1, 17))


def arp_cutoff(time):
    """The arpeggio's filter: closed under the title, opening as the device comes in, wide
    after the impact, narrowed for Section only."""
    keys = [(0, 380), (T(1), 420), (T(2), 900), (T(4), 1400), (T(5) - 0.01, 4200), (T(5), 3200), (T(7), 4200), (T(9), 5200),
            (T(12), 2600), (T(14), 1500), (T(15), 4200), (T(16), 5200), (T(17), 3000), (tl.TOTAL, 2000)]
    xs, ys = zip(*keys)
    return float(np.exp(np.interp(time, xs, np.log(ys))))


def kick_times():
    out = []
    for b in range(tl.BARS):
        if b in FULL:
            out += [T(b, k) for k in range(4)]
        elif b in HALF:
            out += [T(b, 0), T(b, 2.5)]
        elif b in LIGHT:
            out += [T(b, 0)] + ([T(b, 2)] if b == 3 else [])
        elif b == 4:
            out += [T(4, 0)]
        elif b == 16:
            out += [T(16, 0), T(16, 1), T(16, 2)]
    return out


def sidechain(kicks, depth=0.75, release=0.16):
    t = np.arange(N) / SR
    g = np.ones(N)
    for k in kicks:
        i = int(k * SR)
        n = min(int(0.45 * SR), N - i)
        if n <= 0:
            continue
        tt = np.arange(n) / SR
        duck = 1 - depth * np.exp(-tt / release) * np.minimum(tt / 0.004, 1) ** 0.3
        g[i:i + n] = np.minimum(g[i:i + n], duck)
    return g


def pad_layer():
    buf = np.zeros((N, 2))
    for b, name in enumerate(BARS):
        notes = CHORDS[name][0]
        start = T(b)
        dur = tl.BAR + 0.05
        if b >= 17:  # the last chord rings to the end
            if b == 18:
                continue
            dur = tl.TOTAL - start
        bright = 0.35 if b < 2 else (0.55 if b < 5 else (0.8 if b not in (14,) else 0.45))
        for k, m in enumerate(notes):
            t = secs(dur + 1.2)
            v = np.zeros_like(t)
            for det, ph in [(-0.11, 0.0), (0.0, 1.7), (0.09, 3.1)]:
                v += saw(hz(m) * 2 ** (det / 12), t, ph)
            cut = 500 + 2200 * bright
            v = fft_filter(v, lp(cut, 2))
            e = env(int(dur * SR), 0.4 if b == 0 else 0.12, 0.4, 0.8, 1.2)[: len(v)]
            place(buf, start, v * e / 3, 0.075, pan=(k - len(notes) / 2) * 0.3)
    return buf


def arp_layer():
    """Sixteenth pulse arpeggio, up and down over the chord, ping-pong delay on dotted eighths."""
    buf = np.zeros((N, 2))
    step = tl.BEAT / 4
    pattern = [0, 2, 4, 1, 3, 5, 2, 4, 0, 3, 5, 1, 4, 2, 5, 3]
    for b in sorted(ARP):
        tones = CHORDS[BARS[b]][2]
        for k in range(16):
            when = T(b) + k * step
            if b == 14 and k % 2:  # Section only: thinned
                continue
            m = tones[pattern[k] % len(tones)]
            if b in (12, 13) and k % 4 == 3:
                m += 12
            t = secs(step * 1.6)
            width = 0.25 + 0.15 * np.sin(2 * np.pi * when / (tl.BAR * 4))
            v = pulse(hz(m), t, width)
            c = arp_cutoff(when)
            # Filter envelope: a bright attack falling to the cutoff, mixed from two filtered copies.
            bright = fft_filter(v, resonant_lp(min(c * 2.6, 15000), 2.5))
            dark = fft_filter(v, resonant_lp(c, 2.5))
            fe = np.exp(-t / 0.035)
            v = bright * fe + dark * (1 - fe)
            a = np.minimum(t / 0.002, 1) * np.exp(-t / (step * 0.55))
            accent = 1.0 if k % 4 == 0 else 0.72
            gain = 0.16 if b > 1 else 0.16 * (0.35 + 0.65 * k / 16)
            place(buf, when, v * a, gain * accent, pan=0.4 * np.sin(k * 1.9))
    return pingpong(buf, tl.BEAT * 0.75, feedback=0.45, mix=0.28)


def bass_layer():
    """Gated bass: a filtered saw on sixteenths (rests on the beat where the kick hits), with a
    pure sub under it."""
    buf = np.zeros((N, 2))
    step = tl.BEAT / 4
    for b in sorted(BASS_PULSE):
        root = CHORDS[BARS[b]][1]
        for k in range(16):
            when = T(b) + k * step
            if b in FULL and k % 4 == 0:
                continue
            if b in (2, 3) and k % 2:
                continue
            t = secs(step * 0.9)
            v = saw(hz(root), t) + 0.6 * pulse(hz(root + 12), t, 0.4) * (0.35 if b in FULL else 0.15)
            cut = 260 + (500 if b in FULL else 200) * (1 if k % 2 == 0 else 0.6)
            v = fft_filter(v, resonant_lp(cut, 1.8))
            a = np.minimum(t / 0.003, 1) * np.minimum((step * 0.9 - t) / 0.01, 1)
            place(buf, when, v * a, 0.2)
    # Sub: a sine on the root, held through each bar from bar 2 (the swell in bars 0–1).
    for b, name in enumerate(BARS):
        root = CHORDS[name][1] - 12
        dur = tl.BAR if b < 17 else (tl.TOTAL - T(b))
        if b == 18:
            continue
        t = secs(dur + 0.3)
        v = np.sin(2 * np.pi * hz(root) * t)
        if b < 2:
            a = np.minimum(t / tl.BAR, 1) ** 2 * (0.5 if b == 0 else 1.0)
        else:
            a = np.minimum(t / 0.01, 1) * np.minimum((dur + 0.3 - t) / 0.3, 1)
        if b == 4:
            a *= np.maximum(1 - t / (tl.BAR * 0.9), 0)  # out for the riser
        place(buf, T(b), v * a, 0.085 if b not in (14,) else 0.07)
    return buf


def kick(strength=1.0):
    t = secs(0.5)
    f = 54 + 120 * np.exp(-t / 0.03)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.15)
    click = fft_filter(RNG.standard_normal(len(t)), bp(1500, 7000)) * np.exp(-t / 0.004) * 0.25
    return np.tanh((body + click) * 1.6) * strength


def clap():
    t = secs(0.4)
    noise = fft_filter(RNG.standard_normal(len(t)), bp(900, 6000))
    e = np.zeros_like(t)
    for off in (0.0, 0.011, 0.022):
        tt = np.maximum(t - off, 0)
        e += (t >= off) * np.exp(-tt / (0.012 if off < 0.02 else 0.12))
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05) * 0.4
    return noise * e * 0.45 + tone


def hat(open_=False):
    t = secs(0.25 if open_ else 0.06)
    v = fft_filter(RNG.standard_normal(len(t)), hp(7000, 3))
    return v * np.exp(-t / (0.08 if open_ else 0.012)) * 0.35


def tick():
    t = secs(0.03)
    return np.sin(2 * np.pi * 3200 * t) * np.exp(-t / 0.006) * 0.3


def drums():
    buf = np.zeros((N, 2))
    for k in kick_times():
        bar = int(k / tl.BAR + 1e-6)
        place(buf, k, kick(1.0 if bar in FULL | {16} else 0.75), 0.42)
    s16 = tl.BEAT / 4
    for b in range(tl.BARS):
        if b in FULL or b == 16:
            for beat in (1, 3):
                if b == 16 and beat == 3:
                    continue
                place(buf, T(b, beat), clap(), 0.32, pan=0.05)
            for k in range(16):
                if b == 16 and k >= 8:
                    break
                place(buf, T(b) + k * s16, hat(open_=(k % 4 == 2)), 0.27 if k % 2 else 0.16, pan=0.3)
        elif b in HALF:
            place(buf, T(b, 2), clap(), 0.32)
            for k in range(8):
                place(buf, T(b) + k * 2 * s16 + s16, hat(), 0.16, pan=0.3)
        elif b in (2, 3):
            for k in range(4):
                place(buf, T(b, k + 0.5), hat(), 0.12, pan=0.3)
        elif b == 14:
            for k in range(16):
                place(buf, T(b) + k * s16, tick(), 0.12 if k % 4 else 0.2, pan=0.35 * np.sin(k))
        elif b == 1:
            for k in range(4):
                place(buf, T(b, k), tick(), 0.1, pan=0.2)
    # Rolls: into the impact (bar 4, eighths then sixteenths) and into the end (bar 16 b2–b4).
    for k in range(8):
        place(buf, T(4, 2) + k * s16, clap(), 0.05 + 0.03 * k, pan=-0.1)
    for k in range(4):
        place(buf, T(4, 0) + k * 2 * s16, clap(), 0.05, pan=-0.1)
    for k in range(8):
        place(buf, T(16, 2) + k * s16, clap(), 0.06 + 0.035 * k, pan=0.1)
    for k in range(4):
        place(buf, T(13, 3) + k * s16, clap(), 0.06 + 0.04 * k)
    return buf


def riser(start, length, lo=300, hi=9000, gain=0.12):
    n = int(length * SR)
    x = RNG.standard_normal(n)
    y = stft_filter(x, lambda tt: (lo * (hi / lo) ** min(max(tt / length, 0), 1) * 0.6,
                                   lo * (hi / lo) ** min(max(tt / length, 0), 1) * 1.6), kind="bp")
    t = np.arange(n) / SR
    a = (t / length) ** 2.2
    pitch = np.sin(2 * np.pi * np.cumsum(220 * 2 ** (2.5 * t / length)) / SR) * (t / length) ** 3 * 0.25
    return stereo(y * a * gain + pitch * gain)


def reverse_swell(end, length=tl.BEAT, gain=0.25):
    n = int(length * SR)
    t = np.arange(n) / SR
    v = fft_filter(RNG.standard_normal(n), bp(500, 9000)) * np.exp(-t / 0.25)
    v = v[::-1]
    return end - length, stereo(v * gain)


def impact(big=True, crash_level=1.0):
    t = secs(3.2)
    f = 26 + 70 * np.exp(-t / 0.18)
    boom = np.tanh(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (0.9 if big else 0.4)) * 2.2)
    crash = fft_filter(RNG.standard_normal(len(t)), hp(2500, 2)) * np.exp(-t / (1.2 if big else 0.5)) * 0.35 * crash_level
    metal = sum(np.sin(2 * np.pi * f0 * t + p) * np.exp(-t / d) * a for f0, a, d, p in
                [(311.0, 0.2, 0.9, 0), (467.3, 0.15, 0.7, 1), (742.1, 0.1, 0.5, 2), (1213.0, 0.07, 0.35, 3)])
    out = np.stack([boom * 0.55 + crash * 1.0 + metal * 1.2, boom * 0.55 + crash * 1.2 + metal * 1.1], axis=1)
    return out if big else out * 0.7


def scanner(start, length, offsets):
    """Bars 7–8: a band of noise sweeping with the cut's offset, chopped on 32nds, and data blips."""
    n = int(length * SR)
    t = np.arange(n) / SR
    centre = lambda tt: 500 * 2 ** (np.interp(tt, *offsets) / 18 * 3.2)
    y = stft_filter(RNG.standard_normal(n), lambda tt: (centre(tt) * 0.8, centre(tt) * 1.25), kind="bp")
    s32 = tl.BEAT / 8
    gate = ((t / s32).astype(int) % 2 == 0) * 0.7 + 0.3
    gate = np.convolve(gate, np.ones(96) / 96, mode="same")
    out = stereo(y * gate * 0.5)
    rng = np.random.default_rng(77)
    for k in range(int(length / (tl.BEAT / 4))):
        if rng.random() < 0.55:
            f0 = rng.choice([1760, 2349, 2637, 3136, 3520, 4186])
            bt = secs(0.045)
            blip = np.sign(np.sin(2 * np.pi * f0 * bt)) * np.exp(-bt / 0.012) * 0.12
            place(out, k * tl.BEAT / 4, blip, 1.0, pan=rng.uniform(-0.7, 0.7))
    return out


def glide(start, length, cents):
    """Bars 9–10: a tone rising with the grip's angle (fifth above D, sliding up)."""
    n = int(length * SR)
    t = np.arange(n) / SR
    f = hz(69) * 2 ** (np.interp(t, *cents) / 1200)
    v = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.3 * np.sin(4 * np.pi * np.cumsum(f) / SR)
    a = np.minimum(t / 0.1, 1) * np.minimum((length - t) / 0.4, 1)
    return stereo(v * a * 0.06)


def bell(m, dur=3.0):
    t = secs(dur)
    v = sum(a * np.sin(2 * np.pi * hz(m) * r * t) * np.exp(-t / d) for r, a, d in
            [(1, 1.0, 1.2), (2.0, 0.3, 0.8), (3.01, 0.15, 0.5), (4.2, 0.08, 0.3)])
    return v * np.minimum(t / 0.002, 1) * 0.3


def blip(f0=2400):
    t = secs(0.08)
    return np.sin(2 * np.pi * f0 * t * (1 + 0.6 * np.exp(-t / 0.01))) * np.exp(-t / 0.02) * 0.4


def effects():
    buf = np.zeros((N, 2))
    # Bar 0–1: a faint scanning texture under the title.
    n = int(T(2) * SR)
    t = np.arange(n) / SR
    tex = stft_filter(RNG.standard_normal(n), lambda tt: (1800 + 900 * np.sin(tt * 1.3), 2600 + 900 * np.sin(tt * 1.3)), kind="bp")
    place(buf, 0, stereo(tex * np.minimum(t / 1.5, 1) * 0.05))
    # Bar 1: a soft low hit as the title's headline lands, a reversed swell into it.
    s, sig = reverse_swell(T(1), tl.BEAT, 0.12)
    place(buf, s, sig)
    place(buf, T(1), impact(False), 0.22)
    # Bar 4: the riser and a reversed swell into the impact.
    place(buf, T(4), riser(T(4), tl.BAR))
    s, sig = reverse_swell(T(5), tl.BEAT * 2, 0.3)
    place(buf, s, sig)
    place(buf, T(5), impact(True), 0.7)
    # Bars 7–8: the scanner follows the arrow (0 → 18 mm by bar 8, back to 0 by bar 8 beat 3).
    offs = ([0, tl.BEAT, T(8) - T(7), T(8, 3) - T(7), 2 * tl.BAR], [0, 0, 18, 0, 0])
    place(buf, T(7), scanner(T(7), 2 * tl.BAR, offs), 0.55)
    # Bars 9–10: the glide rises with the tilt (0 → 30° from bar 9 beat 1 to beat 3.5).
    place(buf, T(9), glide(T(9), 2 * tl.BAR, ([0, tl.BEAT, tl.BEAT * 3.5, 2 * tl.BAR], [0, 0, 700, 700])), 1.0)
    # Small actions: a blip on the beat they land on.
    for bar, beat, f0 in [(3, 2, 2200), (7, 0, 1800), (9, 0, 1800), (11, 2, 2600), (14, 0, 3000), (15, 0, 2200), (16, 0, 1600)]:
        place(buf, T(bar, beat), blip(f0), 0.18, pan=0.1)
    # Bar 11: a reversed hit into the flip.
    s, sig = reverse_swell(T(11), tl.BEAT, 0.22)
    place(buf, s, sig)
    place(buf, T(11), impact(False), 0.35)
    # Bar 12: 2D — a crystalline hit, bells on the half bars of the lift.
    s, sig = reverse_swell(T(12), tl.BEAT, 0.2)
    place(buf, s, sig)
    for k, m in enumerate([86, 91, 94]):
        place(buf, T(12) + k * 0.03, bell(m, 2.5), 0.16, pan=-0.3 + 0.3 * k)
    for bar in (12, 13):
        for beat, m in [(0, 79), (1.5, 86), (2.5, 84), (3.5, 91)]:
            place(buf, T(bar, beat), bell(m if bar == 12 else m - 3, 1.6), 0.07, pan=0.4 * np.sin(beat * 2))
    # Bar 14: Section only — a gate hit.
    place(buf, T(14), impact(False)[:, :] * 0.6, 0.3)
    # Bar 15: back to 3D.
    s, sig = reverse_swell(T(15), tl.BEAT, 0.18)
    place(buf, s, sig)
    # Bar 16 → 17: riser into the end card, then the resolution.
    place(buf, T(16, 2), riser(T(16, 2), tl.BEAT * 2, 600, 9000, 0.1))
    s, sig = reverse_swell(T(17), tl.BEAT * 1.5, 0.3)
    place(buf, s, sig)
    place(buf, T(17), impact(True, crash_level=0.4), 0.55)
    for k, m in enumerate([74, 78, 81, 86, 90]):
        place(buf, T(17) + k * tl.BEAT / 2, bell(m, 4.0), 0.12, pan=-0.4 + 0.2 * k)
    return buf


def master(mix):
    # Gentle glue: soft clip, then fade the last bar and a half to silence.
    mix = np.tanh(mix * 1.1) / 1.1
    t = np.arange(N) / SR
    fade_from = tl.TOTAL - 2.6
    mix *= np.clip((tl.TOTAL - t) / (tl.TOTAL - fade_from), 0, 1)[:, None] ** 1.6
    fi = int(0.02 * SR)
    mix[:fi] *= np.linspace(0, 1, fi)[:, None]
    return mix


def render():
    kicks = kick_times()
    sc = sidechain(kicks)[:, None]
    pad = reverb(pad_layer(), 3.2, 0.45, seed=5) * sc
    arp = reverb(arp_layer(), 2.0, 0.22, seed=6) * (0.5 + 0.5 * sc)
    bass = bass_layer() * sidechain(kicks, 0.9, 0.12)[:, None]
    dr = reverb(drums(), 1.2, 0.12, seed=7)
    fx = reverb(effects(), 2.8, 0.3, seed=8)
    mix = pad * 1.0 + arp * 1.0 + bass * 1.0 + dr * 1.0 + fx * 1.0
    mix = mix - mix.mean(axis=0)
    mix = np.stack([fft_filter(mix[:, ch], hp(30, 3)) for ch in range(2)], axis=1)
    return master(mix), dict(pad=pad, arp=arp, bass=bass, drums=dr, fx=fx)


def write_wav(path, x):
    x = np.clip(x, -1, 1)
    pcm = (x * 8388607).astype("<i4")
    b = pcm.view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(SR)
        w.writeframes(b)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "build/video/section/audio")
    os.makedirs(out, exist_ok=True)
    mix, stems = render()
    peak = float(np.max(np.abs(mix)))
    mix *= 0.7 / peak  # headroom; loudness is set when it's mastered in build.py
    write_wav(os.path.join(out, "music.wav"), mix)
    # The hits on their own (drums and effects), for beatcheck.py to find in the film's audio.
    write_wav(os.path.join(out, "hits.wav"), (stems["drums"] + stems["fx"]) * 0.7 / peak)
    json.dump(dict(bpm=tl.BPM, bars=tl.BARS, total=tl.TOTAL, chords=BARS, kicks=[round(k, 4) for k in kick_times()],
                   peak_before_gain=peak), open(os.path.join(out, "music.json"), "w"), indent=1)
    print(f"music {tl.TOTAL:.3f} s, {tl.BPM} bpm, peak {peak:.3f} -> {out}/music.wav")
