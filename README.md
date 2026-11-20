# lodestar-infra

The shared platform for Kynosura and the fullstack template, as code: a GKE cluster and the
Cloudflare edge in front of it, written in OpenTofu.

Everything here is written and tested without ever being applied. CI validates, lints and runs
mock-provider tests; it never holds cloud credentials and never runs `tofu apply`. A person applies
changes from a local machine.

## Layout

| Path | Contents |
| --- | --- |
| `bootstrap/` | One-off root that creates the remote-state bucket |
| `modules/` | Reusable modules, each with a `tofu test` file using mock providers |
| `envs/dev/` | The dev environment root, composed from the modules |
| `docs/` | Plans and decisions |
| `tools/` | `pins.tsv` (pinned, checksum-verified toolchain) and hash-pinned Python requirements |
| `scripts/` | `tools.sh` installer and its safe archive extractor |
| `tests/` | Bats tests for the installer |

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
| `make check` | All of the above, plus shellcheck and gitleaks over the git history |

With no OpenTofu roots yet, each target prints `no OpenTofu roots yet` and succeeds.

## Applying (by hand, never from CI)

1. Bootstrap the state bucket from `bootstrap/`.
2. Set the variables locally (copy the `*.tfvars.example` file to `*.tfvars`, which Git ignores).
3. Review `tofu plan`.
4. `tofu apply`.
5. Run the verification checks in the setup guides.

The step-by-step guides live in the fullstack template repository: `wiki/gke-cluster-setup.md` and
`wiki/cloudflare-setup.md`.

## Licence

Apache-2.0, see `LICENSE`.
