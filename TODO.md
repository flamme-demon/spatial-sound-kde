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

### À vérifier avant d'implémenter

- [ ] **Le HyperX Cloud Flight S est-il mesuré** dans AutoEQ ou ASH ? Les casques de
      jeu sans fil y sont mal couverts. Sans mesure du modèle, la fonctionnalité
      existe mais ne sert à personne ici.
- [ ] Rééchantillonnage 44,1 → 48 kHz nécessaire, ou le convolueur PipeWire s'en
      charge-t-il ?
- [ ] Un HpCF mal choisi **dégrade** le son : appliquer une correction DT 990 à un
      autre casque creuse un pic qui n'existe pas. Prévoir un avertissement explicite,
      et surtout ne pas en activer un par défaut.

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
