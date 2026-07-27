# TODO

Pistes ouvertes, par ordre d'intérêt décroissant.

---

## Correction de casque (HpCF)

**Ajouter une seconde étape de convolution, après le mixage binaural, pour compenser
la réponse en fréquence du casque.**

C'est une couche distincte de ce que fait le projet aujourd'hui, et les deux se
cumulent :

| | actuel | à ajouter |
|---|---|---|
| rôle | **placer** les sons autour de la tête | **corriger** la couleur du casque |
| données | HRIR 14 canaux (HeSuVi) | filtre FIR mono (HpCF) |
| dépend de | rien de matériel | le modèle exact de casque |

C'est ce que les gens désignent quand ils parlent d'un « profil beyerdynamic » : une
courbe qui aplatit le pic d'aigus des DT 770 / DT 990. Aucun des 59 profils HeSuVi
n'est un modèle de casque — ce sont tous des captures de virtualiseurs.

### Implémentation

Deux convolueurs supplémentaires en sortie du mixeur, un par oreille :

```
… → mixL → convHpCF_L → sortie G
… → mixR → convHpCF_R → sortie D
```

L'ordre compte : spatialisation **puis** correction. Le graphe existant n'a pas
besoin d'être touché, seulement prolongé.

Point de comparaison utile : Spatial Sound Card lui-meme n'expose que **quatre**
entrees dans son menu « HEADPHONE EQ » (DT 770M, DT 880 PRO, Default, Beats Pro).
Une implementation adossee a ASH ou AutoEQ couvrirait des centaines de modeles, donc
depasserait le produit commercial sur cet axe precis.

Source de filtres : [ASH Toolset](https://github.com/ShanonPearce/ASH-Toolset) —
FIR à phase minimale, 1024 points, WAV mono 44,1 kHz, couvrant AKG, Audeze,
Audio-Technica, Beyerdynamic, HiFiMAN, Sennheiser et d'autres.
Alternative : [AutoEQ](https://autoeq.app/).

### Verifie le 2026-07-28

- [x] **Le HyperX Cloud Flight S est mesure.** Present dans AutoEQ, mesure Rtings
      (HMS II.3), sous `results/Rtings/HMS II.3 over-ear/HyperX Cloud Flight S/`.
- [x] **Pas de reechantillonnage a prevoir** : AutoEQ publie un FIR a phase minimale
      directement en **48 kHz**, notre frequence. Fichier WAV stereo, 4800
      echantillons (100 ms), 16 bits.
      Reponse mesuree du filtre : +4,8 dB dans 200-500 Hz, +4,3 dB dans 3-5 kHz,
      -3,3 dB au-dessus de 10 kHz. Correction credible pour un casque de jeu au
      medium creuse et aux aigus chauds.
- [x] La phase minimale concentre l'energie en debut de reponse : la latence de la
      convolution partitionnee depend du bloc, pas de la longueur du FIR. Les
      4800 points n'ajoutent donc pas 100 ms.

### Reste a trancher
- [ ] Un HpCF mal choisi **dégrade** le son : appliquer une correction DT 990 à un
      autre casque creuse un pic qui n'existe pas. Prévoir un avertissement explicite,
      et surtout ne pas en activer un par défaut.
- [ ] **Comment distribuer le catalogue.** AutoEQ compte ~700 casques et 52 000
      fichiers : impossible a embarquer. Deux pistes — generer un index nom -> chemin
      une fois et telecharger le WAV a la demande, ou se contenter d'un
      `--hpcf-file <chemin>` que l'utilisateur alimente lui-meme.
      L'index est le seul moyen d'avoir un menu deroulant utilisable dans l'applet.

### Integration dans l'applet

Le graphe et le script sont la partie facile : deux convolueurs de plus apres le
mixeur, un symlink `hpcf.wav` sur le modele de `hrir.wav`, et `surround-profil`
gagne `--hpcf <nom>` / `--hpcf-none`. Le rechargement reste celui du service dedie,
donc toujours 0,15 s.

Cote applet, la difficulte n'est pas technique mais de mise en page : la liste des
profils occupe deja toute la hauteur disponible. Un menu deroulant « Casque » dans le
pied de fenetre, la ou vit la legende, coute une seule ligne et ne touche pas a la
liste. C'est la piste a suivre — surtout pas une seconde liste.

---

## Enveloppe de reverberation reglable

Spatial Sound Card expose un « ROOM ENVELOPE » : une courbe de decroissance editable,
graduee en dB, qui laisse raccourcir ou allonger la queue de reverberation **sans
changer de profil**.

Chez nous, le seul reglage equivalent est de basculer d'un profil a l'autre — passer
de `atmos` (46 ms) a `cmss_game` (39 ms) ou `sonic` (16 ms). C'est grossier : on
change en meme temps la lateralisation et la coloration, alors qu'on ne voulait
toucher qu'a la distance percue.

Implementable simplement : appliquer une fenetre de decroissance exponentielle a la
queue du HRIR avant de le donner au convolueur, et regenerer un WAV temporaire. Un
curseur « proximite » dans l'applet piloterait la constante de temps.

A verifier : jusqu'ou raccourcir sans introduire de discontinuite audible, et si
l'operation doit preserver l'energie totale ou non.

---

## Empaquetage AUR

`paru -S spatial-sound-kde` plutôt qu'un clone git. C'est ce qui manque pour que le
projet soit installable sans lire le README.

---

## Ajout automatique du widget au panneau

`install.sh` rend le widget disponible mais ne l'ajoute pas — modifier la disposition
d'un bureau existant est une décision de l'utilisateur. Faisable via `evaluateScript`
sur l'interface D-Bus de plasmashell, à proposer derrière une option explicite
(`--add-widget`), jamais par défaut.

---

## Dépendances hors pacman

L'installation des dépendances est spécifique à Arch. Sur les autres distributions le
script liste ce qui manque et continue sans rien installer. Une abstraction
apt/dnf/zypper serait utile, mais ne doit pas être écrite sans pouvoir la tester.

---

## Captures d'écran à refaire

`docs/applet.png` montre les lignes **empilées**, c'est-à-dire la mise en page
d'avant la compaction. À refaire après un rechargement de plasmashell, ce qui
permettra aussi de confirmer que la barre de défilement a bien disparu.

---

## Vérifications jamais faites

- [ ] **Latence réelle de bout en bout.** `pactl` renvoie 0 µs, ce qui signifie
      « non disponible », pas « nulle ». L'estimation d'un quantum (~21 ms à 1024 @
      48 kHz) est théorique et n'a jamais été mesurée.
      Corroboration indirecte : Spatial Sound Card affiche un « LATENCY TARGET » de
      **21,3 ms**, soit le meme ordre de grandeur. Cela rend l'estimation credible
      mais ne la mesure pas — a confirmer par une vraie boucle d'aller-retour.
- [ ] **Comportement sur une autre distribution que Manjaro**, et sur du matériel
      autre qu'un casque USB stéréo.
