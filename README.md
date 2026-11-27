# lodestar-infra

The shared platform for Kynosura and the fullstack template, as code: a GKE cluster and the
Cloudflare edge in front of it, written in OpenTofu.

CI validates, lints and runs mock-provider tests; it never holds cloud credentials and never runs
`tofu apply`. The agent that wrote this code never applies it. The owner applies the bootstrap once and,
after reviewing the plan, runs the state-only import by hand: see [`docs/import-runbook.md`](docs/import-runbook.md).

## Layout

| Path | Contents |
| --- | --- |
| `bootstrap/` | One-off root that creates the remote-state bucket |
| `modules/` | Reusable modules, each with a `tofu test` file using mock providers |
| `envs/apps/` | The root for the apps cluster, composed from the modules |
| `docs/` | Plans, decisions, the import runbook and the hardening runbook |
| `tools/` | `pins.tsv` (pinned, checksum-verified toolchain) and hash-pinned Python requirements |
| `scripts/` | `tools.sh` installer and its safe archive extractor; `github-settings.sh` (repository settings as code) |
| `tests/` | Bats tests for the installer and the settings script |
| `.github/` | Workflows (CI, PR title, Scorecard), Dependabot and the pull request template |

## Prerequisite

[`uv`](https://docs.astral.sh/uv/) on your PATH (the installer uses it for Python tools), plus `curl`,
`make` and `bash`. Everything else is installed into `./.tools`, never system-wide.

## Commands

| Command | What it does |
| --- | --- |
| `make tools` | Install the pinned toolchain into `./.tools` (each download checked against its sha256) |
| `make tools-dry-run` | Show what `make tools` would do, install nothing |
| `make fmt` | `tofu fmt -check -recursive` |
| `make validate` | `tofu init -backend=false` and `tofu validate` per root |
| `make lint` | tflint per root, then checkov |
| `make test` | `tofu test` per root with a `tests/` directory, then `bats tests/` |
| `make actions` | actionlint and zizmor (offline) over `.github/` |
| `make check` | All of the above, plus shellcheck and gitleaks over the git history |

With no OpenTofu roots yet, each target prints `no OpenTofu roots yet` and succeeds.

## CI

`.github/workflows/ci.yml` runs on pull requests, on pushes to `main` and on demand. It installs the same
pinned tools with `make tools`, then runs the `make check` gates: fmt, validate, tflint, checkov,
`tofu test`, bats, shellcheck, gitleaks, actionlint and zizmor. It has no cloud credentials and never
applies anything. Its last job, **`CI OK`**, fails unless every other job passed: it is the required check,
together with **`PR title (Conventional Commits)`** from `pr-title.yml`. `scorecard.yml` publishes an OpenSSF
Scorecard weekly.

To protect `main`, the owner runs this once, logged in with their own `gh auth login` as a repository admin:

```sh
bash scripts/github-settings.sh            # dry run: prints every call and the ruleset JSON
bash scripts/github-settings.sh --apply    # applies it; safe to repeat (the ruleset is updated in place)
```

After that, `main` takes pull requests only: squash merges, both checks green and up to date, no force
push, no deletion, no bypass. Secret scanning with push protection, Dependabot alerts and security updates,
and private vulnerability reporting are switched on.

### Provider updates

Dependabot's `opentofu` ecosystem opens a weekly grouped pull request for each root and module, bumping the
exact `google` pin and its `.terraform.lock.hcl`. Review it like any change: CI runs validate and the
mock-provider tests. If it ever fails to keep the lock files right, bump by hand about monthly:
change the pin, then run `tofu providers lock -platform=linux_amd64 -platform=darwin_arm64` in each
root and module.

## Applying (by hand, never from CI)

Follow [`docs/import-runbook.md`](docs/import-runbook.md): bootstrap the state bucket once, then plan,
review and apply the import of `envs/apps` (variables go in git-ignored `*.tfvars` files), then run the
verification checks. After that, [`docs/hardening-runbook.md`](docs/hardening-runbook.md) applies the
security baseline (secrets encryption, RBAC, flow logs, audit logs) as in-place changes.

The step-by-step guides live in the fullstack template repository: `wiki/gke-cluster-setup.md` and
`wiki/cloudflare-setup.md`.

## Licence

Apache-2.0, see `LICENSE`.
