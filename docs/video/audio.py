#!/usr/bin/env python3
"""Original music bed and sound effects for the announcement, synthesised with numpy.

    python3 docs/video/audio.py OUT_DIR   ->  OUT_DIR/music.wav, OUT_DIR/sfx.wav (48 kHz stereo, float)

Music: a calm D-major progression (D, Bm, G, A) on a soft pad, a piano-like pluck
arpeggio from the moment the iPad comes in, a sub bass, and a gentle pulse that
builds into the hero moment (the plate widening on the timeline), lands on the
tonic there, thins out for the print check and export, and resolves G -> D on the
end card under a chime. The bar length is chosen so a downbeat falls exactly on the
hero moment and another on the end card.

Effects: soft ticks for taps, Pencil touches, snaps and caliper detents; a gentle
whoosh on camera swings; a pencil-on-paper texture under the opening drawing; a
two-partial chime on the end card. Event times come from edit.py.
"""
import json, os, sys, wave
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import edit

SR = 48000
RNG = np.random.default_rng(7)


def note_hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def env_adsr(n, a, d, s, r, sr=SR):
    """Attack/decay/sustain over n samples, then an exponential-ish release tail appended."""
    a, d, r = int(a * sr), int(d * sr), int(r * sr)
    e = np.full(n + r, s, float)
    a = max(a, 1)
    e[:a] = np.linspace(0, 1, a) ** 1.5
    if d > 0:
        e[a:a + d] = np.linspace(1, s, min(d, len(e) - a))[: max(0, min(d, len(e) - a))]
    e[n:] = s * np.exp(-np.linspace(0, 6, r)) if r > 0 else e[n:]
    return e


def one_pole_lp(x, cutoff):
    """Simple one-pole low-pass; cutoff may be a scalar or a per-sample array."""
    c = np.broadcast_to(np.asarray(cutoff, float), x.shape)
    k = 1 - np.exp(-2 * np.pi * c / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):  # fine for the short sounds this is used on
        acc += k[i] * (x[i] - acc)
        y[i] = acc
    return y


def fft_lowpass(x, cutoff, slope=6.0):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / np.sqrt(1 + (f / cutoff) ** slope)
    return np.fft.irfft(X, len(x))


def fft_bandpass(x, lo, hi):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= (1 / np.sqrt(1 + (lo / np.maximum(f, 1)) ** 4)) * (1 / np.sqrt(1 + (f / hi) ** 4))
    return np.fft.irfft(X, len(x))


def add(buf, start, sig, gain=1.0, pan=0.0):
    """Mixes a mono or stereo signal into a stereo buffer at `start` seconds."""
    i = int(round(start * SR))
    if i >= buf.shape[0]:
        return
    if sig.ndim == 1:
        l, r = np.sqrt(0.5 * (1 - pan)), np.sqrt(0.5 * (1 + pan))
        sig = np.stack([sig * l * 1.414, sig * r * 1.414], axis=1)
    j = min(buf.shape[0], i + len(sig))
    if i < 0:
        sig, i = sig[-i:], 0
    buf[i:j] += sig[: j - i] * gain


def reverb(stereo, seconds=2.6, mix=0.28, predelay=0.02):
    """Convolution with decaying, low-passed stereo noise (a soft plate)."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.empty_like(stereo)
    for ch in range(2):
        ir = RNG.standard_normal(n) * np.exp(-t * 6.9 / seconds)
        ir = fft_lowpass(ir, 5200)
        ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
        ir /= np.sqrt(np.sum(ir ** 2))
        size = 1 << int(np.ceil(np.log2(len(stereo) + len(ir))))
        wet = np.fft.irfft(np.fft.rfft(stereo[:, ch], size) * np.fft.rfft(ir, size), size)[: len(stereo)]
        out[:, ch] = stereo[:, ch] * (1 - mix) + wet * mix * 0.9
    return out


# MARK: Instruments

def pad_voice(freq, dur, bright=1.0):
    n = int(dur * SR)
    t = np.arange(n + int(1.6 * SR)) / SR
    sig = np.zeros_like(t)
    for detune, ph in [(-0.07, 0.0), (0.0, 1.3), (0.06, 2.1)]:
        f = freq * 2 ** (detune / 12)
        # Soft saw from a few partials.
        for h in range(1, 7):
            sig += np.sin(2 * np.pi * f * h * t + ph * h) / h ** (1.6 - 0.25 * bright)
    sig = fft_lowpass(sig, 900 + 1300 * bright, slope=4)
    e = env_adsr(n, 0.9, 0.6, 0.75, 1.6)[: len(sig)]
    return sig * e / 6


def pluck(freq, dur=1.4, bright=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for h, a in [(1, 1.0), (2, 0.45 * bright), (3, 0.18 * bright), (4, 0.08 * bright), (5, 0.04)]:
        sig += a * np.sin(2 * np.pi * freq * h * (1 + 0.0007 * h * h) * t) * np.exp(-t * (2.6 + 1.6 * h))
    attack = np.minimum(t / 0.004, 1)
    hammer = RNG.standard_normal(n) * np.exp(-t * 300) * 0.05
    return (sig * attack + hammer) * 0.5


def bass(freq, dur):
    n = int(dur * SR)
    t = np.arange(n + int(0.4 * SR)) / SR
    sig = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * freq * 2 * t)
    return sig * env_adsr(n, 0.05, 0.3, 0.7, 0.4)[: len(sig)] * 0.55


def pulse(strength=1.0):
    n = int(0.32 * SR)
    t = np.arange(n) / SR
    f = 52 + 70 * np.exp(-t * 30)
    sig = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 11)
    return sig * strength * 0.7


def shaker(strength=1.0):
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    sig = fft_bandpass(RNG.standard_normal(n), 5000, 11000) * np.exp(-t * 55)
    return sig * 0.12 * strength


def bell(freq, dur=3.2):
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for ratio, amp, decay in [(1, 1.0, 1.4), (2.76, 0.35, 3.0), (5.4, 0.12, 5.5), (2.0, 0.2, 2.2)]:
        sig += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t * decay)
    return sig * np.minimum(t / 0.003, 1) * 0.35


# MARK: Music

CHORDS = {  # midi notes: pad voicing, bass root
    "D": ([50, 57, 61, 64, 66], 38),   # D A C# E F#  (Dmaj9)
    "Bm": ([47, 54, 57, 61, 62], 35),  # B F# A C# D  (Bm9-ish)
    "G": ([43, 50, 54, 57, 62], 31),   # G D F# A D   (Gmaj9)
    "A": ([45, 52, 57, 62, 64], 33),   # A E A D E    (Asus4)
}
LOOP = ["D", "Bm", "G", "A"]
ARP = {  # pluck arpeggio notes per chord (an octave up)
    "D": [62, 66, 69, 73, 74, 73, 69, 66],
    "Bm": [59, 62, 66, 69, 71, 69, 66, 62],
    "G": [55, 59, 62, 66, 69, 66, 62, 59],
    "A": [57, 62, 64, 69, 71, 69, 64, 62],
}


def music(cues):
    total = cues["total"] + 0.5
    buf = np.zeros((int(total * SR), 2))
    hero, end = cues["hero"], cues["end_card"]
    bars = max(round((end - hero) / 2.55), 1)
    L = (end - hero) / bars           # bar length: downbeats on the hero and on the end card
    beat = L / 4
    first = hero - L * np.ceil(hero / L)  # grid start (<= 0)
    bar_starts = [first + i * L for i in range(int((end - first) / L) + 1)]
    h = int(round((hero - first) / L))
    log = {"bar": round(L, 3), "bpm": round(60 / beat, 2), "first_downbeat": round(first, 3)}

    for i, s in enumerate(bar_starts):
        if s >= end - 1e-6:
            break
        name = LOOP[(i - h) % 4]
        if i == h + bars - 1:
            name = "G"  # plagal G -> D into the end card
        notes, root = CHORDS[name]
        t0 = max(s, 0)
        dur = s + L - t0 + 0.05
        # Pad: from the start, fuller after the iPad comes in; brightest at the hero.
        bright = 0.5 if s < cues["device_in"] else (1.0 if cues["build"] <= s < cues["settle"] else 0.75)
        pad_gain = 0.16 if s < cues["device_in"] - L else 0.2
        for k, m in enumerate(notes):
            add(buf, t0, pad_voice(note_hz(m), dur, bright), pad_gain * (0.9 if k else 1.0), pan=(k - 2) * 0.22)
        if i == h:
            # The hero lands: the tonic an octave up, held.
            for m in [74, 78, 81]:
                add(buf, s, pad_voice(note_hz(m), L * 2, 1.0), 0.06, pan=0.3)
        # Bass from a couple of bars after the iPad enters.
        if s >= cues["device_in"] + L * 0.5:
            add(buf, s, bass(note_hz(root + (12 if root < 36 else 0)), L * 0.95), 0.2 if s < cues["settle"] else 0.15)
        # Pluck arpeggio: eighths from the iPad's entrance, sixteenths through the build.
        if s >= cues["device_in"] - 0.01:
            dense = cues["build"] <= s < cues["settle"]
            steps = 16 if dense else 8
            pattern = ARP[name]
            for k in range(steps):
                tt = s + k * L / steps
                m = pattern[(k if not dense else k // 2 + (k % 2) * 4) % 8]
                accent = 1.0 if k % (steps // 4) == 0 else 0.7
                g = (0.11 if dense else 0.13) * accent * (0.8 if s >= cues["settle"] else 1.0)
                add(buf, tt, pluck(note_hz(m), 1.2, 0.8 if dense else 0.6), g, pan=0.35 * np.sin(k * 1.3))
        # Pulse: soft kick on beats 1 and 3 through the build and the hero; shaker on the off-beats.
        if cues["build"] - 0.01 <= s < cues["settle"]:
            for k in range(4):
                if k % 2 == 0:
                    add(buf, s + k * beat, pulse(1.0 if i >= h else 0.6), 0.5)
                add(buf, s + k * beat + beat / 2, shaker(1.0 if i >= h else 0.5), 0.7, pan=0.25)
    # Riser into the hero: filtered noise swelling over the bar before it.
    n = int(L * SR)
    t = np.arange(n) / SR
    riser = fft_bandpass(RNG.standard_normal(n), 400, 7000) * (t / (L)) ** 3 * 0.07
    add(buf, hero - L, np.stack([riser, riser[::-1] * 0 + riser], axis=1))

    # Everything before the end card fades out over 0.3 s; the final chord rings.
    fade_at = int(end * SR)
    ramp = int(0.3 * SR)
    buf[fade_at:fade_at + ramp] *= np.linspace(1, 0, ramp)[:, None]
    buf[fade_at + ramp:] = 0
    notes, root = CHORDS["D"]
    for k, m in enumerate(notes + [69, 74]):
        add(buf, end, pad_voice(note_hz(m), total - end - 1.0, 0.8), 0.17, pan=(k - 3) * 0.18)
    add(buf, end, bass(note_hz(root), total - end - 1.2), 0.18)
    for k, m in enumerate([74, 78, 81, 86]):
        add(buf, end + 0.12 * k, pluck(note_hz(m), 2.5, 0.7), 0.12, pan=-0.3 + 0.2 * k)

    buf = reverb(buf, 2.8, 0.3)
    # Fade in over the first second, out over the last 1.4 s.
    fi = int(1.0 * SR)
    buf[:fi] *= np.linspace(0, 1, fi)[:, None] ** 2
    fo = int(1.4 * SR)
    tail = int(cues["total"] * SR)
    buf[tail - fo:tail] *= np.linspace(1, 0, fo)[:, None] ** 1.5
    buf[tail:] = 0
    return buf[:tail], log


# MARK: Effects

def tick(freq, length=0.035, noise=0.25, decay=140):
    n = int(length * SR)
    t = np.arange(n) / SR
    sig = np.sin(2 * np.pi * freq * t) * np.exp(-t * decay)
    sig += fft_bandpass(RNG.standard_normal(n), 2000, 9000) * np.exp(-t * 900) * noise
    return sig * np.minimum(t / 0.0008, 1)


def whoosh(length=1.0):
    n = int(length * SR)
    t = np.arange(n) / SR
    x = RNG.standard_normal(n)
    # A band that sweeps up and back down while it swells.
    centre = 500 + 1600 * np.sin(np.pi * t / length) ** 2
    y = np.zeros(n)
    hop = 2048
    for i in range(0, n, hop):
        seg = x[i:i + hop * 2]
        if len(seg) < 16:
            break
        f = fft_bandpass(seg, centre[i] * 0.5, centre[i] * 1.8) * np.hanning(len(seg))
        y[i:i + len(seg)] += f
    e = np.sin(np.pi * np.minimum(t / length, 1)) ** 2.2
    mono = y * e * 0.22
    pan = np.linspace(-0.5, 0.5, n)
    return np.stack([mono * np.sqrt(0.5 * (1 - pan)) * 1.414, mono * np.sqrt(0.5 * (1 + pan)) * 1.414], axis=1)


def scratch(length):
    """Pencil on paper under the opening drawing."""
    n = int(length * SR)
    t = np.arange(n) / SR
    x = fft_bandpass(RNG.standard_normal(n), 1800, 6500)
    grain = 0.6 + 0.4 * np.abs(np.sin(2 * np.pi * 7.3 * t + 2 * np.sin(2 * np.pi * 1.1 * t)))
    e = np.minimum(t / 0.06, 1) * np.minimum((length - t) / 0.12, 1)
    return x * grain * e * 0.025


def sfx(events, total):
    buf = np.zeros((int((total + 0.5) * SR), 2))
    for t, kind in events:
        jitter = RNG.uniform(0.97, 1.03)
        if kind == "touch":
            add(buf, t, tick(1500 * jitter, 0.05, 0.3, 120), 0.22, pan=0.15)
        elif kind == "pencil":
            add(buf, t, tick(2600 * jitter, 0.03, 0.4, 200), 0.13, pan=-0.1)
        elif kind == "snap":
            add(buf, t, tick(3400 * jitter, 0.025, 0.15, 260), 0.12)
        elif kind == "detent":
            add(buf, t, tick(1150 * jitter, 0.04, 0.2, 160), 0.18)
        elif kind == "whoosh":
            add(buf, t - 0.1, whoosh(1.1), 0.75)
        elif kind == "chime":
            add(buf, t, bell(note_hz(86)), 0.45, pan=-0.15)
            add(buf, t + 0.09, bell(note_hz(93)), 0.3, pan=0.2)
    return buf[: int(total * SR)]


def opener_sfx(buf, slow):
    # The splash's pens draw 0.08–0.62 s and the fillet pass runs 0.54–0.9 s (splash time).
    add(buf, 0.08 * slow, scratch((0.62 - 0.08) * slow), 1.0)
    add(buf, 0.54 * slow, whoosh(0.9), 0.35)


def write_wav(path, stereo):
    data = np.clip(stereo, -1, 1)
    pcm = (data * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(edit.ROOT, "build/video/audio")
    os.makedirs(out, exist_ok=True)
    cues = edit.music_cues()
    m, log = music(cues)
    peak = np.max(np.abs(m))
    m *= 0.5 / peak  # headroom; loudness is set in the final mix
    write_wav(os.path.join(out, "music.wav"), m)
    fx = sfx(edit.sfx_events(), cues["total"])
    opener_sfx(fx, edit.OPENER_SLOW)
    write_wav(os.path.join(out, "sfx.wav"), fx)
    json.dump({"cues": cues, "music": log, "sfx": edit.sfx_events()}, open(os.path.join(out, "audio.json"), "w"), indent=1)
    print(json.dumps({"cues": cues, "music": log}, indent=1))
