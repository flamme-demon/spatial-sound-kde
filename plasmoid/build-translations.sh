#!/usr/bin/env bash
# Compile les catalogues po/*.po vers contents/locale/, ou Plasma va les chercher.
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINE="plasma_applet_$(sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' "$ICI/metadata.json")"

command -v msgfmt >/dev/null || { echo "msgfmt absent (paquet gettext)." >&2; exit 1; }

for po in "$ICI"/po/*.po; do
  [[ -e "$po" ]] || { echo "aucun catalogue dans po/"; exit 0; }
  lang="$(basename "$po" .po)"
  dest="$ICI/contents/locale/$lang/LC_MESSAGES"
  mkdir -p "$dest"
  msgfmt --check --statistics -o "$dest/$DOMAINE.mo" "$po"
  echo "  $lang -> $dest/$DOMAINE.mo"
done
