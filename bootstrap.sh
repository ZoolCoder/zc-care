#!/usr/bin/env bash
# Sets up a new Mac from a config repo in one run: installs Homebrew, ZC Care and the zc-care CLI it
# carries, clones zc-care and the config repo into ~/Developer/Tools, then applies the config.
# Usage: bootstrap.sh OWNER/CONFIG-REPO
#   curl -fsSL https://raw.githubusercontent.com/ZoolCoder/zc-care/main/bootstrap.sh | bash -s -- OWNER/CONFIG-REPO
# Safe to run again: what is already there is kept, an existing clone is fast-forwarded, and apply
# only changes what differs.
set -euo pipefail

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
# -r /dev/tty is true with no controlling terminal; opening it is the real test.
have_tty() { ( : </dev/tty ) 2>/dev/null; }

# Brings a clone up to date; when it cannot fast-forward it says so and keeps the clone.
update_clone() {
  local dir=$1
  if git -C "$dir" pull --ff-only --quiet </dev/null; then
    echo "Updated $dir"
  else
    echo "Could not fast-forward $dir (local changes or a diverged branch); keeping it as it is." >&2
  fi
}

load_brew() {
  local brew_bin
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $brew_bin ]]; then
      eval "$("$brew_bin" shellenv)"
      return 0
    fi
  done
  echo "Homebrew is not installed where expected (/opt/homebrew or /usr/local)." >&2
  return 1
}

# The whole script is one function called on the last line, so under curl | bash
# bash has read all of it before anything runs and no command can eat the rest
# of the script from stdin.
main() {
  local config_repo=${1:-${ZC_CONFIG_REPO:-}}
  [[ -n $config_repo ]] || { echo "usage: bootstrap.sh OWNER/CONFIG-REPO" >&2; exit 1; }
  [[ $(uname -s) == Darwin ]] || { echo "bootstrap.sh is for macOS only." >&2; exit 1; }

  local tools="$HOME/Developer/Tools"
  local tool_dir="$tools/zc-care"
  local config_dir="$tools/$(basename "$config_repo")"
  # Clone sources; the VM test points these at mounted copies.
  local tool_from=${ZC_TOOL_FROM:-https://github.com/ZoolCoder/zc-care.git}
  local config_from=${ZC_CONFIG_FROM:-}

  if ! command -v brew >/dev/null && [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]]; then
    step "Installing Homebrew (asks for your password; also installs the Xcode command line tools)"
    # Installer pinned to a commit; bump with: git ls-remote https://github.com/Homebrew/install.git HEAD
    # The installer asks questions: give it the terminal, not the piped script.
    if have_tty; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/a2fe82ef3a9ec7a5c72a559c09676256d6f354f6/install.sh)" </dev/tty
    else
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/a2fe82ef3a9ec7a5c72a559c09676256d6f354f6/install.sh)" </dev/null
    fi
  fi
  load_brew

  step "Installing what zc-care needs"
  brew install git gh chezmoi mise </dev/null

  if [[ -z $config_from ]]; then
    # The config repo is usually private, so git needs a GitHub login first.
    if ! gh auth status >/dev/null 2>&1 </dev/null; then
      # The login opens a browser and waits on the terminal for a code.
      have_tty || { echo "Run 'gh auth login' first, then run bootstrap again." >&2; exit 1; }
      step "Logging in to GitHub"
      gh auth login --git-protocol https --web </dev/tty
    fi
    gh auth setup-git </dev/null
    config_from="https://github.com/$config_repo.git"
  fi

  mkdir -p "$tools"
  local pair from dir
  for pair in "$tool_from|$tool_dir" "$config_from|$config_dir"; do
    from=${pair%%|*} dir=${pair#*|}
    if [[ -d $dir/.git ]]; then
      step "Updating $dir"
      update_clone "$dir"
    elif [[ -e $dir ]]; then
      echo "$dir exists but is not a git clone; move it away and run bootstrap again." >&2
      exit 1
    else
      step "Cloning $from"
      git clone --quiet "$from" "$dir" </dev/null
    fi
  done

  # ZC Care carries the CLI and its cask puts it on PATH. Before a release has
  # the cask, as in a VM test of a local copy, it is built from the clone.
  step "Installing ZC Care and zc-care"
  local cask_log
  cask_log=$(mktemp)
  trap 'rm -f "$cask_log"' EXIT
  if ! { brew tap zoolcoder/zc-care https://github.com/zoolcoder/zc-care \
         && brew install --cask zc-care; } >"$cask_log" 2>&1 </dev/null; then
    echo "The cask install failed, building from source instead. Why:" >&2
    sed 's/^/  /' "$cask_log" >&2
    # A half-installed cask would shadow the build with a broken link on PATH.
    brew uninstall --cask zc-care >/dev/null 2>&1 </dev/null || true
    brew install go </dev/null
    make -C "$tool_dir" app-install </dev/null
  fi
  # After the cask, brew's link wins; ~/.local/bin only serves the source build.
  export PATH="$PATH:$HOME/.local/bin"
  command -v zc-care >/dev/null || { echo "zc-care is not on PATH after the install." >&2; exit 1; }
  export ZC_CARE_CONFIG="$config_dir/zc-care.yaml"
  defaults write dev.zoolcoder.zccare configPath "$ZC_CARE_CONFIG"
  # mise reads only configs you trust; this one is yours.
  if [[ -f $config_dir/mise.toml ]]; then mise trust --quiet "$config_dir/mise.toml" </dev/null; fi

  # On a terminal, ZC Care asks which of the config's apps this Mac gets; what is
  # left out goes on this Mac's skip list, which the plan below honours.
  if [[ -t 1 && -z ${ZC_NO_PICKER:-} ]] && have_tty; then
    step "Choosing apps in ZC Care"
    # The scheme is registered once the app has been opened; a fresh source
    # build may not be yet, so the picker is then opened by hand.
    open "zccare://apps" </dev/null \
      || echo "Could not open ZC Care: open ~/Applications/ZCCare.app and pick the apps there." >&2
    read -r -p "Pick your apps in ZC Care, press Install, then press Enter here. " </dev/tty
  fi

  step "Plan"
  zc-care plan </dev/null
  # apply asks before deleting, so it needs a terminal to answer on; without
  # one it would read EOF, cancel and stop the script.
  if ! have_tty; then
    echo "Run zc-care apply at a terminal to review and confirm." >&2
    return 0
  fi
  step "Applying"
  zc-care apply </dev/tty
  # Targets planned before the packages arrived, such as runtimes, are finished by a second pass.
  if ! zc-care plan -exit-code >/dev/null 2>&1 </dev/null; then
    zc-care apply </dev/tty
  fi

  step "Done"
  zc-care status </dev/null
  cat <<'MSG'

Left for you, once:
  * Log out and back in, then run: zc-care apply   (loads the commit signing key)
  * Pick WebViewScreenSaver in System Settings > Screen Saver
  * Open a new terminal to get the new shell
MSG
}

main "$@"
