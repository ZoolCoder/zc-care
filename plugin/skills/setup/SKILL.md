---
name: setup
description: Install zc-care, write a first config and check it with doctor. Use when the user asks to "set up", "install" or "get started with" zc-care, or when doctor fails.
license: MIT
compatibility: Needs macOS, with Homebrew or Go.
---

# Set up

1. Install: `brew tap zoolcoder/zc-care https://github.com/zoolcoder/zc-care`, `brew trust zoolcoder/zc-care`, then `brew install --cask zc-care`, or `go install github.com/zoolcoder/zc-care/cmd/zc-care@latest`.
2. Write `~/.config/zc-care/zc-care.yaml`, or keep it in the user's dotfiles repository and point `$ZC_CARE_CONFIG` at it (at a terminal `-config` works too; the MCP tools take no config argument). Start from `zc-care.example.yaml`. Each target needs a kebab-case `name` and a `provider`: `packages` and `tools` need a `file`, `dotfiles` needs a `source`.
3. Run `zc-care validate`, then `zc-care doctor`. Fix every `fail` line before planning. A `program` line that fails names a tool to install: Homebrew, chezmoi or mise. Ask before installing it.
4. Hand over to the `plan-apply` skill for the first plan.

Never point a `dotfiles` target at the user's real home directory while another tool (such as an older dotfiles script) still manages it: set `destination` to a scratch directory until the user switches over.

Never create a target with `prune: true` on a directory the user did not name: prune deletes every file the config does not declare.
