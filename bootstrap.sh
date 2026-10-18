#!/usr/bin/env bash
# Sets up a new Mac from a config repo in one run: installs Homebrew, ZC Care and the zc-care CLI it
# carries, clones zc-care and the config repo into ~/Developer/Tools, then applies the config.
# Usage: bootstrap.sh OWNER/CONFIG-REPO
#   curl -fsSL https://raw.githubusercontent.com/ZoolCoder/zc-care/main/bootstrap.sh | bash -s -- OWNER/CONFIG-REPO
# Safe to run again: what is already there is kept, and apply only changes what differs.
set -euo pipefail

config_repo=${1:-${ZC_CONFIG_REPO:-}}
[[ -n $config_repo ]] || { echo "usage: bootstrap.sh OWNER/CONFIG-REPO" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || { echo "bootstrap.sh is for macOS only." >&2; exit 1; }

tools="$HOME/Developer/Tools"
tool_dir="$tools/zc-care"
config_dir="$tools/$(basename "$config_repo")"
# Clone sources; the VM test points these at mounted copies.
tool_from=${ZC_TOOL_FROM:-https://github.com/ZoolCoder/zc-care.git}
config_from=${ZC_CONFIG_FROM:-}

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if ! command -v brew >/dev/null && [[ ! -x /opt/homebrew/bin/brew ]]; then
  step "Installing Homebrew (asks for your password; also installs the Xcode command line tools)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

step "Installing what zc-care needs"
brew install git gh chezmoi mise

if [[ -z $config_from ]]; then
  # The config repo is usually private, so git needs a GitHub login first.
  gh auth status >/dev/null 2>&1 || { step "Logging in to GitHub"; gh auth login --git-protocol https --web; }
  gh auth setup-git
  config_from="https://github.com/$config_repo.git"
fi

mkdir -p "$tools"
for pair in "$tool_from|$tool_dir" "$config_from|$config_dir"; do
  from=${pair%%|*} dir=${pair#*|}
  if [[ -d $dir/.git ]]; then
    echo "Keeping $dir"
  else
    step "Cloning $from"
    git clone --quiet "$from" "$dir"
  fi
done

# ZC Care carries the CLI and its cask puts it on PATH. Before a release has
# the cask, as in a VM test of a local copy, it is built from the clone.
step "Installing ZC Care and zc-care"
if ! { brew tap zoolcoder/zc-care https://github.com/zoolcoder/zc-care && brew install --cask zc-care; }; then
  brew install go
  make -C "$tool_dir" app-install
fi
export PATH="$HOME/.local/bin:$PATH"
export ZC_CARE_CONFIG="$config_dir/zc-care.yaml"
defaults write dev.zoolcoder.zccare configPath "$ZC_CARE_CONFIG"
# mise reads only configs you trust; this one is yours.
[[ -f $config_dir/mise.toml ]] && mise trust --quiet "$config_dir/mise.toml"

# On a terminal, ZC Care asks which of the config's apps this Mac gets; what is
# left out goes on this Mac's skip list, which the plan below honours.
if [[ -t 1 && -r /dev/tty && -z ${ZC_NO_PICKER:-} ]]; then
  step "Choosing apps in ZC Care"
  open "zccare://apps"
  read -r -p "Pick your apps in ZC Care, press Install, then press Enter here. " </dev/tty
fi

step "Plan"
zc-care plan
step "Applying"
zc-care apply
# Targets planned before the packages arrived, such as runtimes, are finished by a second pass.
if ! zc-care plan -exit-code >/dev/null 2>&1; then
  zc-care apply
fi

step "Done"
zc-care status
cat <<'MSG'

Left for you, once:
  * Log out and back in, then run: zc-care apply   (loads the commit signing key)
  * Pick WebViewScreenSaver in System Settings > Screen Saver
  * Open a new terminal to get the new shell
MSG
