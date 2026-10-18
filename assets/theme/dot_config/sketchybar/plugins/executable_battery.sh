#!/usr/bin/env bash
PERCENT="$(pmset -g batt | grep -Eo '[0-9]+%' | tr -d '%')"
[ -z "$PERCENT" ] && exit 0
if pmset -g batt | grep -q 'AC Power'; then ICON=󰂄
elif [ "$PERCENT" -gt 80 ]; then ICON=󰁹
elif [ "$PERCENT" -gt 50 ]; then ICON=󰂀
elif [ "$PERCENT" -gt 20 ]; then ICON=󰁾
else ICON=󰁺
fi
sketchybar --set "$NAME" icon="$ICON" label="${PERCENT}%"
