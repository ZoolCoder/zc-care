# What is new in the user's tools

Used by the review skill, step 2.

## Sources

- Recent upgrades: `${XDG_STATE_HOME:-~/.local/state}/zc-care/upgrades/` holds snapshots. The newest file is a `list -json -state outdated` that `zc-care upgrade` took just before the last update, so each item moved from `version` to `latest`.
- Pending upgrades: the `outdated` items of `list`.

## Steps

Take the tools the user relies on: items with a why, and runtimes. From the recent and pending upgrades, pick the ten that matter most to how the user works.

For each one, read its release notes between the two versions:

- Homepage on github.com: `gh release list -R OWNER/REPO -L 30`, then `gh release view TAG -R OWNER/REPO` for the releases in range.
- Otherwise the project's changelog page.

Keep only new features, behaviour changes and deprecations that touch the item's why. Give each one line and, where it helps, a command or setting to try. Skip bug-fix-only releases. Say when notes could not be read; report only what the notes state.
