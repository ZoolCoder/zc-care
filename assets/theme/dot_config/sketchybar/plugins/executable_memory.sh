#!/usr/bin/env bash
# Used memory as Activity Monitor counts it: app, wired and compressed pages.
PAGE="$(sysctl -n hw.pagesize)"
TOTAL="$(sysctl -n hw.memsize)"
USED="$(vm_stat | awk '/Anonymous pages|Pages wired down|Pages occupied by compressor/ {gsub("\\.", "", $NF); s += $NF} END {print s}')"
sketchybar --set "$NAME" label="$((USED * PAGE * 100 / TOTAL))%"
