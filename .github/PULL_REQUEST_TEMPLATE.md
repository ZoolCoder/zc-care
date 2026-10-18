## What

<!-- One topic, and why. Link the issue: Closes #123 -->

## Checklist

- [ ] `make test` and `make lint` pass, `gofmt -l .` prints nothing
- [ ] Touches `app/`: `make app-test` passes, and anything that deletes asks first
- [ ] Targets `develop`; only `release/*` and `hotfix/*` target `main`
- [ ] Conventional commit messages, rebased on `develop`
- [ ] No new non-stdlib dependency, or the pull request explains why one is unavoidable
- [ ] `Plan` still writes nothing: every write is inside an action's `Do`
- [ ] Config a provider cannot honour is rejected in `config.Validate`, not ignored
- [ ] Touches a credential path: called out above. No credential reaches stdout or an MCP reply
- [ ] New command or JSON shape: a test, `commands.adoc`, and `plugin/adapters/cloud/AGENTS.md` updated
- [ ] New or changed skill: eval case under `plugin/evals/` when it applies, deletes or handles credentials
- [ ] No real path, host or account name in tests or fixtures
