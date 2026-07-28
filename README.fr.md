# Spatial Sound KDE

*[English](README.md) · **Français***

Sink virtuel **7.1 binaural** pour casque, sous PipeWire. Un équivalent libre de
*Spatial Sound Card*, *Dolby Atmos for Headphones* ou *DTS Headphone:X*, qui ne
sont pas portés sous Linux.

Le principe est le même que ces produits : un périphérique de sortie 7.1 apparaît
dans le système, chaque enceinte virtuelle est convoluée par une paire de réponses
impulsionnelles (HRIR) mesurées, et le résultat est mixé en stéréo pour le casque.

<p align="center">
  <img src="docs/applet.png" alt="L'applet Plasma listant les profils avec leurs mesures" width="380">
</p>

## Ce que ça fait concrètement

Le périphérique virtuel apparaît comme une vraie carte 7.1, avec ses huit canaux :

![Le sink 7.1 dans les réglages audio de KDE](docs/kde-audio-settings.png)

Les jeux et lecteurs vidéo voient une carte son 7.1 et lui envoient un vrai flux
multicanal. Au lieu d'un simple repli stéréo, chaque canal est placé dans l'espace
autour de la tête. Le gain principal n'est pas le gauche/droite — la stéréo le fait
déjà — mais **l'avant/arrière et l'externalisation** : le son cesse de se former à
l'intérieur du crâne.

## Prérequis

`install.sh` vérifie tout ce qui suit et s'arrête avec un message explicite si
quelque chose manque — il ne se contente pas d'afficher les versions.

| Requis | Contrôle |
|---|---|
| bash ≥ 4.0 | tableaux associatifs |
| PipeWire ≥ 0.3.60 | comparaison de version réelle (`sort -V`) |
| `module-filter-chain` | présence de la bibliothèque |
| `pactl`, `paplay`, `systemctl` | présence |
| serveur PipeWire actif | `pactl info` |

| Facultatif | Sans lui |
|---|---|
| `ffmpeg` | pas de contrôle du format des HRIR |
| `python-numpy`, `python-scipy` | pas de mesure ni de génération de tests |
| `pw-link` | vérification finale des liens ignorée |
| Plasma ≥ 6 | applet non installé, le reste fonctionne |

Le seuil de 0.3.60 n'est pas décoratif : en dessous, le module se charge et le sink
apparaît, mais le graphe reste muet — une panne silencieuse, donc pénible à
diagnostiquer. Même logique pour le contrôle 14 canaux des HRIR fournis via
`--hrir-dir`.

Testé sur Manjaro KDE. **PulseAudio classique n'est pas supporté** : l'approche
repose sur `module-filter-chain`, propre à PipeWire. Le script le détecte et
s'arrête proprement.

## Installation

```bash
./install.sh
```

Le script vérifie l'environnement, récupère les jeux de HRIR, génère la
configuration, installe `surround-profil` et l'applet, démarre le service dédié
et vérifie que le sink apparaît bien.

Options utiles :

| Option | Effet |
|---|---|
| `--profil <nom>` | profil initial (défaut : `cmss_game`) |
| `--hrir-dir <chemin>` | utilise des WAV HeSuVi locaux au lieu de télécharger |
| `--no-default-sink` | n'impose pas le sink virtuel comme sortie par défaut |
| `--no-deps` | n'installe rien via pacman |
| `-y` | ne pose aucune question (et ne recharge pas plasmashell) |

## Choisir un profil

### Depuis le bureau (KDE)

L'installation dépose un applet Plasma. Clic droit sur le panneau ou le bureau →
*Ajouter des widgets* → **Spatial Sound**. Il affiche le profil actif, la liste
groupée par usage, et les mesures en face de chaque nom. Un clic bascule.

`install.sh` rend le widget *disponible*, il ne l'ajoute pas au panneau : modifier
la disposition d'un bureau existant est une décision qui revient à l'utilisateur.

**Installer ne suffit pas à faire prendre effet.** `plasmashell` garde en mémoire le
QML et les icônes déjà chargés : une mise à jour de l'applet reste invisible tant
qu'il n'a pas été rechargé. `install.sh` le détecte, affiche depuis quand il tourne
et propose de le relancer. En mode `-y` il ne le fait pas et rappelle la commande :

```bash
kquitapp6 plasmashell && kstart plasmashell
```

### Depuis le terminal

```bash
surround-profil              # liste, avec les mesures
surround-profil cmss_game    # bascule (~0,15 s, sans couper les autres sons)
surround-profil -a           # les 59 profils disponibles
surround-profil --data       # sortie TSV, utilisée par l'applet
```

Les profils ne se valent pas, et **leur réputation ne correspond pas à leur
contenu**. `tools/analyse_hrir.py` les mesure :

| Profil | Réverb | Latéralisation | Usage |
|---|---|---|---|
| `cmss_game` | 39 ms | **+15 dB** | le meilleur compromis, défaut |
| `sonic` | 16 ms | +11 dB | très sec |
| `EAC_Default` | 3 ms | +9 dB | le plus sec (44,1 kHz) |
| `atmos` | 46 ms | +12 dB | cinéma, ample |
| `ssc_ny` / `ssc_syd` | 42 / 99 ms | +9 / +14 dB | les salles de Spatial Sound Card |
| `dh+` | 109 ms | +3 dB | très réverbérant malgré sa réputation FPS |
| `dvs` | 21 ms | **+2 dB** | à éviter — ne latéralise pas |

**Latéralisation** = écart d'énergie entre l'oreille du côté de la source et l'autre,
sur les canaux arrière. C'est le critère décisif : sous ~3 dB le profil ne place plus
rien dans l'espace, quelle que soit sa neutralité tonale par ailleurs.

**Réverb** = durée pendant laquelle l'énergie reste au-dessus de −40 dB. Plus elle
est longue, plus le son paraît lointain — agréable au cinéma, pénalisant en jeu.

Le script mesure aussi la **coloration** (écart crête-à-crête entre 200 Hz et 8 kHz).
Attention à ne pas la lire comme un critère de qualité : `dvs` affiche la coloration
la plus faible du lot (0,7 dB) précisément parce qu'il ne filtre presque rien — donc
ne latéralise pas. Une réponse trop plate est un signal d'alarme, pas un gage de
neutralité.

## Réglage de réverbération

Le curseur **Amortissement**, au pied de l'applet, raccourcit la queue de
réverbération du profil actif **sans en changer**. C'est le réglage qui manquait :
jusque-là, ajuster la distance perçue obligeait à basculer de profil, donc à
modifier en même temps la latéralisation et le timbre.

```bash
surround-profil --enveloppe 0     # profil intact
surround-profil --enveloppe 75    # nettement plus sec
surround-profil --enveloppe 100   # au plus sec
```

Mesuré sur `dh+`, le plus réverbérant des profils livrés :

| Amortissement | Réverbération | Latéralisation |
|---|---|---|
| 0 % | 109 ms | +3,4 dB |
| 50 % | 68 ms | +3,9 dB |
| 75 % | 44 ms | +4,2 dB |
| 100 % | 25 ms | +4,5 dB |

**Raccourcir la queue améliore la localisation**, jamais l'inverse : la
réverbération, décorrélée mais d'énergie égale aux deux oreilles, dilue l'écart
interaural. C'est la même mécanique qui explique pourquoi les profils secs
latéralisent mieux.

Le niveau reste constant d'un bout à l'autre du curseur, pour que la comparaison à
l'oreille reste honnête. Le profil d'origine n'est jamais modifié : le résultat est
écrit dans un fichier dérivé, et le réglage suit d'un profil à l'autre.

**On ne peut que raccourcir.** Allonger demanderait de fabriquer une réverbération
absente du matériau — c'est le travail du générateur de salles, pas de ce réglage.
Le curseur n'apparaît que si `spatial-sound-gen` a pu être compilé.

## Salles personnalisées

N'importe quel WAV **HeSuVi 14 canaux** déposé dans
`~/.local/share/pipewire/hrir_hesuvi/` devient un profil : il apparaît dans
`surround-profil -a`, dans l'applet, et se mesure avec `tools/analyse_hrir.py`.

C'est la voie pour des paramètres de salle, que ce projet n'expose pas lui-même.
[**ASH Toolset**](https://github.com/ShanonPearce/ASH-Toolset) (AGPL-3.0, testé sous
Linux) synthétise des réponses de salle à partir de paramètres — espace acoustique,
gain du son direct, jeu HRTF, cible de salle, coupure des basses — et **exporte
directement au format HeSuVi 14 canaux**. Le fichier produit se dépose tel quel.

Mesure-le avant de l'adopter : `python3 tools/analyse_hrir.py`. Le critère qui compte
reste la latéralisation, et une salle synthétisée n'y échappe pas.

## Correction de casque

Couche **distincte** des profils ci-dessus, et cumulable avec eux : un profil HRIR
*place* les sons autour de la tête, une correction de casque *compense la réponse en
fréquence de ton modèle*. Elle ne déplace rien.

```bash
surround-profil --casque-chercher hyperx      # cherche parmi 8850 casques mesurés
surround-profil --casque "HyperX Cloud Flight S"
surround-profil --casque-aucune               # revenir à aucune correction
```

Le filtre est téléchargé à la demande depuis [AutoEQ](https://github.com/jaakkopasanen/AutoEq),
en FIR à phase minimale 48 kHz — notre fréquence, donc sans rééchantillonnage. Au pied de la fenêtre de l'applet, un champ cherche dans les 8850 entrées à partir de
trois caractères : une coche signale les filtres déjà présents, un « + » ceux à
télécharger. Champ vide, il liste ce qui est installé. Le bouton à droite retire la
correction.

**Une correction ne vaut que pour le modèle mesuré.** En appliquer une prévue pour un
autre casque creuse un pic qui n'existe pas et dégrade le rendu. Aucune n'est donc
active par défaut.

Le niveau global baisse d'environ 3 à 4 dB une fois la correction active : c'est la
réserve que le filtre garde pour ses remontées, pas une perte de qualité.

## Tester

```bash
cd ~/.local/share/pipewire/tests-surround
python3 gen_tests.py
paplay -d effect_input.virtual-surround-7.1-hesuvi test_cercle.wav
```

- `test_avant_arriere.wav` — trajectoire continue avant → côtés → arrière → retour
- `test_cercle.wav` — une salve isolée par enceinte, dans le sens horaire

Les fichiers sont des pistes **7.1 brutes** : il faut les jouer sur le sink virtuel,
pas en lecture directe. Ils utilisent du bruit rose en salves, un sinus ne se
localisant quasiment pas.

## Pièges connus

- **Ne jamais activer le mode « casque » ou « HRTF » du jeu.** Choisis une sortie
  **7.1**. Sinon deux spatialisations s'empilent et l'image devient creuse et bizarre.
- Un jeu en stéréo ne donnera pas de placement arrière — seulement l'externalisation.
- Seuls les WAV HeSuVi **14 canaux** conviennent ; `surround-profil` refuse les autres.
- La voix (chat) traverse aussi la convolution et gagne la réverbération du profil.
  Pour l'éviter, envoie ce flux seul vers le casque brut dans `pavucontrol`.
- Latence ajoutée : de l'ordre d'un quantum PipeWire (~21 ms à 1024 @ 48 kHz).
  Réductible en abaissant le quantum si tu la ressens en jeu.
- **Le sink n'apparaît pas dans l'applet de volume du panneau.** Il est bien visible
  et sélectionnable dans *Configuration du système → Son*, et le son fonctionne
  normalement. En cause : `module-filter-chain` crée le nœud avec
  `object.register = "false"`, ce qui le tient hors du registre que consomme le
  gestionnaire de session — `wpctl status` ne le liste pas non plus. Forcer
  `object.register = true` ne change rien, et le charger dans le démon principal
  plutôt que dans notre instance dédiée non plus : la limitation est en amont.
  Pour changer de sortie par défaut, passe par la configuration système ou
  `pactl set-default-sink`. Le choix des profils, lui, se fait dans notre applet.
- Manjaro ne fournit pas de `pipewire-filter-chain.service` : `install.sh` écrit
  sa propre unité `spatial-sound.service`.

## Désinstallation

```bash
./uninstall.sh          # retire config et binaire, garde les HRIR
./uninstall.sh --tout   # efface aussi les HRIR et les fichiers de test
```

## Fichiers installés

```
~/.config/pipewire/filter-chain.conf.d/99-spatial-sound.conf          graphe de convolution
~/.config/systemd/user/spatial-sound.service                         instance dédiée
~/.local/share/pipewire/hrir_hesuvi/                                 profils HRIR
~/.local/share/pipewire/hpcf/                                        corrections de casque + index
~/.local/share/pipewire/tests-surround/                              outils de mesure/test
~/.local/bin/surround-profil                                         sélecteur de profil
~/.local/share/plasma/plasmoids/org.spatialsound.kde/                applet Plasma (KDE)
~/.local/share/icons/hicolor/scalable/apps/org.spatialsound.kde.svg  icône
```

## Architecture

La chaîne de convolution ne tourne **pas** dans le serveur PipeWire principal, mais
dans une instance dédiée lancée par `spatial-sound.service` — c'est l'usage prévu du
fichier `filter-chain.conf` livré avec PipeWire.

Conséquence directe : changer de profil ne recharge que cette petite instance.
Mesuré à **0,15 s**, contre ~3 s pour un redémarrage complet de la pile audio, et
surtout **sans interrompre les autres flux** : musique, chat et navigateur continuent
de jouer. C'est la raison pour laquelle la configuration vit dans
`filter-chain.conf.d/` et non dans `pipewire.conf.d/`.

L'icône est déposée dans le thème `hicolor` et référencée par son **nom**, pas par un
chemin : le navigateur de widgets ne résout que des noms d'icônes de thème.

## Crédits

Les HRIR proviennent du projet **HeSuVi**, qui a capturé les réponses de nombreux
virtualiseurs commerciaux. Le graphe de convolution dérive de l'exemple
`sink-virtual-surround-7.1-hesuvi.conf` fourni avec PipeWire.

## Feuille de route

Les pistes ouvertes sont dans [TODO.md](TODO.md) — correction de casque
(HpCF), empaquetage AUR, et ce qui n'a pas encore été vérifié.

## Licence

MIT — voir [LICENSE](LICENSE).
