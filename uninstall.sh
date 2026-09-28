#!/usr/bin/env bash
# Retire Spatial Sound KDE et restaure la sortie audio physique.
set -euo pipefail

# « cmd | grep -q » est un piege sous « set -o pipefail » : grep ferme le tuyau
# des la premiere correspondance, le producteur meurt de SIGPIPE, et pipefail
# propage cet echec — le test echoue donc precisement quand il trouve. On
# capture la sortie avant de la tester.
contains() { [[ "$1" == *"$2"* ]]; }

HRIR_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hrir_hesuvi"
TEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/tests-surround"
HPCF_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hpcf"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d/99-spatial-sound.conf"
LEGACY_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-spatial-sound.conf"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/spatial-sound.service"
BIN="$HOME/.local/bin/surround-profil"
GEN="$HOME/.local/bin/spatial-sound-gen"
PLASMOIDS="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids"

# --tout : nom de l'option avant la 1.1, garde en alias.
ALL=0
[[ "${1-}" == "--all" || "${1-}" == "--tout" ]] && ALL=1

# Restaure la sortie d'origine, memorisee a l'installation. A defaut, on choisit
# une sortie physique en ecartant le HDMI/DisplayPort, rarement celle du casque.
STATE_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/spatial-sound.state"
PHYS=""
if [[ -f "$STATE_FILE" ]]; then
  # sink_precedent : nom de la cle avant la 1.1.
  PHYS="$(sed -n 's/^\(previous_sink\|sink_precedent\)=//p' "$STATE_FILE")"
  # Le peripherique peut avoir disparu depuis (casque USB debranche).
  contains "$(pactl list sinks short 2>/dev/null || true)" "$PHYS" || PHYS=""
fi
if [[ -z "$PHYS" ]]; then
  PHYS="$(pactl list sinks short 2>/dev/null \
          | awk '$2 ~ /^alsa_output/ && $2 !~ /hdmi|dp_|display/ {print $2; exit}')"
fi
if [[ -z "$PHYS" ]]; then
  PHYS="$(pactl list sinks short 2>/dev/null | awk '$2 ~ /^alsa_output/ {print $2; exit}')"
fi
if [[ -n "$PHYS" ]]; then
  pactl set-default-sink "$PHYS" 2>/dev/null && echo "Sortie par defaut restauree : $PHYS"
else
  echo "Aucune sortie physique trouvee — a choisir a la main dans les reglages KDE."
fi

# Arreter le service avant de retirer sa configuration.
if [[ -f "$UNIT_FILE" ]]; then
  systemctl --user disable --now spatial-sound.service 2>/dev/null || true
  systemctl --user disable --now pw-surround.service 2>/dev/null || true
  rm -fv "$UNIT_FILE"
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -fv "$CONF" "$LEGACY_CONF" "$BIN" "$GEN" \
       "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/98-spatial-sound-sink.conf"
rm -fv "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/org.spatialsound.kde.svg" \
       "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/org.pwsurround.spatialsound.svg" 2>/dev/null
# Les deux identifiants : l'actuel et celui d'avant la 1.1.
for d in "$PLASMOIDS/org.spatialsound.kde" \
         "$PLASMOIDS/org.pwsurround.spatialsound" \
         "$PLASMOIDS/org.kde.pwsurround"; do
  if [[ -d "$d" ]]; then
    rm -rf "$d"
    echo "Applet Plasma retire ($(basename "$d")) — retire-le aussi du panneau."
  fi
done
if [[ $ALL -eq 1 ]]; then
  rm -rfv "$HRIR_DIR" "$TEST_DIR" "$HPCF_DIR" "$STATE_FILE"
else
  # Etat de fonctionnement : profil de base, reglage de reverberation et fichier
  # derive. Sans ce nettoyage, une reinstallation reprendrait un reglage que
  # l'utilisateur croit avoir efface, et le derive resterait orphelin. Les noms
  # d'avant la 1.1 (.enveloppe, .derive.wav) sont retires aussi.
  rm -f "$HRIR_DIR/.base" "$HRIR_DIR/.envelope" "$HRIR_DIR/.derived.wav" \
        "$HRIR_DIR/.enveloppe" "$HRIR_DIR/.derive.wav" \
        "$HRIR_DIR/.hesuvi" "$HRIR_DIR/hrir.wav" "$HPCF_DIR/hpcf.wav" 2>/dev/null
  echo "HRIR, corrections de casque et fichiers de test conserves."
  echo "Pour tout effacer : ./uninstall.sh --all"
fi

# Meme precaution qu'a l'installation : le redemarrage de WirePlumber ne doit
# pas changer l'entree par defaut dans le dos de l'utilisateur.
SOURCE_BEFORE="$(pactl get-default-source 2>/dev/null || true)"
systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
sleep 2
if [[ -n "$SOURCE_BEFORE" && "$SOURCE_BEFORE" != "$(pactl get-default-source 2>/dev/null)" ]]; then
  pactl set-default-source "$SOURCE_BEFORE" 2>/dev/null \
    && echo "Entree par defaut restauree : $SOURCE_BEFORE"
fi
if contains "$(pactl list sinks short 2>/dev/null || true)" "spatial-sound-sink"; then
  echo "Le sink virtuel est encore la — deconnecte/reconnecte ta session."
else
  echo "Desinstallation terminee."
fi
