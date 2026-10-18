#!/bin/sh
# Draws wallpaper.html to PNG with headless Chrome, dark and light, in two
# sizes: 3024x1964 for a 14-inch MacBook Pro (laptop, committed) and
# 5120x3200 for 16:10 and 5K displays (5k, ignored by git).
# Usage: assets/wallpaper/render.sh [chrome binary]
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
chrome=${1:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
for size in laptop:1512,982 5k:2560,1600; do
  for v in dark light; do
    q=; [ "$v" = light ] && q='?light'
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
      --virtual-time-budget=3000 --window-size="${size#*:}" --force-device-scale-factor=2 \
      --screenshot="$dir/zc-care-${size%%:*}-$v.png" "file://$dir/wallpaper.html$q" 2>/dev/null
  done
done
ls -la "$dir"/*.png
