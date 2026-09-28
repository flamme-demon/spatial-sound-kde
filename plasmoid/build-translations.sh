#!/usr/bin/env bash
# Compile les catalogues po/*.po vers contents/locale/, ou Plasma va les chercher.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="plasma_applet_$(sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' "$HERE/metadata.json")"

command -v msgfmt >/dev/null || { echo "msgfmt absent (paquet gettext)." >&2; exit 1; }

for po in "$HERE"/po/*.po; do
  [[ -e "$po" ]] || { echo "aucun catalogue dans po/"; exit 0; }
  lang="$(basename "$po" .po)"
  dest="$HERE/contents/locale/$lang/LC_MESSAGES"
  mkdir -p "$dest"
  msgfmt --check --statistics -o "$dest/$DOMAIN.mo" "$po"
  echo "  $lang -> $dest/$DOMAIN.mo"
done
