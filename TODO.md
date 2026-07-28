# TODO

Pistes ouvertes, par ordre d'intérêt décroissant.

---

## ~~Correction de casque (HpCF)~~ — fait en 0.2.0

Livre : etage de convolution apres le mixage binaural, index des 8850 casques
mesures par AutoEQ, telechargement a la demande, selecteur dans l'applet.

Reste ouvert :

- [ ] L'index n'expose que les filtres **48 kHz** d'AutoEQ. Les jeux publies
      uniquement en 44,1 kHz sont donc invisibles — a rendre accessibles si le
      convolueur PipeWire sait reechantillonner, ce qui n'a pas ete verifie.
- [ ] Ajouter [ASH Toolset](https://github.com/ShanonPearce/ASH-Toolset) comme
      seconde source : ses filtres visent une cible champ diffus, differente de
      celle d'AutoEQ.
- [x] ~~L'applet ne propose que les corrections deja telechargees.~~ Fait en 0.2.1 :
      un champ de recherche coute la meme ligne qu'un menu deroulant, et les
      resultats flottent au-dessus sans consommer de hauteur.

---

## ~~Enveloppe de reverberation reglable~~ — fait en 0.3.0

Curseur « Amortissement » dans l'applet, `--enveloppe 0-100` en ligne de commande.
Raccourcit la queue du profil actif sans le modifier ni changer son niveau.

Reste ouvert :

- [ ] **On ne sait que raccourcir.** Allonger demanderait de synthetiser de la
      reverberation, ce que fait le generateur de salles — les deux pourraient
      etre reunis derriere un seul reglage de distance.
- [ ] La forme de la decroissance est une exponentielle simple. Une vraie salle
      decroit differemment selon la frequence, les aigus s'eteignant plus vite.

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

## Sink absent de l'applet de volume du panneau

Voir #2. `module-filter-chain` force `object.register = "false"` sur le noeud, donc
WirePlumber ne l'adopte pas et l'applet ne le liste pas — alors que la configuration
systeme, qui enumere les sinks PulseAudio, l'affiche correctement.

Ecarte par la mesure : forcer `object.register = true` (la propriete devient bien
effective, sans effet), `node.dont-reconnect = false`, et charger la chaine dans le
demon principal plutot que dans notre instance dediee.

- [ ] Trouver la propriete qui fait adopter un noeud de filter-chain par
      WirePlumber, ou confirmer en amont qu'il n'y en a pas.

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
