#!/usr/bin/env bash
# usage.sh: Claude's 5-hour and weekly limits for the tmux status bar, HUD style ("LIM 5H 10% ⟩ WK 97%"), read from
# the usage cache the Claude Code status line keeps fresh. Prints nothing without it.
# Usage: usage.sh <label colour> <separator colour> <ok colour> <warn colour> <full colour>
cache="/private/tmp/claude-$(id -u)/usage-cache.json"
[[ -r $cache ]] || exit 0
jq -r --arg dim "$1" --arg sep "$2" --arg ok "$3" --arg warn "$4" --arg full "$5" '
  def lim(k): (.limits // []) | map(select(.kind == k)) | first | .percent // empty;
  def show(name; p): "#[fg=\($dim)]\(name) #[fg=\(if p >= 90 then $full elif p >= 75 then $warn else $ok end)]\(p | round)%";
  [ (lim("session") | show("LIM 5H"; .)), (lim("weekly_all") | show("WK"; .)) ]
  | select(length > 0) | join(" #[fg=\($sep)]⟩ ") + " #[fg=\($sep)]⟩ "' "$cache" 2>/dev/null
