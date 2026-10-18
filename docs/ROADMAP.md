# Roadmap

The full plan, with the decisions and the projects reused from GitHub, is in
[docs/modules/ROOT/pages/roadmap.adoc](modules/ROOT/pages/roadmap.adoc). The
concrete next tasks are in [TODO.md](../TODO.md).

## Done

- The `packages` (brew, mas), `dotfiles` (chezmoi) and `tools` (mise)
  providers.
- Phase 1, macOS parity with aurora-mac:
  - the `settings`, `services` and `desktop` providers
  - security checks in `doctor`
  - the config in a private repo
  - `bootstrap.sh` for a new Mac
- `list`, `capture`, `add`, `remove`, `-upgrade` and `-only`.
- ZC Care, the menu bar app, and its Care window that cleans, protects and
  tunes the Mac.
- The MCP server and the Claude Code plugin, with adapters for other agents.
- The toolbox section of the manual: a page per tool in the reference setup.
- ZC Care: Similar Images in My Clutter, and browser privacy data.
- ZC Care packaged as a cask in the release workflow.
- A generated command reference.
- The repository settings and rulesets, and the release `v0.1.0`.
- macOS only: the Linux and Windows providers, the dashboard and goreleaser
  removed, the CLI shipped inside ZC Care.
- ZCBar renamed ZC Care, with Cloud Cleanup, Settings, an ignore list, Put
  Back, vitals alerts and a review of every item before it is deleted.

## Now

- A clean-machine run of `bootstrap.sh` on a macOS VM.

## Next

- ZC Care signed with a Developer ID and notarised.

## Later

- Phase 4: retire aurora-mac.

## Not planned

- Linux and Windows.
- Applying from an agent without a person's yes to the plan.
- A plan that performs writes.
- Managing servers or fleets of machines.
- Nix or home-manager.
