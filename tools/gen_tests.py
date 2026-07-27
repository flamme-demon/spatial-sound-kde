#!/usr/bin/env python3
"""Genere des WAV 7.1 de test de localisation pour le sink binaural."""
import numpy as np
from scipy.io import wavfile

SR = 48000
# ordre WAVE 7.1 = FL FR FC LFE BL BR SL SR
FL, FR, FC, LFE, BL, BR, SL, SR_ = range(8)


def pink(n, rng):
    """Bruit rose : bien plus localisable qu'un sinus (transitoires + large bande)."""
    w = rng.standard_normal(n)
    f = np.fft.rfft(w)
    freqs = np.fft.rfftfreq(n, 1 / SR)
    freqs[0] = freqs[1]
    f /= np.sqrt(freqs)
    out = np.fft.irfft(f, n)
    return out / np.max(np.abs(out) + 1e-12)


def bursts(sig, rate=4.0):
    """Module en salves courtes : les attaques donnent les indices temporels (ITD)."""
    t = np.arange(len(sig)) / SR
    env = (np.sin(2 * np.pi * rate * t) > 0.3).astype(float)
    # adoucit les fronts pour eviter les clics
    k = np.hanning(int(SR * 0.006))
    k /= k.sum()
    return sig * np.convolve(env, k, mode="same")


def ramp(n, lo, hi):
    return np.linspace(lo, hi, n)


def build_sweep(duration=12.0, seed=1):
    """Avant -> cotes -> arriere -> cotes -> avant, en continu."""
    rng = np.random.default_rng(seed)
    n = int(SR * duration)
    src = bursts(pink(n, rng))
    out = np.zeros((n, 8))

    # position 0 = plein avant, 1 = plein arriere, aller-retour
    pos = np.concatenate([ramp(n // 2, 0, 1), ramp(n - n // 2, 1, 0)])

    # gains en loi de puissance constante sur 3 paires : avant / cotes / arriere
    g_front = np.clip(1 - 2 * pos, 0, 1)
    g_side = 1 - np.abs(2 * pos - 1)
    g_rear = np.clip(2 * pos - 1, 0, 1)
    norm = np.sqrt(g_front**2 + g_side**2 + g_rear**2) + 1e-9
    g_front, g_side, g_rear = g_front / norm, g_side / norm, g_rear / norm

    out[:, FC] = src * g_front
    out[:, SL] = src * g_side * 0.707
    out[:, SR_] = src * g_side * 0.707
    out[:, BL] = src * g_rear * 0.707
    out[:, BR] = src * g_rear * 0.707
    return out


def build_circle(seed=2):
    """Une salve isolee par enceinte, dans le sens horaire."""
    rng = np.random.default_rng(seed)
    order = [(FC, "avant centre"), (FR, "avant droit"), (SR_, "cote droit"),
             (BR, "arriere droit"), (BL, "arriere gauche"), (SL, "cote gauche"),
             (FL, "avant gauche")]
    seg = int(SR * 1.4)
    gap = int(SR * 0.35)
    out = np.zeros(((seg + gap) * len(order), 8))
    for i, (ch, _) in enumerate(order):
        s = bursts(pink(seg, rng), rate=3.0)
        start = i * (seg + gap)
        out[start:start + seg, ch] = s
    return out, order


def write(path, data, peak=0.35):
    data = data / (np.max(np.abs(data)) + 1e-9) * peak
    wavfile.write(path, SR, (data * 32767).astype(np.int16))
    print(f"{path}  {data.shape[1]} canaux  {data.shape[0]/SR:.1f}s")


sweep = build_sweep()
write("test_avant_arriere.wav", sweep)

circ, order = build_circle()
write("test_cercle.wav", circ)
print("\nOrdre du tour du cercle :")
for i, (_, nom) in enumerate(order, 1):
    print(f"  {i}. {nom}")
