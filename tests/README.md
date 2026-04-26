# tests/

Unit + contract tests for the `copilot-qa-suite` plugin, written in
[bats-core](https://github.com/bats-core/bats-core).

## Scope

- `tests/bats/lib/`      — `hooks/lib/config.sh` + `hooks/lib/copilot-call.sh`
- `tests/bats/hooks/`    — dispatcher routing + sub-hook integration
- `tests/bats/contract/` — read-only-flag invariant + sub-hook contract

The `tools/` directory (benchmarks) is intentionally out of scope.

## Running locally

```bash
# install bats-core + jq once
sudo apt-get install -y bats jq         # Debian/Ubuntu
brew install bats-core jq               # macOS

# run the suite
bats -r tests/bats
```

Tests are hermetic: each test creates `$BATS_TEST_TMPDIR`-scoped
project / cache / config dirs, prepends a stub `bin/` to `$PATH`, and
clears all `COPILOT_QA_*` env vars. No real `copilot` or `claude` CLI
is required.

## CI

`.github/workflows/test.yml` runs the suite on every pull request and
on pushes to `main`. A second job runs `shellcheck` over `hooks/`.

## Adding a test

1. Pick the right directory: `lib/`, `hooks/`, or `contract/`.
2. `load ../helpers/common` and call `qa_setup_env` in `setup()`.
3. Use `qa_install_stub <name> <stdout>` for binaries on `$PATH`.
4. For dispatcher / sub-hook tests, mirror the fake-plugin-root
   pattern in `tests/bats/hooks/dispatcher.bats`.
