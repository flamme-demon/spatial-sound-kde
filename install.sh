#!/usr/bin/env bash
#
# Spatial Sound KDE — sink virtuel 7.1 binaural pour casque, sous PipeWire.
# Alternative libre a Spatial Sound Card / Dolby Atmos for Headphones.
#
# Cible : Manjaro / Arch + KDE + pipewire-pulse. Fonctionne sur toute distro
# avec PipeWire >= 0.3.60 ; seule l'installation des dependances est specifique
# a pacman (contournable avec --no-deps).
#
set -euo pipefail

PROJET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HRIR_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hrir_hesuvi"
# La chaine tourne dans une instance PipeWire dediee, pas dans le serveur
# principal : la recharger pour changer de profil devient instantane et
# n'interrompt aucun autre flux audio.
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d"
CONF="$CONF_DIR/99-spatial-sound.conf"
# Emplacements d'avant la 0.1.0 : charges par le serveur principal, ou sous
# l'ancien nom de fichier. Les deux doivent disparaitre, sinon deux sinks
# coexistent et le son passe par le mauvais.
CONFS_ANCIENS=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-surround-casque.conf"
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-spatial-sound.conf"
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d/99-surround-casque.conf"
)
UNITE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/spatial-sound.service"
BIN_DIR="$HOME/.local/bin"
TEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/tests-surround"
ETAT="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/spatial-sound.state"
PLASMOID_ID="org.spatialsound.kde"
PLASMOID_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$PLASMOID_ID"
# Identifiants utilises avant la 0.1.0, a nettoyer pour eviter les doublons
# dans le navigateur de widgets.
PLASMOIDS_ANCIENS=(
  "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/org.kde.pwsurround"
  "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/org.pwsurround.spatialsound"
)
ICONES_ANCIENNES=(
  "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/org.pwsurround.spatialsound.svg"
)
UNITE_ANCIENNE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pw-surround.service"
ETAT_ANCIEN="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/pw-surround.state"

HRIR_REPO="https://github.com/loteran/arctis-virtual-surround.git"
PROFIL_DEFAUT="cmss_game"
SET_DEFAULT_SINK=1
INSTALL_DEPS=1
ASSUME_YES=0
HRIR_LOCAL=""

rouge()  { printf '\033[31m%s\033[0m\n' "$*"; }
vert()   { printf '\033[32m%s\033[0m\n' "$*"; }
jaune()  { printf '\033[33m%s\033[0m\n' "$*"; }
titre()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
mourir() { rouge "ERREUR : $*"; exit 1; }

usage() {
  cat <<EOF
Usage : ./install.sh [options]

  --profil <nom>     profil HRIR initial (defaut : $PROFIL_DEFAUT)
  --hrir-dir <chem>  utilise un dossier de WAV HeSuVi local au lieu de telecharger
  --no-default-sink  n'impose pas le sink virtuel comme sortie par defaut
  --no-deps          n'installe aucune dependance via pacman
  -y, --yes          ne pose aucune question
  -h, --help         cette aide

Profils recommandes en jeu     : cmss_game, sonic, dtshx
Profils de salle pour le cinema : atmos, ssc_ny, ssc_syd
A eviter : dvs (ne lateralise pas), dh+ et gsx (tres reverberants).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profil)          PROFIL_DEFAUT="$2"; shift 2 ;;
    --hrir-dir)        HRIR_LOCAL="$2"; shift 2 ;;
    --no-default-sink) SET_DEFAULT_SINK=0; shift ;;
    --no-deps)         INSTALL_DEPS=0; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) mourir "option inconnue : $1 (voir --help)" ;;
  esac
done

confirmer() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -rp "$1 [O/n] " r
  [[ -z "$r" || "$r" =~ ^[oOyY] ]]
}

# ---------------------------------------------------------------- verifications
titre "Verification de l'environnement"

[[ $EUID -eq 0 ]] && mourir "ne pas lancer en root : la config est par utilisateur."

# Compare deux versions : vrai si $1 >= $2. sort -V gere les numeros multi-champs
# la ou une comparaison lexicale se tromperait (0.3.9 vs 0.3.60).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# surround-profil utilise des tableaux associatifs : bash 4 minimum.
if (( BASH_VERSINFO[0] < 4 )); then
  mourir "bash ${BASH_VERSION} trop ancien : bash 4.0 minimum (tableaux associatifs)."
fi

for outil in pactl paplay systemctl; do
  command -v "$outil" >/dev/null \
    || mourir "$outil introuvable — requis. (pactl/paplay : libpulse ; systemctl : systemd)"
done

SERVEUR="$(pactl info 2>/dev/null | sed -n 's/^Server Name: //p')"
case "$SERVEUR" in
  *PipeWire*) vert "  PipeWire detecte : $SERVEUR" ;;
  "")         mourir "aucun serveur audio joignable. Session utilisateur active ?" ;;
  *)          rouge "  serveur audio : $SERVEUR"
              mourir "PulseAudio classique n'est pas supporte : ce script s'appuie sur
       module-filter-chain de PipeWire. Sous PulseAudio pur, voir
       module-virtual-surround-sink (approche differente)." ;;
esac

# 0.3.60 est le seuil ou le convolueur integre et la forme de configuration
# utilisee ici (capture.props / playback.props) se sont stabilises. En dessous,
# le module se charge mais le graphe reste muet, sans message d'erreur.
PW_MIN="0.3.60"
PW_VER="$(pipewire --version 2>/dev/null | sed -n 's/.*libpipewire \([0-9][0-9.]*\).*/\1/p' | head -1)"
if [[ -z "$PW_VER" ]]; then
  jaune "  version PipeWire indeterminee — verification ignoree ($PW_MIN attendu)"
elif version_ge "$PW_VER" "$PW_MIN"; then
  vert "  version PipeWire : $PW_VER (>= $PW_MIN)"
else
  mourir "PipeWire $PW_VER trop ancien : $PW_MIN minimum.
       En dessous, le sink se cree mais ne produit aucun son."
fi

if ! find /usr/lib /usr/lib64 /usr/local/lib -name "libpipewire-module-filter-chain.so" 2>/dev/null | grep -q .; then
  mourir "module-filter-chain absent. Installer le paquet 'pipewire-audio'."
fi
vert "  module-filter-chain present"

command -v pw-link >/dev/null \
  || jaune "  pw-link absent : la verification finale des liens sera ignoree"

# ------------------------------------------------------------------ dependances
if [[ $INSTALL_DEPS -eq 1 ]]; then
  titre "Dependances"
  MANQUANT=()
  command -v ffprobe >/dev/null || MANQUANT+=(ffmpeg)
  command -v git     >/dev/null || MANQUANT+=(git)
  python3 -c "import numpy"      2>/dev/null || MANQUANT+=(python-numpy)
  python3 -c "import scipy.io"   2>/dev/null || MANQUANT+=(python-scipy)

  if [[ ${#MANQUANT[@]} -gt 0 ]]; then
    jaune "  manquant : ${MANQUANT[*]}"
    if command -v pacman >/dev/null; then
      if confirmer "  Installer via pacman ?"; then
        sudo pacman -S --needed --noconfirm "${MANQUANT[@]}"
      else
        jaune "  ignore — le script de mesure et les tests peuvent echouer."
      fi
    else
      jaune "  pacman absent : installe manuellement ${MANQUANT[*]}"
    fi
  else
    vert "  toutes presentes"
  fi
fi

# ------------------------------------------------------------------------ HRIR
titre "Jeux de reponses impulsionnelles (HRIR)"
mkdir -p "$HRIR_DIR"

nb_wav() { find "$HRIR_DIR" -maxdepth 1 -name '*.wav' ! -name 'hrir.wav' 2>/dev/null | wc -l; }

if [[ -n "$HRIR_LOCAL" ]]; then
  [[ -d "$HRIR_LOCAL" ]] || mourir "dossier introuvable : $HRIR_LOCAL"
  compgen -G "$HRIR_LOCAL/*.wav" >/dev/null || mourir "aucun .wav dans $HRIR_LOCAL"
  # Un dossier fourni a la main contient souvent des WAV stereo : sans ce controle,
  # l'installation reussit et le sink reste muet.
  if command -v ffprobe >/dev/null; then
    n14=0
    for f in "$HRIR_LOCAL"/*.wav; do
      [[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
            -of csv=p=0 "$f" 2>/dev/null)" == "14" ]] && ((n14++)) || true
    done
    (( n14 > 0 )) || mourir "aucun WAV 14 canaux dans $HRIR_LOCAL.
       Le format attendu est celui de HeSuVi (14 canaux), pas des paires stereo."
    vert "  $n14 fichier(s) 14 canaux valides"
  fi
  cp -f "$HRIR_LOCAL"/*.wav "$HRIR_DIR"/
  vert "  copies depuis $HRIR_LOCAL"
elif [[ -d "$PROJET/share/hrir" ]] && compgen -G "$PROJET/share/hrir/*.wav" >/dev/null; then
  cp -f "$PROJET/share/hrir"/*.wav "$HRIR_DIR"/
  vert "  copies depuis le depot local"
elif [[ $(nb_wav) -gt 10 ]]; then
  vert "  deja presents ($(nb_wav) profils), telechargement ignore"
else
  echo "  telechargement depuis $HRIR_REPO ..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 -q "$HRIR_REPO" "$TMP/src" \
    || mourir "telechargement impossible. Reessaie, ou fournis --hrir-dir <dossier>."
  find "$TMP/src" -name '*.wav' -exec cp -f {} "$HRIR_DIR"/ \;
  vert "  $(nb_wav) profils installes"
fi

[[ $(nb_wav) -gt 0 ]] || mourir "aucun HRIR disponible dans $HRIR_DIR"

# Le profil demande doit exister ET faire 14 canaux (format HeSuVi attendu).
valider_14ch() {
  local f="$1"
  command -v ffprobe >/dev/null || return 0   # pas de ffprobe : on fait confiance
  [[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of csv=p=0 "$f" 2>/dev/null)" == "14" ]]
}

if [[ ! -f "$HRIR_DIR/$PROFIL_DEFAUT.wav" ]] || ! valider_14ch "$HRIR_DIR/$PROFIL_DEFAUT.wav"; then
  jaune "  '$PROFIL_DEFAUT' absent ou non 14 canaux, recherche d'un remplacant..."
  for c in cmss_game sonic atmos dtshx EAC_Default; do
    if [[ -f "$HRIR_DIR/$c.wav" ]] && valider_14ch "$HRIR_DIR/$c.wav"; then
      PROFIL_DEFAUT="$c"; break
    fi
  done
  [[ -f "$HRIR_DIR/$PROFIL_DEFAUT.wav" ]] || mourir "aucun profil 14 canaux exploitable."
fi
ln -sfn "$HRIR_DIR/$PROFIL_DEFAUT.wav" "$HRIR_DIR/hrir.wav"
vert "  profil initial : $PROFIL_DEFAUT"

# ---------------------------------------------------------------- configuration
titre "Configuration du sink virtuel"
mkdir -p "$CONF_DIR"

# Memorise la sortie physique d'origine pour la cibler dans la config et
# pour que uninstall.sh la restaure exactement.
ANCIEN_SINK="$(pactl get-default-sink 2>/dev/null || true)"
if [[ -n "$ANCIEN_SINK" && "$ANCIEN_SINK" != *virtual-surround* ]]; then
  printf 'sink_precedent=%s\n' "$ANCIEN_SINK" > "$ETAT"
  vert "  sortie physique precedente : $ANCIEN_SINK"
else
  # En reinstallation, le sink par defaut est deja le virtuel.
  # On lit le peripherique physique depuis l'etat sauvegarde.
  ANCIEN_SINK=""
  [[ -f "$ETAT" ]] && ANCIEN_SINK="$(sed -n 's/^sink_precedent=//p' "$ETAT")"
  if [[ -n "$ANCIEN_SINK" ]]; then
    vert "  sortie physique precedente (depuis etat) : $ANCIEN_SINK"
  fi
fi

# Graphe genere ici plutot que copie depuis /usr/share : le fichier d'exemple
# n'existe pas sur toutes les distros, et son chemin HRIR relatif ne se resout pas.
{
  cat <<'ENTETE'
# Genere par Spatial Sound KDE — ne pas editer a la main.
# Sink virtuel 7.1 convolue en binaural vers la sortie stereo par defaut.
context.modules = [
    { name = libpipewire-module-filter-chain
        flags = [ nofail ]
        args = {
            node.description = "Casque Surround 7.1 (binaural)"
            media.name       = "Casque Surround 7.1"
            filter.graph = {
                nodes = [
                    { type = builtin label = copy name = copyFL  }
                    { type = builtin label = copy name = copyFR  }
                    { type = builtin label = copy name = copyFC  }
                    { type = builtin label = copy name = copyRL  }
                    { type = builtin label = copy name = copyRR  }
                    { type = builtin label = copy name = copySL  }
                    { type = builtin label = copy name = copySR  }
                    { type = builtin label = copy name = copyLFE }
ENTETE

  # 14 convolueurs : chaque enceinte virtuelle vers chaque oreille.
  # L'ordre des canaux est celui du format HeSuVi, a ne pas reorganiser.
  while read -r nom canal; do
    printf '                    { type = builtin label = convolver name = %-9s config = { filename = "%s" channel = %2s } }\n' \
      "$nom" "$HRIR_DIR/hrir.wav" "$canal"
  done <<'CANAUX'
convFL_L 0
convFL_R 1
convSL_L 2
convSL_R 3
convRL_L 4
convRL_R 5
convFC_L 6
convFR_R 7
convFR_L 8
convSR_R 9
convSR_L 10
convRR_R 11
convRR_L 12
convFC_R 13
CANAUX

  # Le LFE n'a pas de HRIR propre : on le traite comme le canal central.
  printf '                    { type = builtin label = convolver name = convLFE_L config = { filename = "%s" channel =  6 } }\n' "$HRIR_DIR/hrir.wav"
  printf '                    { type = builtin label = convolver name = convLFE_R config = { filename = "%s" channel = 13 } }\n' "$HRIR_DIR/hrir.wav"

  # Ligne d'ancrage optionnelle : si on a un peripherique physique de reference,
  # on empeche WirePlumber de router la sortie ailleurs (ex. USB > interne).
  ANCRE=""
  [[ -n "$ANCIEN_SINK" ]] && ANCRE=$'\n                target.object  = "'"$ANCIEN_SINK"'"'

  cat <<PIED
                    { type = builtin label = mixer name = mixL }
                    { type = builtin label = mixer name = mixR }
                ]
                links = [
                    { output = "copyFL:Out"  input="convFL_L:In"  }
                    { output = "copyFL:Out"  input="convFL_R:In"  }
                    { output = "copySL:Out"  input="convSL_L:In"  }
                    { output = "copySL:Out"  input="convSL_R:In"  }
                    { output = "copyRL:Out"  input="convRL_L:In"  }
                    { output = "copyRL:Out"  input="convRL_R:In"  }
                    { output = "copyFC:Out"  input="convFC_L:In"  }
                    { output = "copyFR:Out"  input="convFR_R:In"  }
                    { output = "copyFR:Out"  input="convFR_L:In"  }
                    { output = "copySR:Out"  input="convSR_R:In"  }
                    { output = "copySR:Out"  input="convSR_L:In"  }
                    { output = "copyRR:Out"  input="convRR_R:In"  }
                    { output = "copyRR:Out"  input="convRR_L:In"  }
                    { output = "copyFC:Out"  input="convFC_R:In"  }
                    { output = "copyLFE:Out" input="convLFE_L:In" }
                    { output = "copyLFE:Out" input="convLFE_R:In" }

                    { output = "convFL_L:Out"  input="mixL:In 1" }
                    { output = "convFL_R:Out"  input="mixR:In 1" }
                    { output = "convSL_L:Out"  input="mixL:In 2" }
                    { output = "convSL_R:Out"  input="mixR:In 2" }
                    { output = "convRL_L:Out"  input="mixL:In 3" }
                    { output = "convRL_R:Out"  input="mixR:In 3" }
                    { output = "convFC_L:Out"  input="mixL:In 4" }
                    { output = "convFC_R:Out"  input="mixR:In 4" }
                    { output = "convFR_R:Out"  input="mixR:In 5" }
                    { output = "convFR_L:Out"  input="mixL:In 5" }
                    { output = "convSR_R:Out"  input="mixR:In 6" }
                    { output = "convSR_L:Out"  input="mixL:In 6" }
                    { output = "convRR_R:Out"  input="mixR:In 7" }
                    { output = "convRR_L:Out"  input="mixL:In 7" }
                    { output = "convLFE_R:Out" input="mixR:In 8" }
                    { output = "convLFE_L:Out" input="mixL:In 8" }
                ]
                inputs  = [ "copyFL:In" "copyFR:In" "copyFC:In" "copyLFE:In" "copyRL:In" "copyRR:In", "copySL:In", "copySR:In" ]
                outputs = [ "mixL:Out" "mixR:Out" ]
            }
            capture.props = {
                node.name      = "effect_input.virtual-surround-7.1-hesuvi"
                media.class    = Audio/Sink
                audio.channels = 8
                audio.position = [ FL FR FC LFE RL RR SL SR ]
            }
            playback.props = {
                node.name      = "effect_output.virtual-surround-7.1-hesuvi"
                node.passive   = true
                audio.channels = 2
                audio.position = [ FL FR ]${ANCRE:+$ANCRE}
            }
        }
    }
]
PIED
} > "$CONF"
vert "  ecrit : $CONF"

# Service dedie : c'est lui qui rend le changement de profil instantane.
mkdir -p "$(dirname "$UNITE")"
cat > "$UNITE" <<UNIT
[Unit]
Description=Spatial Sound KDE — chaine de convolution binaurale 7.1
After=pipewire.service
BindsTo=pipewire.service
ConditionPathExists=%h/.local/share/pipewire/hrir_hesuvi/hrir.wav

[Service]
Type=simple
ExecStart=$(command -v pipewire) -c filter-chain.conf
Restart=on-failure
RestartSec=1
Slice=session.slice

[Install]
WantedBy=pipewire.service
UNIT
systemctl --user daemon-reload
vert "  service spatial-sound.service ecrit"

# ------------------------------------------------------------------- outillage
titre "Outils"
mkdir -p "$BIN_DIR" "$TEST_DIR"
install -m 755 "$PROJET/bin/surround-profil" "$BIN_DIR/surround-profil"
vert "  $BIN_DIR/surround-profil"
for t in analyse_hrir.py gen_tests.py; do
  [[ -f "$PROJET/tools/$t" ]] && install -m 755 "$PROJET/tools/$t" "$TEST_DIR/$t" && vert "  $TEST_DIR/$t"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) jaune "  $BIN_DIR n'est pas dans ton PATH."
     jaune "  Ajoute a ~/.bashrc : export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# Applet Plasma : uniquement si KDE est present, sinon c'est du poids mort.
PLASMA_OK=0
if command -v plasmashell >/dev/null; then
  # L'applet declare X-Plasma-API-Minimum-Version 6.0 et importe des modules
  # QML propres a Plasma 6 : sous Plasma 5 il s'installe mais refuse de charger.
  PLASMA_VER="$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  if [[ -z "$PLASMA_VER" ]]; then
    jaune "  version de Plasma indeterminee — applet installe sans garantie"
    PLASMA_OK=1
  elif version_ge "$PLASMA_VER" "6.0"; then
    PLASMA_OK=1
  else
    jaune "  Plasma $PLASMA_VER : l'applet exige Plasma 6, installation ignoree"
    jaune "  (le reste fonctionne, utilise « surround-profil » en ligne de commande)"
  fi
fi

if [[ -d "$PROJET/plasmoid" ]] && (( PLASMA_OK == 1 )); then
  for ancien in "${PLASMOIDS_ANCIENS[@]}"; do
    if [[ -d "$ancien" ]]; then
      rm -rf "$ancien"
      jaune "  ancien applet $(basename "$ancien") retire — a re-ajouter au panneau"
    fi
  done
  rm -f "${ICONES_ANCIENNES[@]}"
  # Les catalogues .mo sont generes ici, pas versionnes : ils derivent des .po.
  [[ -x "$PROJET/plasmoid/build-translations.sh" ]] \
    && "$PROJET/plasmoid/build-translations.sh" >/dev/null 2>&1 || true
  rm -rf "$PLASMOID_DIR"
  mkdir -p "$PLASMOID_DIR"
  cp -r "$PROJET/plasmoid/." "$PLASMOID_DIR"/
  rm -rf "$PLASMOID_DIR/po" "$PLASMOID_DIR/build-translations.sh"

  # L'icone doit vivre dans un theme, pas seulement dans le paquet : le
  # navigateur de widgets resout un NOM d'icone et ignore les chemins relatifs.
  ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  mkdir -p "$ICON_DIR"
  install -m644 "$PROJET/plasmoid/contents/icons/spatial-sound.svg" \
    "$ICON_DIR/org.spatialsound.kde.svg"
  command -v gtk-update-icon-cache >/dev/null \
    && gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
  vert "  icone deposee dans le theme hicolor"
  LANGUES="$(find "$PLASMOID_DIR/contents/locale" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
  vert "  applet Plasma installe (langues : en ${LANGUES:-})"
  echo "    Ajoute-le : clic droit sur le bureau ou le panneau -> Ajouter des widgets"
  echo "    -> chercher « Spatial Sound »"

  # Installer les fichiers ne suffit pas : plasmashell garde en memoire le QML
  # et les icones deja charges. Sans rechargement, une mise a jour de l'applet
  # reste invisible — y compris une icone corrigee, qui continue d'afficher « ? ».
  if pgrep -x plasmashell >/dev/null 2>&1; then
    DEPUIS="$(ps -o lstart= -C plasmashell 2>/dev/null | head -1 | xargs)"
    jaune "  plasmashell tourne depuis $DEPUIS"
    jaune "  Il faut le recharger pour voir cette version."
    if [[ $ASSUME_YES -eq 1 ]]; then
      jaune "  Mode non interactif : rechargement non effectue. Lance a la main :"
      echo  "      kquitapp6 plasmashell && kstart plasmashell"
    elif confirmer "  Recharger plasmashell maintenant ? (le panneau disparait 1 a 2 s)"; then
      if command -v kquitapp6 >/dev/null && command -v kstart >/dev/null; then
        kquitapp6 plasmashell >/dev/null 2>&1 || true
        sleep 1
        (kstart plasmashell >/dev/null 2>&1 &) 
        sleep 3
        pgrep -x plasmashell >/dev/null \
          && vert "  plasmashell recharge" \
          || rouge "  plasmashell ne s'est pas relance — lance : kstart plasmashell"
      else
        jaune "  kquitapp6/kstart absents. Deconnecte/reconnecte ta session."
      fi
    else
      echo  "      Plus tard : kquitapp6 plasmashell && kstart plasmashell"
    fi
  fi
elif [[ -d "$PROJET/plasmoid" ]] && ! command -v plasmashell >/dev/null; then
  jaune "  Plasma absent : applet non installe (sans consequence)"
fi

# --------------------------------------------------------------- redemarrage
titre "Demarrage de la chaine"
# Une installation d'avant la 1.2 laisse la chaine dans le serveur principal :
# il faut le redemarrer une fois pour que l'ancien sink disparaisse.
if [[ -f "$UNITE_ANCIENNE" ]]; then
  systemctl --user disable --now pw-surround.service 2>/dev/null || true
  rm -f "$UNITE_ANCIENNE"
  systemctl --user daemon-reload
  jaune "  ancien service pw-surround.service retire"
fi
[[ -f "$ETAT_ANCIEN" && ! -f "$ETAT" ]] && mv "$ETAT_ANCIEN" "$ETAT"
ANCIEN_TROUVE=0
for c in "${CONFS_ANCIENS[@]}"; do
  [[ -f "$c" ]] && { rm -f "$c"; ANCIEN_TROUVE=1; }
done
if (( ANCIEN_TROUVE )); then
  jaune "  ancienne configuration retiree"
  systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
  sleep 2
fi
systemctl --user enable --now spatial-sound.service 2>/dev/null \
  || jaune "  systemctl a echoue — deconnecte/reconnecte ta session."
systemctl --user restart spatial-sound.service 2>/dev/null || true

for _ in $(seq 20); do
  sleep 0.5
  pactl list sinks short 2>/dev/null | grep -q "effect_input.virtual-surround-7.1-hesuvi" && break
done

if ! pactl list sinks short 2>/dev/null | grep -q "effect_input.virtual-surround-7.1-hesuvi"; then
  rouge "  le sink virtuel n'est pas apparu."
  echo "  Diagnostic : journalctl --user -u pipewire -n 50 | grep -i 'filter\\|convolv\\|error'"
  exit 1
fi
vert "  sink « Casque Surround 7.1 » actif"

if [[ $SET_DEFAULT_SINK -eq 1 ]]; then
  pactl set-default-sink effect_input.virtual-surround-7.1-hesuvi
  vert "  defini comme sortie par defaut (ancienne : ${ANCIEN_SINK:-inconnue})"
fi

# ---------------------------------------------------------------- verification
titre "Verification"
if ! command -v pw-link >/dev/null; then
  LIENS=-1
else
  LIENS="$(pw-link -lo 2>/dev/null | grep -A1 'effect_output.virtual-surround' | grep -c '|->' || true)"
fi
if [[ "${LIENS:-0}" -eq -1 ]]; then
  jaune "  pw-link absent : liens non verifies"
elif [[ "${LIENS:-0}" -ge 2 ]]; then
  # Verifie que la sortie est connectee au bon peripherique
  CIBLE="$(pw-link -lo 2>/dev/null | grep -A1 'effect_output.virtual-surround' | grep '|->' | head -1 | sed 's/.*|-> //; s/:.*//')"
  if [[ -n "$ANCIEN_SINK" && -n "$CIBLE" && "$CIBLE" != "$ANCIEN_SINK" ]]; then
    jaune "  sortie connectee a $CIBLE au lieu de $ANCIEN_SINK"
    jaune "  Reinstalle ou corrige a la main : pw-link ..."
  else
    vert "  sortie reliee a $CIBLE ($LIENS liens)"
  fi
else
  jaune "  sortie non encore reliee — normal si aucun son ne joue."
  jaune "  Elle se connectera au premier flux audio."
fi

cat <<EOF

$(vert "Installation terminee.")

  Profil actif     : $PROFIL_DEFAUT
  Changer          : surround-profil <nom>      (sans argument : la liste)
  Mesurer          : python3 $TEST_DIR/analyse_hrir.py
  Generer un test  : cd $TEST_DIR && python3 gen_tests.py
  Desinstaller     : $PROJET/uninstall.sh

  Dans un jeu, choisis une sortie 7.1 — jamais un mode « casque » ou « HRTF »,
  qui appliquerait une seconde spatialisation par-dessus celle-ci.
EOF
