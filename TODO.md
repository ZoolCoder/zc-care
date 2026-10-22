# TODO

Concrete open work, in rough priority order. The [roadmap](docs/ROADMAP.md)
says where the project is heading; this file says what to pick up next.
Items marked *good first change* need no knowledge of the engine.

Take an item by opening an issue that names it, so two people do not do the
same work. Remove the line in the pull request that finishes it.

## Release

- [ ] Install from the cask on a clean macOS VM and run `bootstrap.sh` end to
      end.

## GitHub

- [ ] Find why `push` and `pull_request` events start no Actions runs. Check
      Settings, Actions, General, and
      `gh api repos/zoolcoder/zc-care/actions/permissions`.

## ZC Care

- [ ] Sign ZC Care with a Developer ID and notarise it, so Full Disk Access
      survives an update and Gatekeeper opens it without a warning.
- [ ] Upload `.github/social-preview.png` by hand in the repository's
      Settings, General, Social preview; GitHub has no API for it.
- [ ] Add the SSH signing key to GitHub as a signing key, so commits show
      Verified.
- [ ] Find why macOS refuses ZC Care's notification request, which vitals
      alerts and the weekly scan rely on.

## Docs

- [ ] *Good first change:* a toolbox page for a tool in the Brewfile that has
      none yet, under `docs/modules/ROOT/pages/toolbox/`.

## Quality

- [ ] A clean-machine test on a tart macOS VM, run before each release.
