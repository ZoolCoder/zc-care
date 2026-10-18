#!/usr/bin/env bash
# ZoolCoder colours for tmux: dark when the server was started in Ghostty, which is always dark, or in dark mode;
# light in light mode elsewhere. The server's environment is asked, as SketchyBar runs this again from outside it.
if tmux show-environment -g GHOSTTY_RESOURCES_DIR >/dev/null 2>&1 || [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ]; then
  base="#05060a" surface="#161A22" faint="#2b313d" dim="#9aa2ad" text="#f3f5f7" subtext="#b9bfc8" accent="#3d7bff"
  blue="#9cc3ff" teal="#5fd3c6" green="#5fd38a" peach="#f5b44a" red="#ff7a7e"
else
  base="#f7f7f4" surface="#e3e3dc" faint="#cbcbc2" dim="#646973" text="#111318" subtext="#4a4f59" accent="#2457e6"
  blue="#1a45c2" teal="#0B7F7A" green="#0b7f4a" peach="#b35c00" red="#c2262c"
fi
# A Claude session titles its pane "<glyph> <label>"; the tab shows that title in place of "index name".
# fnmatch compares bytes, so a bracket class cannot hold the glyphs: three tests.
claude_red='#{m:🔴*,#{pane_title}}'
claude_title="#{||:$claude_red,#{||:#{m:🔵*,#{pane_title}},#{m:✅*,#{pane_title}}}}"
# A bell (which every attention event rings) paints the tab peach with window-status-bell-style; the red applies
# only while the bell flag is clear, so the two never mix.
claude_red_plain="#{&&:$claude_red,#{==:#{window_bell_flag},0}}"
# Neon HUD, like the Claude Code status line and the prompt: ◢◤ caps, dim labels, bright values, ⟩ separators.
usage="#($HOME/.config/tmux/usage.sh '$dim' '$faint' '$green' '$peach' '$red')"
tmux set -g status-style "bg=$base,fg=$text" \; \
  set -g status-left "#[fg=$accent,bold]◢#[fg=$blue]◤ #[fg=$text]#S #[fg=$faint,nobold]⟩ " \; \
  set -g status-right "#{?client_prefix,#[fg=$peach#,bold]PREFIX #[fg=$faint#,nobold]⟩ ,}$usage#[fg=$dim]DIR #[fg=$subtext]#{b:pane_current_path} #[fg=$faint]⟩ #[fg=$blue,bold]%H:%M #[fg=$blue]◥#[fg=$teal]◣" \; \
  setw -g window-status-separator "" \; \
  setw -g window-status-format "#[fg=$dim] #I #[fg=$subtext]#{?$claude_title,#{?$claude_red_plain,#[fg=$red],}#{pane_title},#W} " \; \
  setw -g window-status-current-format "#[fg=$accent,bold]▸#I #[fg=$text]#{?$claude_title,#{?$claude_red_plain,#[fg=$red],}#{pane_title},#W}#[fg=$accent]◂" \; \
  setw -g window-status-bell-style "fg=$peach,bold" \; \
  set -g pane-border-style "fg=$surface" \; \
  set -g pane-active-border-style "fg=$accent" \; \
  set -g pane-border-lines heavy \; \
  set -g message-style "bg=$surface,fg=$text" \; \
  set -g popup-border-style "fg=$accent" \; \
  set -g popup-border-lines rounded \; \
  setw -g mode-style "bg=$surface,fg=$text"
