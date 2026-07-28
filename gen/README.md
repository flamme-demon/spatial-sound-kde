# spatial-sound-gen

Synthetise une salle d'ecoute virtuelle au format HeSuVi 14 canaux, directement
consommable par le projet.

```bash
cargo build --release
./target/release/spatial-sound-gen \
    --sofa kemar.sofa --preset cabine \
    --sortie ~/.local/share/pipewire/hrir_hesuvi/ma_salle.wav
```

Presets : `cabine`, `studio`, `regie`, `salon`. Tous les parametres restent
ajustables individuellement (`--help`).

Il faut un jeu HRTF au format SOFA, par exemple sur
[sofacoustics.org](https://sofacoustics.org/). Le fichier produit apparait dans
l'applet sous « Les tiens — non mesures ».

## Ce que ca vaut, mesure

**A lire avant d'esperer remplacer les profils livres.** Sur du bruit rose, la
salle generee produit **+0,5 dB** d'ecart interaural la ou `cmss_game` en produit
**+3,3 dB**. Deux causes cumulees :

- la HRTF de KEMAR plafonne a +9,6 dB d'ecart, quand les captures de
  virtualiseurs commerciaux atteignent +15 dB — ces produits **exagerent
  deliberement** la separation au-dela du physiquement realiste, et c'est
  precisement ce qui les rend efficaces en jeu ;
- la queue de reverberation, decorrelee mais d'energie egale aux deux oreilles,
  dilue encore l'ecart.

Autrement dit : ce generateur est physiquement correct et perceptivement plus
faible. Il vaut pour explorer des salles, pas pour gagner en localisation.

## Notes d'implementation

Ecrit d'apres les algorithmes publies — methode des sources images
(Allen & Berkley, 1979), formule de Sabine — sans reprendre de code existant.
Aucune dependance cargo ; la seule brique externe est `libmysofa`, en C.

Deux pieges rencontres, documentes dans le code :

- **Normaliser sur la crete sature la chaine.** Une reponse de salle porte une
  longue queue : a crete egale son energie depasse largement celle d'une capture
  seche, et c'est l'energie qui fixe le gain de la convolution. La sortie
  saturait a 0,00 dBFS, ce qui ecrasait toute localisation. La normalisation se
  fait donc sur l'energie.
- **Les retards renvoyes par libmysofa ne doivent pas etre reappliques** : la
  geometrie de la salle porte deja la difference de temps interaurale.
