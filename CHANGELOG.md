# Changelog

Notable changes, newest first. Versions follow [semver](https://semver.org);
before 1.0 a minor bump may change the config format, and any that does says so
here with what to edit.

## Unreleased

### ZC Care

- Remove buttons say **Move to Trash** or **Delete** to match the Settings
  toggle, and the confirmations use the same words.
- Buttons that start work are disabled while another job runs, and the
  panel's close button waits for it; a running job can be cancelled.
- Screen Cleaner needs Esc held for two seconds and releases itself after
  sixty seconds.
- Setup has Back and Retry.
- Space Lens, Developer and the care views use one shared "newly appeared"
  badge.

### CLI

- `apply -json`, `validate -json` and `undo -json` print structured results;
  `undo -json` only shows the plan and changes nothing. `capture -json` is
  refused.
- `diff -exit-code` exits 2 when the two snapshots differ; `export -o`
  refuses to overwrite without `-force`, and every written file is 0600.
- `undo` records progress, so a second run after a failure skips what it
  already put back; an entry with only manual work left exits 3.
- A dotfile that was a symlink is restored as a symlink, and a dotfile write
  that fails half way keeps a partial undo record, labelled as such.
- `undo` refuses to uninstall a cask that adopted an app already in
  `/Applications`.
- Brewfiles accept single quotes and multi-line entries; unsupported lines
  become MANUAL instead of failing the plan.
- `init` writes its three files together and never writes through a symlink
  under `-force`; localdir file names are cleaned and duplicates rejected;
  the profiles file is lowercased and checked.
- Agent configs: symlinked skill folders sync their files, unreadable rules
  or skill files fail instead of reading as empty, a `null` client config no
  longer panics, files holding keychain-backed servers are written 0600, and
  a file edited mid-write is reported, not overwritten.
- The screensaver page goes in through a temp file, so a large page no longer
  fails with E2BIG.
- `drift -hour` must be 0 to 23; `-h` on any command prints that command's
  flags.

### Security checks

- A check that could not read its answer reports `unknown` instead of a
  pass or a fail, and `doctor -fix` does not count it as still failing.
- New checks: Guest account off, screen saver idle time, automatic macOS
  update downloads and installs.
- Listening ports on loopback are ignored; FIDO `sk-` keys are not flagged
  for a missing passphrase.
- Root fixes run as one `sudo` line each; File Sharing is disabled and
  stopped, automatic login removes `/etc/kcpassword`, and Touch ID for sudo
  edits `/etc/pam.d/sudo_local` in place.

### Agents and MCP

- Saved plans expire after 10 minutes and a successful apply spends the plan.
  Apply ends with a one-line digest of what was applied and what MANUAL work
  is left.
- `add` no longer accepts a `config` argument and returns `{file,item,section}`;
  `validate` returns structured JSON; `remove` only plans and names the
  terminal command.
- The plugin hook parses the real command, so it also catches `yes |`, here-doc
  input and `-yes` on any subcommand. It has a 36-case test run by
  `make hook-test` and `make lint`.
- The five agent adapters are generated from one `COMMON.md` and checked by a
  Go test; they no longer allow `-yes`.
- Eight new evals cover stale plans, plan_id reuse, MANUAL items, prompt
  injection, a typed `-yes` and `yes` piping.

### Release and CI

- The release workflow builds with read-only credentials and publishes in a
  separate job; it checks the tag is semver and on `main`, marks
  pre-releases, and re-runs safely.
- The cask clears the quarantine flag until the app is notarized, and says so
  in its caveats. `package.sh` signs with the hardened runtime and a stable
  identifier.
- Security workflow runs on pull requests, verifies `go.sum`, and pins
  gitleaks and osv-scanner by commit.
- `make vuln` runs govulncheck and `make verify` checks the module sums.

## v0.2.0 — 2026-10-21

Set Up This Mac, safer cleanups that go to the Trash, and a CLI that can undo
an apply, fix security findings and compare two Macs.

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
