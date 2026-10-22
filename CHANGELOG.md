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
- Notifications no longer repeat after a refresh that partly failed, and a
  refresh asked for while another runs follows it, so badges show the data
  after your change.
- Removing or adopting an app refreshes the lists and the overview; putting
  a file back during a scan rescans when the scan ends; Large Files no
  longer brings back a file you trashed during a scan.
- A second click on Trash, Remove similar images, Dependencies, Leftovers,
  Plan, Install or Create Config while the first runs does nothing.
- An overview target that fails to load shows the error and a Retry button,
  and the open target no longer flashes a spinner on refresh.
- Cleanup reports a failure when some files could not be removed, Show in
  Finder buttons have an accessibility label, `zccare://` links are
  case-insensitive, and Set Up This Mac offers Try Again after any error.
- Uninstalling an app no longer trashes or boots out the launch agents and
  per-host settings of another installed app whose id extends its own
  (Chrome and Chrome Canary), the uninstall preview no longer lists an
  ignored file inside a leftover folder as trashed with it, and leftover
  detection counts apps in Setapp and on other volumes as installed.
- Claude Code temp folders stay while any file inside them changed in the
  last day, a running command that names a path followed by a quote, tab or
  `=` protects that path, a running process whose path contains spaces keeps
  its cache, and project dependency folders are never called idle when the
  project is too large to read in full.
- Docker maintenance steps run against this Mac's own daemon only, ignoring
  `DOCKER_HOST` and `DOCKER_CONTEXT`; Ollama blobs are not offered for
  removal when any manifest cannot be read.
- A corrupt `activity.json` is moved aside as `activity.json.broken-<time>`
  instead of being overwritten, so Put Back records survive, and Put Back
  recreates missing parent folders as private (0700).
- Cloud Cleanup lists only files iCloud confirms as uploaded and never lists
  Google Drive, OneDrive or Dropbox files for download removal; Space Lens
  growth for a path missing from the scan shows nothing instead of the whole
  disk's growth.
- Uninstalling an app no longer trashes agents of a sibling app installed
  through Setapp or on another volume, a stray `.DS_Store` in Ollama's
  manifests folder no longer turns off model cleanup, a corrupt activity log
  that cannot be moved aside is kept rather than overwritten, and Claude
  temp cleanup leaves a folder alone after reading 2000 entries.
- The app runs the automatic-login fix and the updated Touch ID fix from the
  doctor's own sudo lines, and shows AirDrop and automatic update findings
  as System Settings advice.

### CLI

- `apply -json`, `validate -json` and `undo -json` print structured results;
  `undo -json` only shows the plan and changes nothing. `capture -json` is
  refused.
- `diff -exit-code` exits 2 when the two snapshots differ; `export -o`
  refuses to overwrite without `-force`, and every written file is 0600.
- `undo` records progress, so a second run after a failure skips what it
  already put back. Changes that cannot be undone are reported once with
  exit 3, then the entry closes, so `undo` moves on to the next one. Each
  undo is matched to its own outcome, so two entries on the same resource
  no longer both count as reverted when only one revert succeeded.
- A dotfile that was a symlink is restored as a symlink, and a dotfile write
  that fails half way keeps a partial undo record, labelled as such.
- `undo` refuses to uninstall a cask that adopted an app already in
  `/Applications` or `~/Applications`.
- Brewfiles accept single quotes and multi-line entries; unsupported lines
  become MANUAL instead of failing the plan, and so does every line inside
  an `if`/`unless` block, which is not evaluated. Removing a multi-line
  entry also removes its continuation lines.
- `export -o -force` writes through a temp file and rename, so an existing
  world-readable file ends up 0600 and a failed write leaves the old one.
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
- `apply` runs one second pass for targets that were MANUAL only because the
  apply had not installed their tool yet, such as dotfiles before chezmoi,
  unless the pass deletes or needs a confirmation or the plan was saved; then
  it exits 1 and says how many changes became possible, so you run `apply`
  again.
- A saved plan records a digest of the content it will write, so a source
  file edited after the review is refused as a changed live state.
- `validate` refuses paths with `$` or `~user`, which were never expanded
  and would have landed under the config's folder.
- `plan` warns when the Mac has no profile set but targets are restricted
  to profiles, since every one of them then runs.
- `init -from-mac` reads single-quoted Brewfile entries.
- Local-directory targets write through a temp file and a rename, keep an
  existing file's mode (new files are 0600), and their prune and update can
  be undone.
- An agent client's rules file refuses to overwrite an edit made after the
  plan, its config and rules writes can be undone, and skill copies keep the
  source file's mode, so scripts stay executable.
- A failed `codesign` puts the screen saver's Info.plist back, so the next
  plan retries it, and the plist is replaced in one rename.
- A Brewfile entry whose line ends in a comment before its `id:` is read as
  one entry, and comment lines inside a multi-line entry are skipped.
- Settings reads run eight at a time in the C locale, and overwriting an
  array or dictionary setting, which undo cannot put back, asks first.
- Saved plans refuse to apply when a dotfile, local file, rules file, skill
  or screen saver page changed since the plan.
- A symlink inside a local-directory target is written through and stays a
  link, undo restores the file it points to, and a link that leaves the
  directory is refused.
- `apply` runs its follow-up pass, or reports pending changes, only for
  targets that were waiting on a missing tool (brew, mise, chezmoi, Ollama),
  not for any target with a permanent MANUAL line.
- A settings change that replaces an array, dictionary, data or date value
  says in the plan that undo cannot restore it; the confirmation prompt names
  this case and the MCP server refuses such plans.
- A dotfiles plan's content digest hashes the chezmoi source file, so it no
  longer changes when `chezmoi diff` fails or varies. A plan saved before
  digests existed, or whose content can no longer be read, is refused with a
  message that says to re-run `plan`.
- Undo journal IDs carry a random suffix, so two saves in the same clock
  tick no longer collide. `undo -id` with `-n` says "use -n or -id, not
  both".
- A missing `mas` waits for the apply that installs it through brew, so App
  Store apps are retried in the follow-up pass. The localdir provider refuses
  to write through a symlink to a missing file or to a directory, naming the
  file, and creates parent folders next to the link's real target.

### Security checks

- The MCP pin check prints no raw argument: it skips the value after an
  unknown flag and shows only a name-shaped package spec, so
  `npx --token ghp_xxx pkg` leaks nothing. One wrong-typed value in a client
  config (a numeric PORT or argument) no longer hides the whole file from the
  key and pin checks, short secrets under a secret-named key are flagged with
  no 8-character floor, and servers started through `npm exec`, `pnpm dlx`,
  `yarn dlx` or `bun x` are checked for a pinned version.
- `doctor` and `doctor -fix` agree: automatic login shows its fix command,
  while AirDrop and automatic updates stay advice; the update advice says
  macOS installs updates and restarts on its own.
- The Touch ID for sudo fix turns an active `auth optional pam_tid.so` line
  into a working `auth sufficient` line.
- A disabled Gatekeeper fails even when `spctl --status` exits non-zero; the
  listening-servers check flags LAN-address listeners and reports unknown
  when `lsof` fails.
- `npx --legacy-peer-deps pkg@latest` and `uvx --upgrade pkg` are no longer
  hidden from the unpinned-server check, an MCP server entry that is not an
  object or a config that does not parse is reported as unknown instead of
  skipped, an SSH key in an unrecognised format is unknown rather than
  protected (`config`, `known_hosts*` and `authorized_keys*` are skipped),
  and a loopback listener with a zone (`::1%lo0`) is not reported as exposed.
- Commit signing needs `gpg.format ssh`, a `user.signingkey` that exists and
  `commit.gpgsign true`, the advice names the key, an SSH key file that
  cannot be parsed is reported as unknown rather than protected, and the git
  config read has a timeout.
- A check that could not read its answer reports `unknown` instead of a
  pass or a fail; `doctor -fix` does not count it as still failing and says
  `could not verify` instead of claiming the fix was verified. Ctrl-C during
  a check is a cancellation, not a timeout.
- New checks: Guest account off, screen saver idle time, automatic macOS
  update downloads and installs.
- Listening ports on loopback are ignored; FIDO `sk-` keys are not flagged
  for a missing passphrase.
- Root fixes run as one `sudo` line each; File Sharing is disabled and
  stopped, automatic login removes `/etc/kcpassword`, and Touch ID for sudo
  edits `/etc/pam.d/sudo_local` in place: it uncomments a real `auth ...
  pam_tid.so` line, not a comment that mentions it, and ends an unterminated
  last line before appending.

### Agents and MCP

- No MCP tool takes a config argument: the server's own config is the only
  one, and `apply` refuses a saved plan that names another.
- `apply` claims the plan with an atomic rename, so two servers on one
  state folder cannot apply one plan_id. An apply that ran actions spends
  the plan even when it failed; one refused before running keeps it until it
  expires.
- The terminal command a refused apply prints is shell-quoted, control
  characters are stripped from every tool result, and `detail`, `desc` and
  `why` are named as untrusted text.
- The hook asks on globs, launchers (`find -exec`, `xargs`, `git -c alias.`,
  `env`, `time`, `sh -c`), `eval`, interpreter pipes and escaped command
  names that could hide zc-care, on an unlisted subcommand or a flag value
  that hid it (`zc-care -n sync`), and on `export`; `diff` stays allowed.
- The no-MCP path states the 10-minute, single-use and same-turn rules, and
  the add-software skill no longer edits the Brewfile for `mas` items.
- The injected-description, stale-plan and plan-id-reuse evals grade
  recorded tool calls against mocked `zc-care` tools.
- Saved plans expire after 10 minutes and a successful apply spends the plan.
  Apply ends with a one-line digest of what was applied and what MANUAL work
  is left.
- `add` no longer accepts a `config` argument and returns `{file,item,section}`;
  `validate` returns structured JSON; `remove` only plans and names the
  terminal command.
- The plugin hook fails closed: it allows only read-only subcommands in plain
  commands and asks for every `apply` (a saved plan file no longer counts),
  `undo`, `upgrade`, `remove`, `init`, `add`, `skip`, `profile`, `mcp`,
  `-yes` and `-fix`, and for any `zc-care` command with quotes, `$`,
  backticks or `;`, which closes quoting, substitution and alias bypasses.
  It parses the real command, so it also catches `yes |` and here-doc input,
  and no longer asks on `printf x | tee $LOG`. Its 100-case test runs with
  `make hook-test` and `make lint`.
- MCP `remove` includes `-config` in the terminal command it returns, so the
  command runs against the config the plan was made for.
- `bootstrap.sh` opens `/dev/tty` to detect a terminal and gives `apply` the
  terminal for its prompts; without one it says to run `zc-care apply` by
  hand instead of stopping on EOF.
- The five agent adapters are generated from one `COMMON.md` and checked by a
  Go test; they no longer allow `-yes`.
- Eight new evals cover stale plans, plan_id reuse, MANUAL items, prompt
  injection, a typed `-yes` and `yes` piping.

### Release and CI

- A re-run of the release workflow on an existing release takes the cask
  checksum from the asset already published, so the cask pull request matches
  the zip users download, and the cask step opens a pull request when the
  cask file is new on develop instead of calling it already present.
- The release workflow comment states which permissions the build job holds
  and why, and the prerelease flag reaches the script through the environment.
- The bootstrap script installs Homebrew from a pinned installer commit and
  stops with a clear message when a target folder exists but is not a clone.
- `make lint` fails when the installed golangci-lint is not the version CI
  pins (2.15.0); the CI lint job runs `make lint` after installing that
  version, and the full test job runs the hook test too.
- The docs build writes Antora logs as JSON, fails when the log is not JSON,
  and verifies the UI bundle's sha256 before Antora uses it.
- `make build` uses the release flags: `-trimpath`, `-s -w` and `CGO_ENABLED=0`.
- The release workflow builds with read-only credentials and publishes in a
  separate job; it checks the tag is semver and on `main`, marks
  pre-releases, and re-runs safely.
- The cask clears the quarantine flag until the app is notarized, and says so
  in its caveats. `package.sh` signs with the hardened runtime and a stable
  identifier.
- Security workflow runs on pull requests, verifies `go.sum`, and pins
  gitleaks and osv-scanner by commit.
- `make vuln` runs govulncheck, pinned by a `tool` directive in `go.mod` so
  Dependabot bumps it, and `make verify` checks the module sums.
- Every CI job has a timeout, the quick check on a pull request into
  `develop` also runs the hook test, and osv-scanner reads `Gemfile.lock`.
- `package.sh` claims Apple Events in the app's entitlements and usage
  string, so Empty Trash reaches Finder under the hardened runtime, and
  timestamps a Developer ID signature. `cask.sh` refuses a version or digest
  that is not one.
- `bootstrap.sh` stops with a clear message when the GitHub login needs a
  terminal it does not have, checks `zc-care` is on PATH before planning,
  and tells you to open ZC Care by hand when the `zccare://` scheme is not
  registered yet. `harden.sh` no longer loses the repository settings when
  secret scanning is unavailable, and `select-modules.sh` removes the whole
  `plugin/` folder, the hook test and the docs generator with their modules.

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
