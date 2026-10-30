<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../.github/mark-dark.png">
    <img src="../.github/mark.png" alt="ZoolCoder" width="96">
  </picture>
</p>

<h1 align="center">ZC Care</h1>

ZC Care is the macOS menu bar app for [zc-care](../README.md). It
shows what the CLI would change, your Mac's vitals and outdated packages,
and opens the **Care window**, which cleans, protects and tunes the Mac.
Nothing changes until you approve it.

<p align="center">
  <img src="screenshots/care-smart.png" alt="ZC Care's Smart Care: cleanup, health, applications, performance and clutter in one scan" width="80%">
</p>

<p align="center">
  <img src="screenshots/panel-mac.png" alt="The panel's Mac tab: health, security checks, disk, memory, battery, CPU and Wi-Fi" width="32%">
  <img src="screenshots/panel-overview.png" alt="The panel's Overview tab: every target fully in place" width="32%">
  <img src="screenshots/panel-updates.png" alt="The panel's Updates tab: outdated formulae with Update and Update All" width="32%">
</p>

## Install

From the Homebrew tap. The app carries the `zc-care` CLI, and the cask
links it onto PATH:

```console
$ brew tap zoolcoder/zc-care https://github.com/zoolcoder/zc-care
$ brew trust zoolcoder/zc-care    # newer Homebrew loads a third-party tap only once you trust it
$ brew install --cask zc-care
```

The release build is signed ad hoc, so open it the first time with
Control-click, Open. To build it yourself instead:

ZC Care needs macOS 14 or later, Xcode or the Swift toolchain, and the
`zc-care` CLI. From the repository root:

```console
$ make app-install
installed ~/Applications/ZCCare.app; open it once, then tick Open at login
```

This builds `bin/app.noindex/ZCCare.app`, signs it ad hoc and copies it to
`~/Applications`. ZC Care has no Dock icon; look for the mark in the menu bar.

A Finder-opened app gets no shell environment. ZC Care therefore:

- reads `PATH` from your login shell
- looks for `zc-care` on that `PATH`, then in `~/.local/bin` and
  `/opt/homebrew/bin`

If `ZC_CARE_CONFIG` is set, `make app-install` passes it to the app
once. Use *Choose Config…* in the panel to change it later.

## How it works

ZC Care does not reimplement zc-care. It runs the CLI and reads its
`-json` output. ZC Care is the one part that works on files itself:

```mermaid
flowchart LR
    subgraph app["ZCCare.app"]
        UI["ZC Care<br/>panel · ZC Care window<br/>SwiftUI + AppKit"]
        Core["ZCCareCore<br/>CLI JSON · scans · care plans<br/>tested, no UI"]
        UI --> Core
    end
    Core -->|"status · list · doctor -json"| CLI["zc-care CLI"]
    Core -->|"plan -out, then apply · remove"| CLI
    CLI --> Tools["brew · chezmoi · mise<br/>defaults · launchctl"]
    Core -->|"scan, then delete or Trash<br/>after you confirm"| Files["caches · logs · apps<br/>clutter · idle dependencies"]
    SB["SketchyBar · Raycast · scripts"] -->|"zccare:// URLs"| UI
```

| ZC Care shows | From |
|---|---|
| What each target has and misses | `zc-care status -json` |
| Outdated and undeclared items | `zc-care list -json` |
| Health findings | `zc-care doctor -json` |
| *Apply*, *Update* | `plan -out` (with `-upgrade` and `-only` for updates), then `apply` of that saved plan |
| *Uninstall* | `zc-care remove` |

Every change that touches the workstation goes through the CLI. The CLI's
checks therefore hold here too: plan before apply, verify after, and no
uninstall without a yes.

ZC Care's cleaning works on files directly. Each module scans first and
shows what it found. Nothing is removed until you press its button and
confirm:

```mermaid
flowchart LR
    I["Intro<br/>what the module does"] --> S["Scan<br/>reads only"]
    S --> R["Review<br/>sizes, paths, checkboxes"]
    R --> C{"Confirm?<br/>names what goes"}
    C -->|no| R
    C -->|yes| D["Delete caches<br/>Trash files and apps<br/>zc-care remove for casks"]
    D --> L["Activity log<br/>what was freed"]
```

## The panel

Click the mark, or press ⌃⌥Z, to open the panel. It opens on the Mac
page; the laptop button at its foot opens the other pages, *Plan* and
*Apply*, and shows a dot when one of them holds something to do. The arrow beside
it reads the Mac again (⌘R). The sparkle opens Smart Care.

| Page | Shows |
|---|---|
| Mac | Disk, memory, CPU, battery, network and sensors, the largest junk folders, and advice. |
| Overview | Each target with what is in place and missing, and *Apply* per target. |
| Updates | macOS updates from Software Update, with *Open Software Update*; outdated packages and runtimes, with *Update* per item and *Update All…*. |
| Health | `doctor` findings, with *Fix*, *Copy Fix* and *Ignore*. |
| Services | Homebrew services and launchd agents, with *Start*, *Run Now* and logs. |

The panel's settings turn on:

- notifications, including one when an app dragged to the Trash left files
  in the Library, which opens Leftovers
- vitals alerts, with a limit each: free disk space, memory pressure, CPU
  heat, battery capacity and the Trash's size
- the ⌃⌥Z hotkey
- the weekly Smart Care scan
- opening at login

Each tile on the Mac tab opens a detail. *Free Up* on Disk lists the
folders it can clear, with their sizes. *Top Apps* on CPU lists what is
busy. The bottom bar opens ZC Care and the settings.

If [SketchyBar](https://github.com/FelixKratz/SketchyBar) is installed,
ZC Care sends it the count of open items for its `zccare` item.

## ZC Care

| Module | Does |
|---|---|
| Smart Care | Scans everything at once: junk, clutter, updates, health. *Run* cleans up, then updates. |
| Cleanup | Clears caches, logs, build output, npx packages and Mail downloads. Clears AI clutter: Claude Code temp files and old versions, and the caches and logs of Claude, Cursor, ChatGPT, Windsurf, Codex, Gemini CLI and Chrome DevTools MCP. Empties the Trash. |
| Protection | Shows issues found and checks passed; FileVault, firewall, SIP and security responses beside Gatekeeper's verdict per app, background apps, extensions (Safari, Finder, Share, Quick Look, Spotlight, Notification Center, Action, Photos and system extensions, with host app, state, and a flag when the host app is gone or the developer unidentified), the privacy permissions apps hold (with Reset), Recent Items to clear, known Wi-Fi networks to forget, and each browser's history, cookies, cache, site data and saved tabs, cleared only while that browser is closed. |
| Performance | Manages login items and runs maintenance: free RAM, flush DNS, thin Time Machine snapshots, reindex Spotlight, verify the startup disk, reset Quick Look, clear font caches, clean Homebrew, Docker and simulators. Top processes by CPU or memory with *Quit* and *Force Quit*; ZC Care, system daemons and other users' processes cannot be quit. |
| Applications | Uninstalls an app with what it keeps in the Library. *Adopt* replaces a hand-installed app in `/Applications` with its Homebrew cask. Finds leftovers of removed apps. *Updates* lists newer versions from each app's own update feed, Homebrew and the App Store. *Intel Only* lists apps that need Rosetta. Apps in `~/Applications` are listed too; a copy installed twice is flagged, and uninstalling it leaves the settings the other copy uses. Leftovers also lists installer package receipts and whether their files remain. |
| My Clutter | Finds large files, duplicates, similar images (Vision keeps the one with the most pixels), old downloads and installers. Large files filter by kind (videos, music, pictures, archives, installers, documents) and by not opened for a year. |
| Space Lens | Maps what fills your home folder. *Startup Disk* shows hidden volumes, snapshots, purgeable space and the drive's health. |
| Cloud Cleanup | Lists the files cloud drives keep downloaded; *Remove Download* frees them and keeps them in the cloud. |
| Developer | Finds `node_modules` and virtualenvs of projects untouched for 90 days, and local models from Ollama, LM Studio and Hugging Face. Homebrew: unneeded dependencies with *Remove…* (never one the config declares), what `brew cleanup` would free, and `brew doctor` warnings. Simulator runtimes with *Delete* (permanent, Xcode downloads them again), and Android system images and AVDs with *Show in Finder*. |
| My Tools | Lists every tool as a searchable card, including *Screen Cleaning Mode*. |
| My Activity | Shows Mac health, disk use, what ZC Care freed by kind, a tile each for protection, updates, maintenance and the startup drive, recommendations and recent runs. |

<p align="center">
  <img src="../docs/modules/ROOT/images/care-cleanup.png" alt="Cleanup: system junk and AI clutter" width="49%">
  <img src="screenshots/care-applications.png" alt="Applications: every app with its size, last use, Brewfile status, Adopt and Uninstall" width="49%">
</p>
<p align="center">
  <img src="screenshots/care-performance.png" alt="Performance: maintenance tasks and launch agents" width="49%">
  <img src="../docs/modules/ROOT/images/care-tools.png" alt="My Tools: every tool as a searchable card" width="49%">
</p>

Each module opens on an intro that says what it does, before anything is
scanned:

<p align="center">
  <img src="screenshots/care-protection.png" alt="Protection's intro: security settings, background items and application permissions" width="70%">
</p>

### Where things go

- **Deleted:** junk, caches and AI clutter. Each tool makes them again.
- **Moved to the Trash:** files, apps, leftovers, dependencies and models.
  You can put them back.
- **Uninstalled through `zc-care remove`:** Homebrew apps, so they
  also leave the Brewfile.
- **Admin tasks** ask for your password in a macOS dialog.

### What it never touches

- AI chats, settings and sessions: `~/.claude/projects`, `~/.codex/sessions`.
- The Claude Code version that `~/.local/bin/claude` runs.
- A Claude Code temp folder used in the last day.
- Caches of apps that are open.

ZC Care keeps its last scan in `~/Library/Caches/dev.zoolcoder.zccare` and its
activity log in `~/Library/Application Support/dev.zoolcoder.zccare`. Both are
outside what Cleanup clears.

### Permissions

- **Full Disk Access** lets Protection read privacy permissions and browser
  history and cookies. An ad hoc signed build is a new app to macOS, so each
  rebuild asks again.
- **Finder automation** lets Cleanup empty the Trash. It asks once.

## URLs

ZC Care registers the `zccare://` scheme, so scripts, SketchyBar and Raycast
can open it:

| URL | Opens |
|---|---|
| `zccare://panel` | Toggles the panel. |
| `zccare://panel/updates` | A panel tab. |
| `zccare://panel/overview/home` | A target in the Overview tab. |
| `zccare://panel/mac/disk` | A tile in the Mac tab. |
| `zccare://care` | The ZC Care window. |
| `zccare://care/cleanup` | A module, matched by the start of its name. |

```console
$ open zccare://care/developer
```

## Layout

```text
Package.swift        SwiftPM: ZCCareCore, ZC Care, ZCCareCoreTests
Sources/ZCCareCore/   the logic, no UI: CLI JSON, discovery, scans, care plans, activity log
Sources/ZCCare/       the SwiftUI and AppKit app: panel, Care window, hotkey, notifications
Tests/ZCCareCoreTests/ tests for ZCCareCore
Resources/           AppIcon.icns and MenuBarMark.pdf
screenshots/         the images in this README
icon/                mark.svg and make-icon.swift, which draws the icons
package.sh           builds the release binary and wraps it in an ad hoc signed .app
```

## Develop

From the repository root:

```console
$ make app-test      # swift test: the ZCCareCore tests
$ make app           # bin/app.noindex/ZCCare.app
$ make app-install   # copy it to ~/Applications
$ make app-icon      # redraw the icons from icon/mark.svg
```

Put logic in `ZCCareCore`; it is what the tests cover. Keep `ZCCare` to views
and AppKit glue.

A change that deletes or trashes files must:

- ask first, naming what it removes
- come with a test proving it leaves alone what it must keep

`zccare://` URLs open the installed app, so test them after
`make app-install`. CI builds and tests the app on a macOS runner.

More is in the manual's
[Menu bar app and ZC Care](https://zoolcoder.github.io/zc-care/app.html)
page.
