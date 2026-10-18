# Contributing

Thanks for helping. This guide takes you from a clone to a merged pull
request. Questions go to [SUPPORT.md](SUPPORT.md); security problems go to
[SECURITY.md](SECURITY.md), never to a public issue.

## Where to start

- **Something broke?** Open a [bug report](https://github.com/ZoolCoder/zc-care/issues/new?template=bug_report.yml)
  with the output of `zc-care doctor` and the plan it printed.
- **An idea?** Open a [feature request](https://github.com/ZoolCoder/zc-care/issues/new?template=feature_request.yml)
  before writing code, so we agree on the shape first.
- **Want to code?** [TODO.md](TODO.md) lists open work. Items marked
  *good first change* need no knowledge of the engine. The
  [roadmap](docs/ROADMAP.md) has the bigger picture.

## Set up

You need Go (the version in `go.mod`), `make` and git. For the menu bar app,
also Xcode or the Swift toolchain on macOS 14 or later. For the manual,
Node.

```console
$ gh repo fork ZoolCoder/zc-care --clone
$ cd zc-care
$ git switch develop
$ make lint test build
```

`bin/zc-care` is your build. Try it against the example config, which
changes nothing until you apply:

```console
$ bin/zc-care validate -config zc-care.example.yaml
$ bin/zc-care plan -config zc-care.example.yaml
```

## Make a change

The project follows git flow. Open your pull request against `develop`:

```console
$ git switch -c feature/<topic> develop
# edit, then:
$ make lint test
$ git commit -m "feat(packages): plan mas upgrades"
$ git fetch origin && git rebase origin/develop
$ git push -u origin feature/<topic>
$ gh pr create --base develop
```

Use `fix/`, `docs/` or `chore/` instead of `feature/` when that fits better.
CI must be green before the merge. The pull request template lists what the
review checks; tick what applies.

### Branches

| Branch | From | Merges into | Holds |
|---|---|---|---|
| `main` | | | released code only; every merge is a tag `vX.Y.Z` |
| `develop` | `main` | | the next release; the default branch; open pull requests here |
| `feature/<topic>` | `develop` | `develop` | one change; `fix/`, `docs/`, `chore/` work the same |
| `release/<X.Y.Z>` | `develop` | `main`, then `develop` | version bump and changelog only |
| `hotfix/<X.Y.Z>` | `main` | `main`, then `develop` | an urgent fix to a release |

`main` and `develop` change only through pull requests with green CI, and
neither can be force-pushed or deleted. CI refuses a pull request into `main`
that does not come from a `release/` or `hotfix/` branch.

Rebase a topic branch on `develop` rather than merging `develop` into it.
Topic branches are rebased into `develop`. Release and hotfix branches are
merged into `main` with a merge commit, so each release is one visible merge.

### Commits

Conventional commits: `type(scope): description`, imperative, lowercase, no
trailing period, under 60 characters. Types: `feat`, `fix`, `refactor`,
`docs`, `test`, `chore`, `build`, `ci`, `perf`, `style`. The scope is the
area: `packages`, `dotfiles`, `engine`, `mcp`, `app`, `docs`.

One change per commit, with a body saying what was wrong and why the fix is
the right one. If a test found the bug, say so; that is the useful part for
whoever reads it next.

## Running everything

```console
make test    # go test ./...
make race    # the same, with the race detector
make lint    # gofmt check, go vet, golangci-lint (with the import boundaries)
make cover   # coverage across the whole suite
make build   # bin/zc-care
make evals   # the plugin eval suite in plugin/evals/, needs the claude CLI
```

No test touches a network. A pull request from a fork must be testable
without being handed access to anything, so CI runs with no credentials.
A provider that talks to an API is tested against an `httptest.Server` that
answers in that API's real shapes.

CI runs the CLI tests, and builds and tests ZC Care, on a clean macOS runner.
A change that only works on your Mac will show up there.

## What a good change looks like

**Say what breaks, not what differs.** `content differs, 12 to 40 bytes` sends
someone to the right place; `mismatch` does not. Plan and error text is most of
this tool's value.

**Never print a value that could be a secret.** Not in a plan, not in `-json`,
not in a saved plan, not in an error. Say where the value comes from instead.

**Prefer reporting to guessing.** If the tool cannot do something, that is a
`MANUAL` action saying what a person must do, printed every run. A tool that
silently skips what it cannot do is how a half-finished state passes for a
finished one.

**Test the failure, not the success.** The interesting tests are a provider
that accepts every write and changes nothing, a saved plan applied after the
world moved, a symlink that points out of the target. Successes tend to hold on
their own.

**Keep planning pure.** `Plan` reads and never writes; every write sits inside
an action's `Do`. Config a provider cannot honour is rejected in
`config.Validate`, not ignored.

**No new dependency without a reason.** The standard library first. A pull
request that adds a module says why nothing smaller would do.

## Adding a provider

See [Adding a provider](docs/modules/ROOT/pages/extending.adoc): a package
under `internal/provider/`, a name in `config.Providers`, an entry in
`engine.Default`, and a depguard line in `.golangci.yml`.

## The menu bar app

ZC Care lives in `app/`, a Swift package for macOS 14 and later. It
needs Xcode or the Swift toolchain, so it builds only on a Mac:

```console
make app-test      # swift test: the ZCCareCore tests
make app           # bin/app.noindex/ZCCare.app, signed ad hoc
make app-install   # copy it to ~/Applications
make app-icon      # redraw the icons from app/icon/mark.svg
```

Logic goes in `ZCCareCore`, which has no UI and is what the tests cover. The
`ZCCare` target holds only SwiftUI and AppKit. The app runs the CLI for
anything that changes the workstation, so the CLI's checks apply to it too.

A ZC Care change that deletes or trashes files asks first. It names what it
will remove. A test proves it leaves alone what it must keep, such as a
running Claude Code version or an AI tool's chats. `zccare://` URLs open the
installed app, so test them after `make app-install`.

Screenshots in a README or the manual show no personal data: no real names,
client folders, hostnames or device names.

See [app/README.md](app/README.md) for how the app works.

## Docs

The manual is Antora, in `docs/modules/ROOT`:

```console
make docs && open build/site/index.html
```

It builds on the [zc-supplemental-ui](https://github.com/zoolcoder/zc-supplemental-ui)
theme release named in `package.json`; `npm run docs:local` builds against a
checkout of the theme next to this repository instead.

It must build with no warnings. `${VAR}` in prose is an attribute reference;
wrap it in `+…+` or it renders as nothing. A new page also needs a line in
`nav.adoc`.

A change to a command, a flag or a JSON shape updates `commands.adoc` and
`plugin/adapters/cloud/AGENTS.md` in the same pull request. A tool added to the
reference setup gets a page under `pages/toolbox/`.

## Releases

Only the maintainer releases; see [GOVERNANCE.md](GOVERNANCE.md#releases).
In short: a `release/X.Y.Z` branch from `develop` moves the *Unreleased*
section of `CHANGELOG.md` under the version, merges into `main`, and the
`vX.Y.Z` tag on `main` starts the release workflow.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
