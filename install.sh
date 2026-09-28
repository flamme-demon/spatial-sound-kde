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

# « cmd | grep -q » est un piege sous « set -o pipefail » : grep ferme le tuyau
# des la premiere correspondance, le producteur meurt de SIGPIPE, et pipefail
# propage cet echec — le test echoue donc precisement quand il trouve. On
# capture la sortie avant de la tester.
contains() { [[ "$1" == *"$2"* ]]; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HRIR_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hrir_hesuvi"
HPCF_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hpcf"
# La chaine tourne dans une instance PipeWire dediee, pas dans le serveur
# principal : la recharger pour changer de profil devient instantane et
# n'interrompt aucun autre flux audio.
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d"
CONF="$CONF_DIR/99-spatial-sound.conf"
# Le peripherique visible est declare dans le demon PRINCIPAL, pas dans notre
# instance dediee : un noeud cree par un client n'est pas enregistre aupres du
# gestionnaire de session, donc n'apparait ni dans wpctl ni dans l'applet de
# volume. Un sink du demon, lui, l'est. Il est statique — seule la chaine de
# convolution derriere lui est rechargee quand on change de profil.
CONF_SINK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
CONF_SINK="$CONF_SINK_DIR/98-spatial-sound-sink.conf"
SINK_NAME="spatial-sound-sink"
# Emplacements d'avant la 0.1.0 : charges par le serveur principal, ou sous
# l'ancien nom de fichier. Les deux doivent disparaitre, sinon deux sinks
# coexistent et le son passe par le mauvais.
LEGACY_CONFS=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-surround-casque.conf"
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-spatial-sound.conf"
  "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d/99-surround-casque.conf"
)
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/spatial-sound.service"
BIN_DIR="$HOME/.local/bin"
TEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/tests-surround"
STATE_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/spatial-sound.state"
PLASMOID_ID="org.spatialsound.kde"
PLASMOID_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$PLASMOID_ID"
# Identifiants utilises avant la 0.1.0, a nettoyer pour eviter les doublons
# dans le navigateur de widgets.
LEGACY_PLASMOIDS=(
  "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/org.kde.pwsurround"
  "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/org.pwsurround.spatialsound"
)
LEGACY_ICONS=(
  "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/org.pwsurround.spatialsound.svg"
)
LEGACY_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pw-surround.service"
LEGACY_STATE="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/pw-surround.state"

HRIR_REPO="https://github.com/loteran/arctis-virtual-surround.git"
DEFAULT_PROFILE="cmss_game"
PROFILE_GIVEN=0
SET_DEFAULT_SINK=1
INSTALL_DEPS=1
ASSUME_YES=0
HRIR_LOCAL=""

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
title()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()    { red "ERREUR : $*"; exit 1; }

usage() {
  cat <<EOF
Usage : ./install.sh [options]

  --profile <nom>    profil HRIR a appliquer (defaut : celui en place, sinon $DEFAULT_PROFILE)
  --hrir-dir <chem>  utilise un dossier de WAV HeSuVi local au lieu de telecharger
  --no-default-sink  n'impose pas le sink virtuel comme sortie par defaut
  --no-deps          n'installe aucune dependance via pacman
  -y, --yes          ne pose aucune question
  -h, --help         cette aide

Profils recommandes en jeu     : cmss_game, sonic, dtshx
Profils de salle pour le cinema : atmos, ssc_ny, ssc_syd
A eviter : dh+ et gsx, tres reverberants.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    # --profil : nom de l'option avant la 1.1, garde en alias.
    --profile|--profil) DEFAULT_PROFILE="$2"; PROFILE_GIVEN=1; shift 2 ;;
    --hrir-dir)        HRIR_LOCAL="$2"; shift 2 ;;
    --no-default-sink) SET_DEFAULT_SINK=0; shift ;;
    --no-deps)         INSTALL_DEPS=0; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "option inconnue : $1 (voir --help)" ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -rp "$1 [O/n] " r
  [[ -z "$r" || "$r" =~ ^[oOyY] ]]
}

# ---------------------------------------------------------------- verifications
title "Verification de l'environnement"

[[ $EUID -eq 0 ]] && die "ne pas lancer en root : la config est par utilisateur."

# Compare deux versions : vrai si $1 >= $2. sort -V gere les numeros multi-champs
# la ou une comparaison lexicale se tromperait (0.3.9 vs 0.3.60).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# surround-profil utilise des tableaux associatifs : bash 4 minimum.
if (( BASH_VERSINFO[0] < 4 )); then
  die "bash ${BASH_VERSION} trop ancien : bash 4.0 minimum (tableaux associatifs)."
fi

for tool in pactl paplay systemctl python3; do
  command -v "$tool" >/dev/null \
    || die "$tool introuvable — requis. (pactl/paplay : libpulse ; systemctl : systemd ; python3)"
done

SERVER="$(pactl info 2>/dev/null | sed -n 's/^Server Name: //p')"
case "$SERVER" in
  *PipeWire*) green "  PipeWire detecte : $SERVER" ;;
  "")         die "aucun serveur audio joignable. Session utilisateur active ?" ;;
  *)          red "  serveur audio : $SERVER"
              die "PulseAudio classique n'est pas supporte : ce script s'appuie sur
       module-filter-chain de PipeWire. Sous PulseAudio pur, voir
       module-virtual-surround-sink (approche differente)." ;;
esac

# 0.3.60 est le seuil ou le convolueur integre et la forme de configuration
# utilisee ici (capture.props / playback.props) se sont stabilises. En dessous,
# le module se charge mais le graphe reste muet, sans message d'erreur.
PW_MIN="0.3.60"
PW_VER="$(pipewire --version 2>/dev/null | sed -n 's/.*libpipewire \([0-9][0-9.]*\).*/\1/p' | head -1)"
if [[ -z "$PW_VER" ]]; then
  yellow "  version PipeWire indeterminee — verification ignoree ($PW_MIN attendu)"
elif version_ge "$PW_VER" "$PW_MIN"; then
  green "  version PipeWire : $PW_VER (>= $PW_MIN)"
else
  die "PipeWire $PW_VER trop ancien : $PW_MIN minimum.
       En dessous, le sink se cree mais ne produit aucun son."
fi

if [[ -z "$(find /usr/lib /usr/lib64 /usr/local/lib -name "libpipewire-module-filter-chain.so" 2>/dev/null | head -1)" ]]; then
  die "module-filter-chain absent. Installer le paquet 'pipewire-audio'."
fi
green "  module-filter-chain present"

command -v pw-link >/dev/null \
  || yellow "  pw-link absent : la verification finale des liens sera ignoree"

# ------------------------------------------------------------------ dependances
if [[ $INSTALL_DEPS -eq 1 ]]; then
  title "Dependances"
  MISSING=()
  command -v ffprobe >/dev/null || MISSING+=(ffmpeg)
  command -v git     >/dev/null || MISSING+=(git)
  python3 -c "import numpy"      2>/dev/null || MISSING+=(python-numpy)
  python3 -c "import scipy.io"   2>/dev/null || MISSING+=(python-scipy)

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    yellow "  manquant : ${MISSING[*]}"
    if command -v pacman >/dev/null; then
      if confirm "  Installer via pacman ?"; then
        sudo pacman -S --needed --noconfirm "${MISSING[@]}"
      else
        yellow "  ignore — le script de mesure et les tests peuvent echouer."
      fi
    else
      yellow "  pacman absent : installe manuellement ${MISSING[*]}"
    fi
  else
    green "  toutes presentes"
  fi
fi

# ------------------------------------------------------------------------ HRIR
title "Jeux de reponses impulsionnelles (HRIR)"
mkdir -p "$HRIR_DIR"

# Les fichiers caches (.derived.wav, profil retravaille) ne sont pas des profils.
count_wav() { find "$HRIR_DIR" -maxdepth 1 -name '*.wav' ! -name 'hrir.wav' ! -name '.*' 2>/dev/null | wc -l; }

if [[ -n "$HRIR_LOCAL" ]]; then
  [[ -d "$HRIR_LOCAL" ]] || die "dossier introuvable : $HRIR_LOCAL"
  compgen -G "$HRIR_LOCAL/*.wav" >/dev/null || die "aucun .wav dans $HRIR_LOCAL"
  # Un dossier fourni a la main contient souvent des WAV stereo : sans ce controle,
  # l'installation reussit et le sink reste muet.
  if command -v ffprobe >/dev/null; then
    n14=0
    for f in "$HRIR_LOCAL"/*.wav; do
      [[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
            -of csv=p=0 "$f" 2>/dev/null)" == "14" ]] && ((n14++)) || true
    done
    (( n14 > 0 )) || die "aucun WAV 14 canaux dans $HRIR_LOCAL.
       Le format attendu est celui de HeSuVi (14 canaux), pas des paires stereo."
    green "  $n14 fichier(s) 14 canaux valides"
  fi
  cp -f "$HRIR_LOCAL"/*.wav "$HRIR_DIR"/
  green "  copies depuis $HRIR_LOCAL"
elif [[ -d "$PROJECT_DIR/share/hrir" ]] && compgen -G "$PROJECT_DIR/share/hrir/*.wav" >/dev/null; then
  cp -f "$PROJECT_DIR/share/hrir"/*.wav "$HRIR_DIR"/
  green "  copies depuis le depot local"
elif [[ $(count_wav) -gt 10 ]]; then
  green "  deja presents ($(count_wav) profils), telechargement ignore"
else
  echo "  telechargement depuis $HRIR_REPO ..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 -q "$HRIR_REPO" "$TMP/src" \
    || die "telechargement impossible. Reessaie, ou fournis --hrir-dir <dossier>."
  find "$TMP/src" -name '*.wav' -exec cp -f {} "$HRIR_DIR"/ \;
  green "  $(count_wav) profils installes"
fi

[[ $(count_wav) -gt 0 ]] || die "aucun HRIR disponible dans $HRIR_DIR"

# Le profil demande doit exister ET faire 14 canaux (format HeSuVi attendu).
is_14ch() {
  local f="$1"
  command -v ffprobe >/dev/null || return 0   # pas de ffprobe : on fait confiance
  [[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of csv=p=0 "$f" 2>/dev/null)" == "14" ]]
}

# Une reinstallation garde le profil en place, sauf --profile explicite. Sans
# cela, hrir.wav repartait sur le profil par defaut alors que .base designait
# toujours l'ancien : l'applet affichait un profil qui n'etait plus celui qu'on
# entendait. Sans .base (installations d'avant la 0.3), on lit la cible de
# hrir.wav ; un fichier cache y serait un derive, pas un profil.
KEPT_PROFILE=0
if (( ! PROFILE_GIVEN )); then
  if [[ -f "$HRIR_DIR/.base" ]]; then
    current="$(cat "$HRIR_DIR/.base")"
  else
    current="$(basename "$(readlink -f "$HRIR_DIR/hrir.wav" 2>/dev/null || true)" .wav)"
  fi
  if [[ -n "$current" && "$current" != .* && "$current" != hrir \
        && -f "$HRIR_DIR/$current.wav" ]] && is_14ch "$HRIR_DIR/$current.wav"; then
    DEFAULT_PROFILE="$current"; KEPT_PROFILE=1
  fi
fi

if [[ ! -f "$HRIR_DIR/$DEFAULT_PROFILE.wav" ]] || ! is_14ch "$HRIR_DIR/$DEFAULT_PROFILE.wav"; then
  yellow "  '$DEFAULT_PROFILE' absent ou non 14 canaux, recherche d'un remplacant..."
  for c in cmss_game sonic atmos dtshx EAC_Default; do
    if [[ -f "$HRIR_DIR/$c.wav" ]] && is_14ch "$HRIR_DIR/$c.wav"; then
      DEFAULT_PROFILE="$c"; break
    fi
  done
  [[ -f "$HRIR_DIR/$DEFAULT_PROFILE.wav" ]] || die "aucun profil 14 canaux exploitable."
fi
# Recense les profils livres, pour distinguer ensuite ceux que l'utilisateur
# ajoute lui-meme : sans cette liste, l'applet devrait afficher les 58 fichiers
# HeSuVi, variantes inexploitables comprises.
[[ -f "$PROJECT_DIR/share/hesuvi-profiles.txt" ]] \
  && install -m644 "$PROJECT_DIR/share/hesuvi-profiles.txt" "$HRIR_DIR/.hesuvi"

# .base et hrir.wav vont ensemble : l'applet lit l'un, PipeWire l'autre.
ln -sfn "$HRIR_DIR/$DEFAULT_PROFILE.wav" "$HRIR_DIR/hrir.wav"
echo "$DEFAULT_PROFILE" > "$HRIR_DIR/.base"
if (( KEPT_PROFILE )); then
  green "  profil conserve : $DEFAULT_PROFILE"
else
  green "  profil initial : $DEFAULT_PROFILE"
fi

# -------------------------------------------------- correction de casque (HpCF)
title "Correction de casque"
mkdir -p "$HPCF_DIR"

# Avant la 1.1, l'impulsion neutre s'appelait aucune.wav. La renommer, plutot
# que d'en generer une seconde, evite qu'elle apparaisse comme un casque dans
# l'applet ; le lien actif qui la designait est reoriente.
if [[ -f "$HPCF_DIR/aucune.wav" && ! -f "$HPCF_DIR/none.wav" ]]; then
  mv "$HPCF_DIR/aucune.wav" "$HPCF_DIR/none.wav"
  [[ "$(readlink "$HPCF_DIR/hpcf.wav" 2>/dev/null)" == "$HPCF_DIR/aucune.wav" ]] \
    && ln -sfn "$HPCF_DIR/none.wav" "$HPCF_DIR/hpcf.wav"
fi

# Impulsion unite : convoluer par elle ne modifie rien. C'est la valeur « aucune
# correction », et elle doit exister meme si l'utilisateur n'installe jamais de
# filtre, car l'etage de convolution est toujours present dans le graphe.
if [[ ! -f "$HPCF_DIR/none.wav" ]]; then
  python3 - "$HPCF_DIR/none.wav" <<'IMPULSE'
import struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(struct.pack("<hh", 32767, 32767))
IMPULSE
  green "  impulsion neutre generee"
fi

# On ne choisit jamais de correction a la place de l'utilisateur : un filtre prevu
# pour un autre casque degrade le son au lieu de l'ameliorer.
[[ -e "$HPCF_DIR/hpcf.wav" ]] || ln -sfn "$HPCF_DIR/none.wav" "$HPCF_DIR/hpcf.wav"
green "  correction active : $(basename "$(readlink -f "$HPCF_DIR/hpcf.wav")" .wav)"

install -m644 "$PROJECT_DIR/share/hpcf-index.tsv" "$HPCF_DIR/index.tsv"
green "  index : $(grep -vc '^#' "$HPCF_DIR/index.tsv") casques mesures (AutoEQ)"

# ---------------------------------------------------------------- configuration
title "Configuration du sink virtuel"
mkdir -p "$CONF_DIR"

# Sortie physique de reference, vers laquelle la chaine enverra son resultat.
#
# Elle doit imperativement etre un peripherique REEL : la sortie du graphe est
# passive, donc routee par WirePlumber vers le peripherique par defaut — qui est
# desormais notre propre sink. Sans ancrage explicite, la chaine se rebranche sur
# sa propre entree et plus aucun son ne sort.
is_ours() {
  [[ "$1" == *virtual-surround* || "$1" == "$SINK_NAME" || "$1" == effect_* ]]
}
physical_output() {
  local c
  # 1. la valeur memorisee, si elle designe toujours un peripherique reel
  if [[ -f "$STATE_FILE" ]]; then
    # sink_precedent : nom de la cle avant la 1.1.
    c="$(sed -n 's/^\(previous_sink\|sink_precedent\)=//p' "$STATE_FILE")"
    if [[ -n "$c" ]] && ! is_ours "$c" && contains "$(pactl list sinks short 2>/dev/null || true)" "$c"; then
      echo "$c"; return
    fi
  fi
  # 2. la sortie par defaut actuelle, si ce n'est pas une des notres
  c="$(pactl get-default-sink 2>/dev/null || true)"
  if [[ -n "$c" ]] && ! is_ours "$c"; then echo "$c"; return; fi
  # 3. a defaut, une sortie materielle, en ecartant le HDMI qui est rarement
  #    celle du casque
  c="$(pactl list sinks short 2>/dev/null \
       | awk '$2 ~ /^alsa_output/ && $2 !~ /hdmi|dp_|display/ {print $2; exit}')"
  [[ -n "$c" ]] && { echo "$c"; return; }
  pactl list sinks short 2>/dev/null | awk '$2 ~ /^alsa_output/ {print $2; exit}'
}

PREVIOUS_SINK="$(physical_output)"
if [[ -n "$PREVIOUS_SINK" ]]; then
  printf 'previous_sink=%s\n' "$PREVIOUS_SINK" > "$STATE_FILE"
  green "  sortie physique : $PREVIOUS_SINK"
else
  red "  aucune sortie physique identifiee — la chaine n'aura pas de destination."
fi

# Graphe genere ici plutot que copie depuis /usr/share : le fichier d'exemple
# n'existe pas sur toutes les distros, et son chemin HRIR relatif ne se resout pas.
{
  cat <<'HEADER'
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
HEADER

  # 14 convolueurs : chaque enceinte virtuelle vers chaque oreille.
  # L'ordre des canaux est celui du format HeSuVi, a ne pas reorganiser.
  while read -r name channel; do
    printf '                    { type = builtin label = convolver name = %-9s config = { filename = "%s" channel = %2s } }\n' \
      "$name" "$HRIR_DIR/hrir.wav" "$channel"
  done <<'CHANNELS'
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
CHANNELS

  # Le LFE n'a pas de HRIR propre : on le traite comme le canal central.
  printf '                    { type = builtin label = convolver name = convLFE_L config = { filename = "%s" channel =  6 } }\n' "$HRIR_DIR/hrir.wav"
  printf '                    { type = builtin label = convolver name = convLFE_R config = { filename = "%s" channel = 13 } }\n' "$HRIR_DIR/hrir.wav"

  # Ligne d'ancrage optionnelle : si on a un peripherique physique de reference,
  # on empeche WirePlumber de router la sortie ailleurs (ex. USB > interne).
  ANCHOR=""
  [[ -n "$PREVIOUS_SINK" ]] && ANCHOR=$'\n                target.object  = "'"$PREVIOUS_SINK"'"'

  # Delimiteur NON quote : $ANCRE doit s'etendre plus bas. Consequence, tout ce
  # bloc subit l'expansion du shell — n'y introduire ni $, ni backquote, ni
  # antislash sans les proteger.
  cat <<FOOTER
                    { type = builtin label = mixer name = mixL }
                    { type = builtin label = mixer name = mixR }
FOOTER

  # Correction de casque (HpCF), apres la spatialisation : cet etage compense la
  # reponse du casque, il ne place rien. Il est TOUJOURS present dans le graphe et
  # pointe par defaut sur une impulsion unite, mathematiquement neutre. Cela evite
  # deux formes de configuration a maintenir : changer de correction se resume a
  # deplacer le lien symbolique hpcf.wav, exactement comme pour hrir.wav.
  printf '                    { type = builtin label = convolver name = convHP_L config = { filename = "%s" channel = 0 } }\n' "$HPCF_DIR/hpcf.wav"
  printf '                    { type = builtin label = convolver name = convHP_R config = { filename = "%s" channel = 1 } }\n' "$HPCF_DIR/hpcf.wav"

  cat <<FOOTER 
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
                    { output = "mixL:Out" input="convHP_L:In" }
                    { output = "mixR:Out" input="convHP_R:In" }
                ]
                inputs  = [ "copyFL:In" "copyFR:In" "copyFC:In" "copyLFE:In" "copyRL:In" "copyRR:In", "copySL:In", "copySR:In" ]
                outputs = [ "convHP_L:Out" "convHP_R:Out" ]
            }
            capture.props = {
                node.name      = "effect_input.virtual-surround-7.1-hesuvi"
                media.class    = Stream/Input/Audio
                stream.capture.sink = true
                target.object  = "spatial-sound-sink"
                audio.channels = 8
                audio.position = [ FL FR FC LFE RL RR SL SR ]
            }
            playback.props = {
                node.name      = "effect_output.virtual-surround-7.1-hesuvi"
                node.passive   = true
                audio.channels = 2
                audio.position = [ FL FR ]${ANCHOR:+$ANCHOR}
            }
        }
    }
]
FOOTER
} > "$CONF"
mkdir -p "$CONF_SINK_DIR"
cat > "$CONF_SINK" <<SINK
# Genere par Spatial Sound KDE — ne pas editer a la main.
# Peripherique visible du systeme. Il doit vivre dans le demon principal pour
# etre enregistre aupres du gestionnaire de session ; declare dans l'instance
# dediee, il resterait invisible de l'applet de volume.
context.objects = [
    { factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = "$SINK_NAME"
            node.description = "Casque Surround 7.1 (binaural)"
            media.class      = Audio/Sink
            audio.position   = [ FL FR FC LFE RL RR SL SR ]
            monitor.channel-volumes = true
            monitor.passthrough     = true
        }
    }
]
SINK
green "  peripherique visible : $CONF_SINK"
green "  ecrit : $CONF"

# Service dedie : c'est lui qui rend le changement de profil instantane.
mkdir -p "$(dirname "$UNIT_FILE")"
cat > "$UNIT_FILE" <<UNIT
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
green "  service spatial-sound.service ecrit"

# ------------------------------------------------------------------- outillage
title "Outils"
mkdir -p "$BIN_DIR" "$TEST_DIR"
install -m 755 "$PROJECT_DIR/bin/surround-profil" "$BIN_DIR/surround-profil"
green "  $BIN_DIR/surround-profil"
for t in analyse_hrir.py gen_tests.py; do
  [[ -f "$PROJECT_DIR/tools/$t" ]] && install -m 755 "$PROJECT_DIR/tools/$t" "$TEST_DIR/$t" && green "  $TEST_DIR/$t"
done

# Generateur de salles : facultatif, il n'est requis que pour le reglage de
# reverberation et la synthese. Sans cargo, le reste fonctionne a l'identique.
if [[ -d "$PROJECT_DIR/gen" ]]; then
  if command -v cargo >/dev/null; then
    echo "  compilation de spatial-sound-gen..."
    if (cd "$PROJECT_DIR/gen" && cargo build --release --quiet 2>/dev/null); then
      install -m755 "$PROJECT_DIR/gen/target/release/spatial-sound-gen" "$BIN_DIR/spatial-sound-gen"
      green "  $BIN_DIR/spatial-sound-gen"
    else
      yellow "  compilation echouee — reglage de reverberation indisponible"
      yellow "  (verifie que libmysofa est installe)"
    fi
  else
    yellow "  cargo absent : reglage de reverberation indisponible"
  fi
fi

# hrir.wav vient d'etre relie au profil brut : on le reconstruit avec l'enveloppe
# reglee avant la reinstallation. surround-profil est seul a savoir l'appliquer,
# et le generateur doit deja etre en place.
if "$BIN_DIR/surround-profil" --rebuild; then
  ENV_NOW="$("$BIN_DIR/surround-profil" --envelope-current)"
  if [[ "$ENV_NOW" != 0 ]]; then green "  enveloppe conservee : $ENV_NOW %"; fi
else
  yellow "  enveloppe non reappliquee — profil utilise sans amortissement"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) yellow "  $BIN_DIR n'est pas dans ton PATH."
     yellow "  Ajoute a ~/.bashrc : export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# Applet Plasma : uniquement si KDE est present, sinon c'est du poids mort.
PLASMA_OK=0
if command -v plasmashell >/dev/null; then
  # L'applet declare X-Plasma-API-Minimum-Version 6.0 et importe des modules
  # QML propres a Plasma 6 : sous Plasma 5 il s'installe mais refuse de charger.
  PLASMA_VER="$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  if [[ -z "$PLASMA_VER" ]]; then
    yellow "  version de Plasma indeterminee — applet installe sans garantie"
    PLASMA_OK=1
  elif version_ge "$PLASMA_VER" "6.0"; then
    PLASMA_OK=1
  else
    yellow "  Plasma $PLASMA_VER : l'applet exige Plasma 6, installation ignoree"
    yellow "  (le reste fonctionne, utilise « surround-profil » en ligne de commande)"
  fi
fi

if [[ -d "$PROJECT_DIR/plasmoid" ]] && (( PLASMA_OK == 1 )); then
  for legacy in "${LEGACY_PLASMOIDS[@]}"; do
    if [[ -d "$legacy" ]]; then
      rm -rf "$legacy"
      yellow "  ancien applet $(basename "$legacy") retire — a re-ajouter au panneau"
    fi
  done
  rm -f "${LEGACY_ICONS[@]}"
  # Les catalogues .mo sont generes ici, pas versionnes : ils derivent des .po.
  [[ -x "$PROJECT_DIR/plasmoid/build-translations.sh" ]] \
    && "$PROJECT_DIR/plasmoid/build-translations.sh" >/dev/null 2>&1 || true
  rm -rf "$PLASMOID_DIR"
  mkdir -p "$PLASMOID_DIR"
  cp -rp "$PROJECT_DIR/plasmoid/." "$PLASMOID_DIR"/
  rm -rf "$PLASMOID_DIR/po" "$PLASMOID_DIR/build-translations.sh"

  # L'icone doit vivre dans un theme, pas seulement dans le paquet : le
  # navigateur de widgets resout un NOM d'icone et ignore les chemins relatifs.
  ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  mkdir -p "$ICON_DIR"
  install -m644 "$PROJECT_DIR/plasmoid/contents/icons/spatial-sound.svg" \
    "$ICON_DIR/org.spatialsound.kde.svg"
  command -v gtk-update-icon-cache >/dev/null \
    && gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
  green "  icone deposee dans le theme hicolor"
  LANGUAGES="$(find "$PLASMOID_DIR/contents/locale" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
  green "  applet Plasma installe (langues : en ${LANGUAGES:-})"
  echo "    Ajoute-le : clic droit sur le bureau ou le panneau -> Ajouter des widgets"
  echo "    -> chercher « Spatial Sound »"

  # Installer les fichiers ne suffit pas : plasmashell garde en memoire le QML
  # et les icones deja charges. Sans rechargement, une mise a jour de l'applet
  # reste invisible — y compris une icone corrigee, qui continue d'afficher « ? ».
  if pgrep -x plasmashell >/dev/null 2>&1; then
    # Comparaison par age en secondes plutot que par date : « ps -o lstart »
    # est localise, et « date -d » refuse de le relire dans certaines langues.
    PID_PS="$(pgrep -x plasmashell | head -1)"
    AGE_PS="$(ps -o etimes= -p "$PID_PS" 2>/dev/null | tr -d ' ')"
    STARTED_PS=$(( $(date +%s) - ${AGE_PS:-0} ))
    QML_MTIME="$(stat -c %Y "$PLASMOID_DIR/contents/ui/main.qml" 2>/dev/null || echo 0)"
    if (( STARTED_PS > QML_MTIME )); then
      green "  plasmashell a deja cette version en memoire"
      PLASMA_UP_TO_DATE=1
    else
      PLASMA_UP_TO_DATE=0
      yellow "  plasmashell tourne depuis $(( AGE_PS / 60 )) min, avec une version anterieure."
      yellow "  Il faut le recharger pour voir celle-ci."
    fi
  else
    PLASMA_UP_TO_DATE=1
  fi

  if [[ "${PLASMA_UP_TO_DATE:-1}" -eq 0 ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      yellow "  Mode non interactif : rechargement non effectue. Lance a la main :"
      echo  "      kquitapp6 plasmashell && kstart plasmashell"
    elif confirm "  Recharger plasmashell maintenant ? (le panneau disparait 1 a 2 s)"; then
      if command -v kquitapp6 >/dev/null && command -v kstart >/dev/null; then
        kquitapp6 plasmashell >/dev/null 2>&1 || true
        sleep 1
        (kstart plasmashell >/dev/null 2>&1 &) 
        sleep 3
        pgrep -x plasmashell >/dev/null \
          && green "  plasmashell recharge" \
          || red "  plasmashell ne s'est pas relance — lance : kstart plasmashell"
      else
        yellow "  kquitapp6/kstart absents. Deconnecte/reconnecte ta session."
      fi
    else
      echo  "      Plus tard : kquitapp6 plasmashell && kstart plasmashell"
    fi
  fi
elif [[ -d "$PROJECT_DIR/plasmoid" ]] && ! command -v plasmashell >/dev/null; then
  yellow "  Plasma absent : applet non installe (sans consequence)"
fi

# --------------------------------------------------------------- redemarrage
title "Demarrage de la chaine"
# Une installation d'avant la 1.2 laisse la chaine dans le serveur principal :
# il faut le redemarrer une fois pour que l'ancien sink disparaisse.
if [[ -f "$LEGACY_UNIT" ]]; then
  systemctl --user disable --now pw-surround.service 2>/dev/null || true
  rm -f "$LEGACY_UNIT"
  systemctl --user daemon-reload
  yellow "  ancien service pw-surround.service retire"
fi
[[ -f "$LEGACY_STATE" && ! -f "$STATE_FILE" ]] && mv "$LEGACY_STATE" "$STATE_FILE"
LEGACY_FOUND=0
for c in "${LEGACY_CONFS[@]}"; do
  [[ -f "$c" ]] && { rm -f "$c"; LEGACY_FOUND=1; }
done
if (( LEGACY_FOUND )) || [[ ! "$(pactl list sinks short 2>/dev/null)" == *"$SINK_NAME"* ]]; then
  (( LEGACY_FOUND )) && yellow "  ancienne configuration retiree"
  # WirePlumber reevalue ses regles de routage au redemarrage. Il restaure
  # normalement l'entree choisie par l'utilisateur, mais rien ne le garantit
  # sur toutes les configurations — et une entree changee en silence se
  # remarque au pire moment. On la remet donc explicitement.
  SOURCE_BEFORE="$(pactl get-default-source 2>/dev/null || true)"
  systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
  sleep 2
  if [[ -n "$SOURCE_BEFORE" && "$SOURCE_BEFORE" != "$(pactl get-default-source 2>/dev/null)" ]]; then
    pactl set-default-source "$SOURCE_BEFORE" 2>/dev/null \
      && yellow "  entree par defaut restauree : $SOURCE_BEFORE"
  fi
fi
# Un service bloque par la limite de demarrages de systemd (bascules trop
# rapprochees avec une version anterieure) refuserait de repartir : relancer
# l'installation doit suffire a retrouver le son.
systemctl --user reset-failed spatial-sound.service 2>/dev/null || true
systemctl --user enable --now spatial-sound.service 2>/dev/null \
  || yellow "  systemctl a echoue — deconnecte/reconnecte ta session."
systemctl --user restart spatial-sound.service 2>/dev/null || true

for _ in $(seq 20); do
  sleep 0.5
  contains "$(pactl list sinks short 2>/dev/null || true)" "$SINK_NAME" && break
done

if ! contains "$(pactl list sinks short 2>/dev/null || true)" "$SINK_NAME"; then
  red "  le sink virtuel n'est pas apparu."
  echo "  Diagnostic : journalctl --user -u pipewire -n 50 | grep -i 'filter\\|convolv\\|error'"
  exit 1
fi
green "  sink « Casque Surround 7.1 » actif"

# Migration depuis l'architecture d'avant la 0.4 : le peripherique par defaut
# etait alors le noeud de la chaine elle-meme, qui n'est plus un sink. Laisse tel
# quel, le systeme n'aurait plus aucune sortie valide.
CURRENT_DEFAULT="$(pactl get-default-sink 2>/dev/null || true)"
if [[ "$CURRENT_DEFAULT" == *virtual-surround* || "$CURRENT_DEFAULT" == effect_* ]]; then
  yellow "  ancien peripherique par defaut detecte : $CURRENT_DEFAULT"
  pactl set-default-sink "$SINK_NAME" 2>/dev/null \
    && green "  bascule sur le nouveau peripherique" \
    || red "  bascule impossible — choisis « Casque Surround 7.1 » a la main"
fi

if [[ $SET_DEFAULT_SINK -eq 1 ]]; then
  pactl set-default-sink "$SINK_NAME"
  green "  defini comme sortie par defaut (ancienne : ${PREVIOUS_SINK:-inconnue})"
fi

# ---------------------------------------------------------------- verification
title "Verification"
if ! command -v pw-link >/dev/null; then
  LINKS=-1
else
  LINKS="$(pw-link -lo 2>/dev/null | grep -A1 'effect_output.virtual-surround' | grep -c '|->' || true)"
fi
if [[ "${LINKS:-0}" -eq -1 ]]; then
  yellow "  pw-link absent : liens non verifies"
elif [[ "${LINKS:-0}" -ge 2 ]]; then
  # Verifie que la sortie est connectee au bon peripherique
  TARGET="$(pw-link -lo 2>/dev/null | grep -A1 'effect_output.virtual-surround' | grep '|->' | head -1 | sed 's/.*|-> //; s/:.*//')"
  if [[ -n "$PREVIOUS_SINK" && -n "$TARGET" && "$TARGET" != "$PREVIOUS_SINK" ]]; then
    yellow "  sortie connectee a $TARGET au lieu de $PREVIOUS_SINK"
    yellow "  Reinstalle ou corrige a la main : pw-link ..."
  else
    green "  sortie reliee a $TARGET ($LINKS liens)"
  fi
else
  yellow "  sortie non encore reliee — normal si aucun son ne joue."
  yellow "  Elle se connectera au premier flux audio."
fi

# Verification du chemin complet. Chaque point a deja casse au moins une fois :
# un sink invisible du gestionnaire de session, une entree non capturee, et une
# sortie rebouclee sur notre propre entree — silence total dans les trois cas.
title "Verification de la chaine"
CHECKS_OK=1

if contains "$(pactl list sinks short 2>/dev/null || true)" "$SINK_NAME"; then
  green "  peripherique present"
else
  red "  peripherique absent"; CHECKS_OK=0
fi

if command -v wpctl >/dev/null; then
  # Le gestionnaire de session adopte le noeud avec un leger retard apres le
  # demarrage du demon : sans attente, le controle echoue a tort.
  SEEN=0
  for _ in $(seq 20); do
    contains "$(wpctl status 2>/dev/null || true)" "Casque Surround 7.1" && { SEEN=1; break; }
    sleep 0.25
  done
  if (( SEEN )); then
    green "  visible du gestionnaire de session (donc de l'applet de volume)"
  else
    yellow "  invisible du gestionnaire de session — l'applet de volume ne le listera pas"
    CHECKS_OK=0
  fi
fi

if command -v pw-link >/dev/null; then
  if contains "$(pw-link -l 2>/dev/null | grep -A1 "$SINK_NAME:monitor_FL" || true)" "effect_input"; then
    green "  entree de la chaine reliee au peripherique"
  else
    yellow "  entree non reliee — elle se connectera au premier flux audio"
  fi

  DEST="$(pw-link -lo 2>/dev/null | grep -A1 'effect_output.virtual-surround' \
          | grep '|->' | head -1 | sed 's/.*|-> //; s/:.*//')"
  if [[ -z "$DEST" ]]; then
    yellow "  sortie non encore reliee — normal si aucun son ne joue"
  elif [[ "$DEST" == "$SINK_NAME" || "$DEST" == effect_* ]]; then
    red "  BOUCLE : la sortie revient sur notre propre entree ($DEST)"
    red "  Aucun son ne sortira. Signale-le, c'est un defaut de l'installation."
    CHECKS_OK=0
  elif [[ -n "$PREVIOUS_SINK" && "$DEST" != "$PREVIOUS_SINK" ]]; then
    yellow "  sortie vers $DEST au lieu de $PREVIOUS_SINK"
  else
    green "  sortie vers le peripherique physique : $DEST"
  fi
fi

(( CHECKS_OK )) || yellow "  Des points ci-dessus ont echoue : relance ./install.sh, ou ouvre une issue."

cat <<EOF

$(green "Installation terminee.")

  Profil actif     : $DEFAULT_PROFILE
  Changer          : surround-profil <nom>      (sans argument : la liste)
  Mesurer          : python3 $TEST_DIR/analyse_hrir.py
  Generer un test  : cd $TEST_DIR && python3 gen_tests.py
  Desinstaller     : $PROJECT_DIR/uninstall.sh

  Dans un jeu, choisis une sortie 7.1 — jamais un mode « casque » ou « HRTF »,
  qui appliquerait une seconde spatialisation par-dessus celle-ci.
EOF
