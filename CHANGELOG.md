# Changelog

Notable changes, newest first. Versions follow [semver](https://semver.org);
before 1.0 a minor bump may change the config format, and any that does says so
here with what to edit.

## Unreleased

### ZC Care

- **Set Up This Mac**: a Setup Assistant for a Mac without a config. Pick
  who it is for (Everyday, Developer, Creative) and Personal or Work, then
  fix the failing security checks behind one password dialog. A developer
  also gets git's name and email, an SSH key that signs commits, and GitHub.
  `zccare://setup` opens it.
- **Choose Apps** picks several profiles at once, starting from the Mac's
  own.
- **Cleanups go to the Trash** by default: junk, browser data and AI caches
  are recorded in My Activity and can be put back. A new Settings toggle,
  "Delete permanently instead of moving to the Trash", restores the old
  behaviour, and the confirmations say which one applies.
- **Secure All previews the commands**: a sheet lists each failing check with
  the exact root command before the single password dialog.
- **Space Lens shows growth**: it keeps the scan before and marks each folder
  that grew since then, lists the top growers, and links to the module that
  can clean them.
- **Developer** covers Docker, when its CLI is installed and the daemon
  answers, with sizes and Prune Build Cache and Prune Dangling Images, and
  Xcode: DerivedData, Archives, iOS DeviceSupport and simulator caches, each
  with its size and a Trash button.
- **New since last week**: launch agents, daemons and background items that
  appeared in the last seven days carry a New badge in Performance and
  Protection.

### CLI

- `zc-care init` writes a starter config for chosen profiles, puts other
  profiles' packages on the skip list, and with `-from-mac` keeps the apps
  the Mac has.
- `zc-care profile` shows and sets who a Mac is for. A target's new
  `profiles` key limits it to Macs with one of them.
- `doctor` checks that Time Machine has a backup disk.
- `zc-care export` saves what a Mac has as a JSON snapshot: every target's
  items with state and version, and the sha256 of dotfiles, never their
  content. `zc-care diff a.json b.json` shows what only one Mac has and what
  differs; with one file it compares against this Mac.
- Agent servers can take secrets from the keychain: write
  `${keychain:service}` or `${keychain:service/account}` in a command, arg,
  url, env or header. Plans, history and errors show the reference, not the
  secret. `validate` flags a malformed one. For dotfiles use chezmoi's
  `keyring` template function.
- `zc-care undo` reverts the last apply, or the last `-n N`. It builds the
  reverse as a plan, shows it, and asks first when it would uninstall a
  package or overwrite a file. Settings go back to their old value or are
  deleted, dotfiles come back from a private copy, installed packages are
  uninstalled and removed ones reinstalled. Upgrades, runtimes and scripts
  are listed as cannot be undone. `-plan` and `-json` change nothing.
- `zc-care doctor -fix` turns each fixable security finding into a plan
  action, lists the exact commands (`sudo` included), asks, runs them and
  checks again. Findings with no safe command stay advice.

## v0.1.0 — 2026-10-18

The first release of ZC Care, a menu bar app that sets up, cleans and watches
a Mac. macOS 14 or later only.

### ZC Care

- **Menu bar**: the count of changes waiting, and live readings beside the
  mark (CPU load, memory used, free disk space, network speed, battery
  charge), each picked in Settings. CPU and memory show by default.
- **Care window**: Smart Care, Cleanup with System Junk and AI Clutter,
  Protection, Performance, Applications with Leftovers, My Clutter with
  Similar Images, Space Lens, Cloud Cleanup, Developer, My Tools and My
  Activity with Put Back. Every item is listed for review before it is
  deleted.
- **My Workstation**: what the config declares and what is in place, each
  target with its items and *Apply*, the drift check and what was applied.
- **Choose Apps** on first launch: pick a profile, untick what this Mac does
  not need, install the rest.
- Welcome, Settings (⌘,), an ignore list, vitals alerts and a weekly scan.

### CLI

- `zc-care`, inside ZC Care: `plan`, `apply`, `status`, `list`, `capture`,
  `validate`, `doctor`, `upgrade`, `history`, `drift`, `add`, `remove`,
  `skip` and `mcp`.
- One `zc-care.yaml` declares the Mac: Homebrew and App Store packages,
  dotfiles through chezmoi, runtimes through mise, macOS defaults, services
  and launch agents, and the look (wallpaper, screen saver, accent).
- Brewfile headings take profile tags, `# Containers [developer]`.
- An MCP server and a Claude Code plugin, with adapters for other agents.
- `bootstrap.sh` sets up a new Mac from a config repo in one command.
