#!/usr/bin/env bash
# Retire Spatial Sound KDE et restaure la sortie audio physique.
set -euo pipefail

HRIR_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hrir_hesuvi"
TEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/tests-surround"
HPCF_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/hpcf"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/filter-chain.conf.d/99-spatial-sound.conf"
CONF_ANCIEN="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-spatial-sound.conf"
UNITE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/spatial-sound.service"
BIN="$HOME/.local/bin/surround-profil"
PLASMOIDS="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids"

TOUT=0
[[ "${1-}" == "--tout" ]] && TOUT=1

# Restaure la sortie d'origine, memorisee a l'installation. A defaut, on choisit
# une sortie physique en ecartant le HDMI/DisplayPort, rarement celle du casque.
ETAT="${XDG_DATA_HOME:-$HOME/.local/share}/pipewire/spatial-sound.state"
PHYS=""
if [[ -f "$ETAT" ]]; then
  PHYS="$(sed -n 's/^sink_precedent=//p' "$ETAT")"
  # Le peripherique peut avoir disparu depuis (casque USB debranche).
  pactl list sinks short 2>/dev/null | grep -qw -- "$PHYS" || PHYS=""
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
if [[ -f "$UNITE" ]]; then
  systemctl --user disable --now spatial-sound.service 2>/dev/null || true
  systemctl --user disable --now pw-surround.service 2>/dev/null || true
  rm -fv "$UNITE"
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -fv "$CONF" "$CONF_ANCIEN" "$BIN"
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
if [[ $TOUT -eq 1 ]]; then
  rm -rfv "$HRIR_DIR" "$TEST_DIR" "$HPCF_DIR" "$ETAT"
else
  echo "HRIR, corrections de casque et fichiers de test conserves."
  echo "Pour tout effacer : ./uninstall.sh --tout"
fi

# Meme precaution qu'a l'installation : le redemarrage de WirePlumber ne doit
# pas changer l'entree par defaut dans le dos de l'utilisateur.
SOURCE_AVANT="$(pactl get-default-source 2>/dev/null || true)"
systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
sleep 2
if [[ -n "$SOURCE_AVANT" && "$SOURCE_AVANT" != "$(pactl get-default-source 2>/dev/null)" ]]; then
  pactl set-default-source "$SOURCE_AVANT" 2>/dev/null \
    && echo "Entree par defaut restauree : $SOURCE_AVANT"
fi
if pactl list sinks short 2>/dev/null | grep -q "effect_input.virtual-surround"; then
  echo "Le sink virtuel est encore la — deconnecte/reconnecte ta session."
else
  echo "Desinstallation terminee."
fi
