#!/usr/bin/env bash
# Recolours the bar, the window borders and tmux when macOS switches between light and dark mode.
[ "$SENDER" = theme_changed ] || exit 0
export PATH="/opt/homebrew/bin:$PATH"
"$HOME/.config/borders/bordersrc"
sketchybar --reload
# tmux follows only while its server runs; a new server reads the mode at start.
tmux info >/dev/null 2>&1 && "$HOME/.config/tmux/theme.sh"
