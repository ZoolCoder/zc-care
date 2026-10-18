# ZoolCoder colours for the shell's tools. ~/.zshrc.local sources this after zshrc, so these settings win.
# Ghostty is always dark; elsewhere the macOS appearance at shell start picks dark or light.
# delta needs ~/.config/git/zoolcoder-delta.gitconfig included from your gitconfig.
export BAT_THEME_DARK="ZoolCoder Dark" BAT_THEME_LIGHT="ZoolCoder Light"
unset STARSHIP_CONFIG LG_CONFIG_FILE
unalias btop 2>/dev/null
if [[ -n $GHOSTTY_RESOURCES_DIR || $(defaults read -g AppleInterfaceStyle 2>/dev/null) == Dark ]]; then
  export FZF_DEFAULT_OPTS="--color=bg+:#161a22,spinner:#9cc3ff,hl:#3d7bff,fg:#f3f5f7,header:#9cc3ff \
--color=info:#9aa2ad,pointer:#3d7bff,marker:#5fd38a,fg+:#f3f5f7,prompt:#3d7bff,hl+:#9cc3ff \
--color=selected-bg:#2b313d,border:#2b313d,label:#b9bfc8"
  export EZA_CONFIG_DIR="$HOME/.config/eza" DELTA_FEATURES="zoolcoder-dark" K9S_SKIN="zoolcoder-dark"
else
  export FZF_DEFAULT_OPTS="--color=bg+:#e3e3dc,spinner:#1a45c2,hl:#2457e6,fg:#111318,header:#1a45c2 \
--color=info:#646973,pointer:#2457e6,marker:#0b7f4a,fg+:#111318,prompt:#2457e6,hl+:#1a45c2 \
--color=selected-bg:#cbcbc2,border:#cbcbc2,label:#4a4f59"
  # The same prompt with the light palette, regenerated when starship.toml changes.
  export STARSHIP_CONFIG="$HOME/.cache/zsh/starship-light.toml"
  [[ $STARSHIP_CONFIG -nt ~/.config/starship.toml ]] || sed "s/^palette = 'zoolcoder_dark'/palette = 'zoolcoder_light'/" ~/.config/starship.toml > $STARSHIP_CONFIG
  export EZA_CONFIG_DIR="$HOME/.config/eza/light" DELTA_FEATURES="zoolcoder-light" K9S_SKIN="zoolcoder-light"
  # lazygit merges the listed files, so the light colours override the dark ones in its config.
  export LG_CONFIG_FILE="$HOME/Library/Application Support/lazygit/config.yml,$HOME/Library/Application Support/lazygit/light.yml"
  alias btop="btop -c ~/.config/btop/btop-light.conf"
fi
# The prompt a command leaves behind once it runs, in ZoolCoder blue.
_transient_prompt() {
  _full_prompt=$PROMPT _full_rprompt=$RPROMPT
  PROMPT='%F{#3d7bff}◥◣%f %F{#9aa2ad}%D{%H:%M}%f %F{#5fd38a}❯%f ' RPROMPT=''
  zle .reset-prompt
}
