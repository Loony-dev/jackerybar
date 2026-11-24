#!/bin/zsh
# Regenerates README screenshots (demo data only) into docs/screenshots.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build docs/screenshots
swiftc -swift-version 5 -target $(uname -m)-apple-macos14 -o build/render Sources/Core/*.swift Sources/UI/*.swift
B=build/render
D=docs/screenshots
for lang in uk en; do
  E=(); [[ $lang == en ]] && E=(en)
  $B --render $D/menubar-$lang.png $E
  $B --render-panel $D/panel-$lang.png dark $E
  $B --render-panel $D/panel-light-$lang.png $E
  $B --render-panel $D/chart-$lang.png dark metric battery $E
  $B --render-panel $D/chart30-$lang.png dark metric soc range 2592000 $E
  $B --render-panel $D/outages-$lang.png dark outages $E
  $B --render-panel $D/outage-$lang.png dark outage $E
  $B --render-panel $D/stats-$lang.png dark stats $E
  $B --render-panel $D/control-$lang.png dark control $E
  $B --render-panel $D/schedule-$lang.png dark schedule $E
  $B --render-panel $D/queue-$lang.png dark queue $E
  $B --render-panel $D/settings-$lang.png dark settings $E
done
echo "Screenshots written to $D"
