#!/bin/zsh
# Regenerates README screenshots (demo data only) into docs/screenshots.
set -euo pipefail
cd "${0:A:h}/.."
./build.sh >/dev/null
B=build/JackeryBar.app/Contents/MacOS/JackeryBar
D=docs/screenshots
mkdir -p $D
for lang in uk en; do
  E=(); [[ $lang == en ]] && E=(en)
  $B --render $D/menubar-$lang.png $E
  $B --render-panel $D/panel-$lang.png dark $E
  $B --render-panel $D/panel-light-$lang.png $E
  $B --render-panel $D/chart-$lang.png dark detail battery $E
  $B --render-panel $D/outages-$lang.png dark outages $E
  $B --render-panel $D/outage-$lang.png dark outage $E
  $B --render-panel $D/settings-$lang.png dark settings $E
done
echo "Screenshots written to $D"
