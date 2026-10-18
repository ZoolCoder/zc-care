#!/usr/bin/env bash
CORES="$(sysctl -n hw.ncpu)"
sketchybar --set "$NAME" label="$(ps -A -o %cpu | awk -v c="$CORES" '{s+=$1} END {printf "%.0f%%", s/c}')"
