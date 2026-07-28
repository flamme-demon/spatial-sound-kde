#!/usr/bin/env python3
"""Mesure reverb et coloration de chaque profil HRIR HeSuVi installe."""
import os

import numpy as np
from scipy.io import wavfile

HR = os.path.expanduser(
    os.environ.get("XDG_DATA_HOME", "~/.local/share") + "/pipewire/hrir_hesuvi")
CANDIDATS = ["atmos", "cmss_game", "cmss_ent", "dh+", "dh++", "gsx", "gsx+", "dtshx",
             "dvs", "sbx33", "sbx67", "ssc_ny", "ssc_dub", "ssc_syd", "EAC_Default",
             "nahimic", "ooyh1", "razer_fix", "sonic", "hear"]


def decay_ms(h, sr):
    """Duree pendant laquelle l'energie reste au-dessus de -40 dB : proxy de reverb."""
    e = h.astype(float) ** 2
    c = np.cumsum(e[::-1])[::-1]          # courbe de Schroeder
    c /= c[0] + 1e-20
    db = 10 * np.log10(c + 1e-20)
    idx = np.argmax(db < -40)
    return (idx if idx else len(h)) / sr * 1000


def lateralisation(d):
    """Verifie que l'oreille du cote de la source recoit bien plus d'energie.

    Canaux HeSuVi : 4=RL->L, 5=RL->R, 11=RR->R, 12=RR->L.
    Renvoie (ecart RL, ecart RR) en dB, positifs si le profil est correct.
    Un profil dont un ecart est <= 0 ne lateralise pas : il est inexploitable,
    meme s'il parait neutre sur le canal frontal.
    """
    def rms(x):
        return np.sqrt(np.mean(x.astype(float) ** 2)) + 1e-20
    ild_rl = 20 * np.log10(rms(d[:, 4]) / rms(d[:, 5]))
    ild_rr = 20 * np.log10(rms(d[:, 11]) / rms(d[:, 12]))
    return ild_rl, ild_rr


def coloration_db(h, sr):
    """Ecart crete-a-crete de la reponse lissee entre 200 Hz et 8 kHz."""
    n = max(4096, len(h))
    H = np.abs(np.fft.rfft(h, n))
    f = np.fft.rfftfreq(n, 1 / sr)
    band = (f > 200) & (f < 8000)
    mag = 20 * np.log10(H[band] + 1e-12)
    # lissage 1/6 d'octave approx : moyenne glissante en echelle log
    k = max(3, len(mag) // 120)
    sm = np.convolve(mag, np.ones(k) / k, mode="valid")
    return sm.max() - sm.min()


rows = []
for nom in CANDIDATS:
    p = f"{HR}/{nom}.wav"
    if not os.path.exists(p):
        continue
    sr, raw = wavfile.read(p)
    d = np.atleast_2d(np.asarray(raw))
    if d.shape[1] != 14:   # seuls les WAV HeSuVi 14 canaux nous interessent
        continue
    # Un fichier porteur de NaN ou de valeurs hors bornes produirait des mesures
    # « nan » silencieuses. Mieux vaut le nommer : convolue, il enverrait des
    # salves tres fortes dans le casque.
    brut = d.astype(np.float64)
    if not np.isfinite(brut).all() or np.abs(brut[np.isfinite(brut)]).max() > 8.0 * (
        1 if np.issubdtype(d.dtype, np.floating) else np.iinfo(d.dtype).max
    ):
        print(f"{nom:<14}  FICHIER CORROMPU — valeurs non finies ou hors bornes")
        continue
    d = d.astype(float) / 32768
    # canal 6 = FC vers oreille gauche : la source frontale, la plus revelatrice
    fc = d[:, 6]
    ild_rl, ild_rr = lateralisation(d)
    rows.append((nom, decay_ms(fc, sr), coloration_db(fc, sr), ild_rl, ild_rr))

# On trie par reverb croissante, mais les profils non lateralisants sont relegues :
# un profil qui ne place pas la gauche a gauche ne sert a rien, quelle que soit
# sa reverb ou sa neutralite.
# En dessous de 3 dB d'ecart interaural, la difference est trop faible pour etre
# exploitee a l'ecoute : le profil ne place plus les sons, on le relegue en bas.
SEUIL_LAT = 3.0
rows.sort(key=lambda r: (min(r[3], r[4]) < SEUIL_LAT, r[1]))

print(f"{'profil':<14}{'reverb':>9}{'coloration':>12}{'lat. G':>9}{'lat. D':>9}   verdict")
print("-" * 70)
for nom, dec, col, ild_rl, ild_rr in rows:
    if min(ild_rl, ild_rr) < SEUIL_LAT:
        verdict = "A EVITER (ne lateralise pas)"
    elif dec < 45 and min(ild_rl, ild_rr) > 8:
        verdict = "bon en jeu"
    elif dec > 60:
        verdict = "salle marquee (cinema)"
    else:
        verdict = "correct"
    print(f"{nom:<14}{dec:>7.0f}ms{col:>10.1f}dB{ild_rl:>+8.1f}dB{ild_rr:>+8.1f}dB   {verdict}")
