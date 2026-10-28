#!/bin/sh
# Puts the fonts Flutter's web engine falls back to (emoji, symbols, scripts the app's own font
# lacks) next to a web build, so the hub serves them and the page never asks fonts.gstatic.com
# (the hub's Content-Security-Policy wouldn't let it). The web app looks for them under
# fonts/fallback/ (app/web/flutter_bootstrap.js).
#
# Usage: fallback_fonts.sh <build/web> [pattern] [--list]
#   pattern  an extended regex over the font paths to fetch; by default emoji, symbols, math
#            and Noto Sans (Latin, Greek, Cyrillic), the ones a family's names and titles
#            need most. '.' fetches every script (much larger).
#   --list   prints the matching paths without fetching anything.
set -eu

web="$1"
pattern="${2:-^(roboto|notocoloremoji|notoemoji|notosanssymbols|notosanssymbols2|notosansmath|notosans)/}"
list="${3:-}"
out="$web/fonts/fallback"

# The engine names each font by its path under https://fonts.gstatic.com/s/, as a string in
# the compiled app: notocoloremoji/v32/Yq6P-....0.woff2, notosans/v37/o-0mIpQl....ttf.
paths=$(grep -ohE '[a-z0-9]+/v[0-9]+/[A-Za-z0-9_-]+(\.[0-9]+)?\.(ttf|otf|woff2)' "$web"/main.dart*.js | sort -u | grep -E "$pattern" || true)
count=$(printf '%s\n' "$paths" | grep -c . || true)
if [ "$count" -eq 0 ]; then
  echo "No fallback fonts found in $web/main.dart.js: has Flutter changed how it names them?" >&2
  exit 1
fi
if [ "$list" = "--list" ]; then
  printf '%s\n' "$paths"
  exit 0
fi

for path in $paths; do
  mkdir -p "$out/$(dirname "$path")"
  curl -fsSL --retry 3 --retry-delay 2 -o "$out/$path" "https://fonts.gstatic.com/s/$path"
done
echo "Fallback fonts: $count files, $(du -sh "$out" | cut -f1), in $out"
