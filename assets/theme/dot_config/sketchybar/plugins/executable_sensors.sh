#!/usr/bin/env bash
# CPU temperature and the whole chip's power draw, from macmon, which needs no sudo; red from 85 °C.
export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"
read -r temp watts < <(macmon pipe -s 1 -i 200 2>/dev/null | jq -r '"\(.temp.cpu_temp_avg | round) \((.all_power * 10 | round) / 10)"') || exit 0
# macmon now and then returns a sample without power; the previous reading then stays.
[ "$watts" = 0 ] && exit 0
colour=$TEXT
[ "$temp" -ge 85 ] && colour=$RED
sketchybar --set "$NAME" label="${temp}° ${watts}W" label.color="$colour"
