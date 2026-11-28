# lodestar-infra: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to carry out this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the shared platform as code. That's the GKE cluster and its Google Cloud foundations, plus the Cloudflare zone, tunnel and Access, which host Kynosura and the fullstack template. All of it is written and tested **without applying anything**, so the owner's setup becomes a reviewed `tofu apply`.

**Architecture:**
- OpenTofu, with small modules (`modules/gcp-*`, `modules/cloudflare-*`) composed per environment (`envs/dev`).
- State in a versioned, locked GCS bucket, created by a one-time `bootstrap/` stack.
- Every resource maps to a step in the two setup guides, and the guides' verification steps stay the acceptance tests after apply.

**Tech stack:** OpenTofu (an exact version), the `hashicorp/google` provider (a pinned major), the `cloudflare/cloudflare` provider v5 (pinned), tflint (with the google ruleset), checkov, `tofu test` with mock providers, pre-commit and GitHub Actions.

**Spec:** these, in the fullstack template repository:
- `wiki/plans/2026-11-20-github-actions-migration-design.md`, v2.1, §7.9 and §11 item 11;
- the guides `wiki/gke-cluster-setup.md` and `wiki/cloudflare-setup.md`. They're the source of the resource settings.

## Global constraints

- **The agent never applies anything and never uses cloud credentials.** No agent step calls a cloud API, except provider downloads from the OpenTofu registry. Modules are proven with `tofu validate`, `tofu test` with mock providers, tflint and checkov. Since 2026-11-27, the owner runs plan and apply with their own login, and only after review:
  - the one-time bootstrap apply (the state bucket and its key);
  - the import apply, which writes state only.

  The owner's no-change `tofu plan` is the acceptance test of phase 1.
- **Provider and tool versions:** pinned. `.terraform.lock.hcl` is committed for every root, with hashes for `linux_amd64` and `darwin_arm64`.
- **Never in Git:** `*.tfstate*`, `*.tfvars`, `.terraform/`, plan files, tokens, account IDs and project numbers. `*.tfvars.example` files carry placeholders only.
- **Security defaults are the guides' settings, or stricter:**
  - private nodes;
  - Dataplane V2;
  - Workload Identity;
  - Shielded nodes;
  - the release channel;
  - the DNS-based control-plane endpoint;
  - least-privilege node and deployer service accounts;
  - WIF conditions on `repository_owner_id` **and** `repository_id`, and one deployer per environment, bound to the repository's OIDC subject for that environment. Repositories created after 2026-07-15 use GitHub's immutable subjects, `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>`. Older ones use `repo:<owner>/<repo>:environment:<env>` unless they opt in. The prefix is an input; never assume the old form;
  - Cloudflare Full (strict), TLS 1.2 minimum, DNSSEC, and CAA/SPF/DMARC.
- **This is a public repository:** no secrets, no real domains or IDs in examples, and every action pinned by SHA.
- **TDD:** every module has a `tofu test` file with mock providers, asserting its security settings.

## Progress

| Phase | Theme | Tasks | Status |
|---|---|---|---|
| 0 | Scaffold | L0.1 | **done** (2026-11-20) |
| 1 | State and Google Cloud | L1.1 to L1.7 | **done** (2026-11-27; see "Phase 1 closed" under L1.7). It imports the owner's by-hand GKE setup; see "Carried from the owner's by-hand setup" below |
| 2 | Cloudflare | L2.0 to L2.3 | L2.0 built (PR #7, 2026-11-27); the owner sets Cloudflare up by hand first, then L2.1 to L2.3 import it |
| 3 | Environments, CI and docs | L3.1 to L3.3 | not started (largely superseded by L1.5 to L1.7 and phase 4) |
| 4 | A separate production environment | L4.1 to L4.7 | L4.1 to L4.5 built and reviewed (PR #10, 2026-11-27); the owner applies after the Cloudflare setup; L4.6 and L4.7 after production is live |

### Task L0.1: Scaffold
**Files:** `README.md` (purpose, layout, the apply workflow, links to the guides), `LICENSE` (Apache-2.0), `.gitignore`, `.pre-commit-config.yaml` (tofu fmt and validate, tflint, checkov, gitleaks), `tools/pins.tsv` and `scripts/tools.sh` (checksum-verified install into `.tools/bin` of tofu, tflint and checkov through `uv tool`), and a `Makefile` (`tools fmt validate lint test check`).
- [x] **Verify:** `make tools check` passes on an empty tree.

**Executed (2026-11-20, commits e767ba5 and e68f124):**
- **What exists:** `README.md`, `LICENSE` (Apache-2.0, byte-identical to GitHub's text), `.gitignore`, `.pre-commit-config.yaml` (local hooks only, so pre-commit never downloads), `.tflint.hcl`, `tools/pins.tsv`, `tools/requirements/`, `scripts/tools.sh`, `scripts/safe_extract.py`, `tests/tools.bats` and a `Makefile`.
- **The installer** is ported from the fullstack template: each download is checked against its sha256 before it's unpacked, tar archives go through `filter="data"`, and the Python tools are hash-pinned.
- **A zip branch was added,** because tflint ships zips. It refuses `..` names, absolute names, symlinks and special files, and a setuid bit never survives.
- **Pins:** tofu 1.13.9, tflint 0.66.0, the google ruleset 0.41.0 (installed from a verified archive, so `tflint --init` fetches nothing), gitleaks 8.30.1, shellcheck 0.11.0, bats 1.14.0, checkov 3.4.5 and pre-commit 4.7.0.
- **Results:** `make check` on the empty tree exits 0, with a "no OpenTofu roots yet" line from each target. bats: 14/14.
- **Review:** one Important issue, the zip branch had a single test; it was fixed in round 1 with four more cases. The controller also fixed one trailing newline in the LICENSE. Re-reviewed clean.
- **Carried to L1.1:** the docstring wording, a comment on mode-less zip members, a note that the bats hash isn't vendor-attested, checkov `--skip-path .tools`, and a first `pre-commit run --all-files`.

### Task L1.1: The state bootstrap
**Files:** `bootstrap/` (a GCS bucket with versioning, uniform bucket-level access, public access prevention, an optional CMEK key, and a retention lock on noncurrent versions), plus `bootstrap/README.md` (a one-time apply with local state, then migrate).
- [x] **Tests:** the bucket is versioned, has uniform access and prevents public access.

**Executed (2026-11-27, commits 9c28345, 9363eb0 and 4da8033):**
- **What exists:** `bootstrap/`, with:
  - the `cloudkms` and `storage` APIs;
  - a KMS key ring and key (rotation a variable, 90 days by default; `prevent_destroy`);
  - the state bucket: versioned, uniform access, public access prevention enforced, `force_destroy = false`, `prevent_destroy`, and a noncurrent-version rule needing both age and count;
  - optional CMEK, with the storage agent granted before the bucket uses the key;
  - optional `state_admins` (bucket and key bindings), with a validation that refuses `allUsers` and `allAuthenticatedUsers`;
  - the `state_bucket` and `kms_key_id` outputs.
- **Shape:** the root is in its first-apply shape (local state). The README's migration step adds the `gcs` backend and the `aes_gcm` + `gcp_kms` encryption in an untracked `override.tf`. `encryption.example.tf.txt` holds the final block that other roots copy.
- **Pins:** google provider 8.12.0 (2026-11-17), tofu 1.13.9.
- **Results:** `tofu test` 9/9, with mock provider, plan only; `make check` and `pre-commit run --all-files` green. checkov skips only CKV_GCP_62 (bucket access logs), with the reason inline.
- **Also:** the L0.1 deferred minors (the `safe_extract.py` docs and comment, the bats pin note, checkov `--skip-path .tools`).
- **Review:** spec ✅. One Important finding: the public-member test asserted nothing. Fixed in round 1 with the validation and two `expect_failures` runs, and re-reviewed clean. Four minors are deferred to the phase review, one of them a README sentence to correct before the owner applies.

### Task L1.2: Google Cloud network and identity modules
**Files:**
- `modules/gcp-network` (VPC, subnet with secondary ranges, Private Google Access, router plus NAT with error logging);
- `modules/gcp-node-sa` (the minimal node roles);
- `modules/gcp-registry` (Artifact Registry with immutable tags, cleanup policies and the reader binding);
- `modules/gcp-github-wif` (the pool, the provider with the owner-ID and repository-ID condition, per-environment deployer service accounts with subject bindings, the registry writer role and the cluster viewer role).
- [x] **Tests:** the attribute condition includes both IDs; there's one service account per environment; no `roles/editor` or `roles/owner` is granted anywhere.

**Executed (2026-11-27). Three reviewed dispatches, each clean on the first review; the controller's `make check` exits 0:**

**L1.2a, `957860a`.** Each value matches the owner's live resources, and the optionals the owner never set stay unset:
- **`gcp-project`:** the nine APIs, `disable_on_destroy = false`.
- **`gcp-network`:**
  - `apps-vpc`;
  - `apps-subnet` with Private Google Access and `pods`/`services` in live order;
  - `apps-router`;
  - `apps-nat` (AUTO_ONLY, all subnets and ranges, logging `ERRORS_ONLY`);
  - an optional proxy-only subnet, off by default.
- **`gcp-node-sa`:** `gke-nodes` with `roles/container.defaultNodeServiceAccount`, or the four classic roles.
- **`gcp-registry`:** off by default, since the template uses GHCR.

**L1.2b, `b3fae3b` (`gcp-github-wif`):**
- the pool and the `github-oidc` provider;
- the exact stored condition (owner ID, repo ID, `deploy|deploy-ops` on `main` or `v*`, with doubled backslashes);
- `gh-deployer-<env>`, bound to `<sub_claim_prefix>:environment:<env>`, so it works with immutable subjects;
- `roles/container.clusterViewer`, or a custom connect-only role;
- no registry writer;
- optional previews and drift per guide §12.5 and §12.6.

**L1.2c, `0f4f633`:**
- **`gcp-secrets`:** five conditional secretAccessor bindings (`eso-<ns>`), plus the seven empty secrets with user-managed replication in the region. A Makefile grep fails the build if a `google_secret_manager_secret_version` ever appears.
- **`gcp-budget`:** optional; project filter, EUR amount, thresholds 0.5/0.9/1.0/1.5.

**Tests:** 3 + 6 + 4 + 3 + 12 + 6 + 4 runs.

**Deferred:** 10 minor findings, in the ledger for the phase review.

### Task L1.3: The GKE module
**Files:** `modules/gcp-gke`. It creates a Standard zonal cluster with:
- private nodes;
- the DNS-based endpoint, with the IP endpoint optionally disabled;
- Dataplane V2;
- the Workload Identity pool;
- Gateway API standard;
- Shielded nodes with Secure Boot;
- the release channel and a maintenance window;
- the node service account;
- a Binary Authorization evaluation mode (a variable, off until phase 11);
- managed Prometheus, and system plus workload logging;
- an autoscaled node pool, with an optional spot variant;
- labels.
- [x] **Tests:** every setting in the list above; the node service account isn't the default compute account.

**Executed (2026-11-27, commit 543e183):** `modules/gcp-gke`, import-shaped against the owner's live cluster. The values were written from the owner's private, read-only exports, and no identifying value is in Git.
- **Cluster:**
  - a zonal `apps`, built without an inline pool;
  - it ignores `node_pool`, `node_config`, `initial_node_count` and `remove_default_node_pool`;
  - STABLE channel, private nodes, the DNS endpoint with external traffic allowed, the IP endpoint kept (a variable can close it later);
  - Dataplane V2, Workload Identity, Gateway API standard;
  - system and workload logging, plus managed Prometheus;
  - the Sat/Sun 00:00 to 08:00 UTC window, the `cluster=apps` label, cost allocation, `deletion_protection`;
  - Binary Authorization is a variable, unset.
- **Separate `default-pool`:**
  - spot e2-standard-2, pd-balanced 50 GB, COS_CONTAINERD, autoscaling 1 to 3 with `ANY`;
  - the node SA (a validation refuses the default compute account);
  - exactly the two live OAuth scopes, legacy metadata endpoints disabled, shielded secure boot and integrity, GKE_METADATA;
  - auto repair and upgrade, SURGE 1;
  - it ignores `node_count` and `initial_node_count`.
- **Results:** 14 tests; `make check` green.
- **Review:** clean. Every value the module sets equals live, and the sections it leaves unset are Optional+Computed in provider 8.12.0.
- **Carried to L1.5:** an "expected or possible diff" checklist for the owner's first plan, and a hard stop on any replacement.
- **Carried to L1.4 (post-import hardening):** the insecure RBAC bindings, security posture, application-layer secrets encryption, and the node scopes.

**Order (ruling 2026-11-27):** L1.5, the import, runs before L1.4, because L1.4 changes live resources.

### Task L1.4: The GKE security baseline extras
**Files:** VPC flow logs on the subnet, Data Access audit logging for the container API, and the `gke-security-posture` settings where the provider supports them.
- [x] **Tests and checkov:** checkov is clean, with documented skips only.

**Executed (2026-11-27, commits 51a1450, 8850f53 and a42e52b; owner go on the proposed defaults):**
- **RBAC:** the insecure bindings to `system:authenticated` and `system:unauthenticated` are refused.
- **Secrets encryption:** application-layer encryption with a new `gcp-gke-secrets-key` module (ring `gke`, key `secrets` in the cluster's region, 90-day rotation, `prevent_destroy`). The GKE service agent gets EncrypterDecrypter, and the cluster only uses the key after that grant. `key_id` is built from the inputs, so the plan shows `ENCRYPTED`.
- **Flow logs:** on the subnet, 10-minute aggregation and 0.1 sampling.
- **Container API audit config:** `ADMIN_READ` and `DATA_WRITE`, with no `DATA_READ`.
- **Security posture:** `BASIC`. Vulnerability scanning stays off, because GKE retired both tiers.
- **Deferred:** node scopes and spot to on-demand, to one pool swap before go-live.
- **Runbook:** `docs/hardening-runbook.md`. The expected plan is 4 to add, 2 to change, 0 to destroy. It covers:
  - the control-plane restart of a zonal cluster;
  - the RBAC leftover check;
  - partial-failure and rollback paths.
- **Results:** `make check` green (checkov 71 passed, 0 failed).
- **Review:** the opus review found two Important runbook and plan-visibility issues, fixed in one round; the re-review is clean.
- **Owner apply (2026-11-27): done.**
  - The plan matched exactly: 4 to add, 2 to change, 0 to destroy, `DECRYPTED -> ENCRYPTED` with the literal key, and both RBAC switches `true -> false`.
  - After the apply, `tofu plan` reports **No changes**.

### Task L1.5: The `envs/apps` composition and the import (added 2026-11-27)
**Files:**
- `envs/apps/{versions.tf,main.tf,variables.tf,outputs.tf,backend.tf,imports.tf,terraform.tfvars.example}` and its `.terraform.lock.hcl`;
- `docs/import-runbook.md`.

This pulls the Google half of L3.1 forward, because the import needs a root. `envs/apps` is the one shared cluster that hosts the dev, qa and production namespaces; it is not "dev".

`imports.tf` holds one `import` block per hand-built resource. Each block's `id` is built from variables, so no project ID, number or account ID ever enters Git.

**The runbook:** the owner's exact commands, written for bash and zsh alike, with every variable before a `:` in braces:
- `tofu init` with the bucket backend and encryption;
- `tofu plan`;
- the expected summary line;
- `tofu apply`, which imports only;
- `tofu plan` again, expecting "No changes";
- then the guides' checks.
- [x] **Tests:** `tofu validate` on the root; a test that every import `id` uses variables, with no literal project ID; the outputs map onto the template's GitHub variables table.
- [x] **Owner acceptance** (reworded 2026-11-27 by the L1.2a ruling and the phase review):
  - The first plan shows "41 to import, 0 to add, 0 to destroy".
  - In-place updates are state-only, at most 10, and nothing else:
    - the 9 `google_project_service` (`disable_on_destroy`, `disable_dependent_services`);
    - the cluster's `resource_labels` and `terraform_labels` gaining `cluster = "apps"`.
  - After the import apply, `tofu plan` shows "No changes".
  - Any replacement or destroy is a hard stop.

**Owner-run acceptance (2026-11-27): PASSED.**
1. **Bootstrap.** The bucket, key ring, key and two APIs (5 added). The state moved into the bucket, proven encrypted (`encrypted_data` present, no plain resources). The final override is enforced, and the local state was removed.
2. **First import plan: failed.** The provider bills requests to the project, and the Service Usage API was off there, so the 9 API reads failed (403). The fix (commit 76ecf0c, reviewed) has the bootstrap enable `serviceusage.googleapis.com`: 1 added.
3. **Import plan: `41 to import, 0 to add, 1 to change, 0 to destroy`.** The only change was the cluster's state-only `cluster = "apps"` labels. The APIs showed no change.
4. **After the import apply,** `tofu plan` reports **No changes. Your infrastructure matches the configuration.**

**Executed (2026-11-27, commits 7dc7a6e and b3d996e, plus the phase-1 fix wave):**
- **Module fixes from the owner's live exports:** the NAT's `enable_endpoint_independent_mapping = false`; the budget's `calendar_period = "MONTH"` and `credit_types_treatment = "INCLUDE_ALL_CREDITS"`.
- **The `envs/apps` root:**
  - Pins: tofu 1.13.9 and google 8.12.0.
  - Backend: the `gcs` backend from variables.
  - Encryption: `gcp_kms` + `aes_gcm`, enforced for state and plans.
  - Provider: `user_project_override` and `billing_project`, for the budget.
  - Wiring: every module, with the registry, previews and drift off and the deployer role `clusterViewer`.
  - Outputs: mapped onto the template's GitHub variables, plus `dns_endpoint`.
  - Placeholders: in `terraform.tfvars.example` only.
- **`imports.tf`:** 41 instances in 18 blocks. Every id is built from variables or locals, and a bats test with a negative case guards that.
- **Tests:** a mock `tofu test` panics on import blocks, so the composition is tested on a copy of the root without `imports.tf` and `backend.tf`. `make check` is green.
- **`docs/import-runbook.md`:** the owner's zsh-safe steps, with a hard stop on replace or destroy.
- **Review:** clean.
- **The phase review** found four Important issues: a wrong expected cluster diff; a bootstrap migration that could silently do nothing and then lose the state; no attribute-level check of in-place updates; and this plan not being updated. One fix wave corrected the runbook and READMEs. The controller updated this plan.

### Task L1.6: Static CI and repository hygiene (added 2026-11-27, owner go; supersedes L3.2)
The repository is public and manages live infrastructure, so CI moves from the last phase to now. It uses no cloud credentials.
**Files:** `.github/workflows/ci.yml`, `.github/workflows/pr-title.yml`, `.github/workflows/scorecard.yml`, `.github/dependabot.yml`, `.github/zizmor.yml`, `.github/CODEOWNERS`, `.github/pull_request_template.md`, `scripts/github-settings.sh`, and README.
- [x] **`ci.yml`:** the same gates as `make check`, with the same pinned tools installed by `make tools` (local and CI parity). That is fmt-check, validate with `-backend=false`, tflint, checkov, `tofu test`, bats, shellcheck and gitleaks, plus actionlint and zizmor. One aggregated required check, `CI OK`. Every action is SHA-pinned; there are timeouts, `concurrency`, read-only `permissions`, and `persist-credentials: false`.
- [x] **PR title check** (Conventional Commits), **Dependabot** (GitHub Actions, plus the OpenTofu/Terraform providers for each root and module), and **OpenSSF Scorecard**. The template's patterns are reused, adapted to this repository.
- [x] **`scripts/github-settings.sh`:** dry-run by default, `--apply` explicit. It sets a `main` ruleset (PRs only, `CI OK` and the PR-title check required, squash only, no force-push or deletion), security settings, and Dependabot alerts. The owner runs it once with their own `gh` login.
- [x] **Tests:** bats for the settings script's dry run, and actionlint and zizmor clean. Before it is called green, CI parity is checked in a runner-like fresh clone with only CI's tools.

**Executed (2026-11-27, commits 3cf8bae, 0ca2c44, eb92707, a09cff2 and 42da6b4; built in an isolated worktree and rebased onto main):**
- **`ci.yml`:** runs the exact `make check` targets, with the tools from `make tools`. `make check` now includes `make actions` (actionlint plus a hash-locked zizmor).
  - The single required check is `CI OK`, with `if: always()`; any non-success fails it.
  - Top-level `permissions: {}`, `persist-credentials: false`, timeouts and concurrency.
- **PR title:** `PR title (Conventional Commits)`, with the title read from `env` and job `permissions: {}`.
- **Scorecard:** with SARIF upload.
- **Dependabot:** github-actions, plus the `opentofu` ecosystem (per dependabot-core; a manual-bump fallback is documented). The PR template and the zizmor config come from the template patterns. No CODEOWNERS (ruling).
- **`scripts/github-settings.sh`:**
  - Dry run by default. It does a read-only GET to say whether it would create or update.
  - The `main` ruleset: PRs required with 0 approvals; strict `CI OK` and PR-title checks (GitHub Actions app); squash only; no force-push or deletion; no bypass.
  - Squash commits take the PR title and body.
  - It also turns on secret scanning, push protection, Dependabot alerts and security fixes, and private vulnerability reporting.
- **Parity proof:** a fresh worktree with no tfvars gives `make check` rc 0.
- **Review:** one Important finding (the squash title) and four small items, fixed in one round; the re-review is clean. Action pins are reused from the template; `setup-uv` was verified against its tag.
- **Owner steps:** push; a green first run; then `bash scripts/github-settings.sh` (dry run) and `--apply`.

### Task L1.7: PR plans and weekly drift, with a read-only keyless identity (added 2026-11-27, owner go)
**Files:** `modules/gcp-ci-planner` (or an extension of `gcp-github-wif`), the `envs/apps` wiring, `.github/workflows/plan.yml`, `.github/workflows/drift.yml`, and docs.
- [x] **Identity:** a Workload Identity provider and a planner service account limited to this repository, using its immutable owner and repository IDs, `job_workflow_ref` pinned to `plan.yml` and `drift.yml`, and the PR and `main` refs. Read-only roles: viewer-level reads, the state bucket's object read, KMS decrypt on the state key, and nothing that writes. Plans run with `-lock=false`.
- [x] **`plan.yml`:** on PRs from this repository (never from forks), `tofu plan` for `envs/apps`. The summary goes into the job summary, never the full plan in a public log. The plan file is never uploaded.
- [x] **`drift.yml`:** weekly and on demand. `tofu plan -detailed-exitcode`; on drift it opens or updates one issue, with the summary only.
**Executed (2026-11-27, commits 397a759, 6743687, 8e8fde3, de446c0, 2f6ba97 and 292bdb9; built in an isolated worktree, opus security review plus one fix round, re-review clean):**
- **`modules/gcp-ci-planner`:**
  - a new pool `github-infra` and provider `lodestar-infra` (owner ID, repo ID, `job_workflow_ref` limited to plan.yml/drift.yml on `main` or `refs/pull/N/merge`, and an event allow-list);
  - SA `tofu-planner`, with exactly two WIU subjects (`<immutable prefix>:pull_request` and `:ref:refs/heads/main`);
  - roles: viewer, iam.securityReviewer and serviceUsageConsumer; objectViewer on the state bucket; EncrypterDecrypter on the state key (OpenTofu's gcp_kms calls Encrypt on every run, and nothing grants state writes); billing.viewer for the budget;
  - a forbidden-roles test.
- **`plan.yml` and `drift.yml`:**
  - same-repo PRs only (never forks, never Dependabot); a "not configured yet" skip;
  - identifying inputs are individual secrets (masked); region and zone are variables;
  - no plan text in logs: only an address/action summary; error lines are redacted literally and never truncated;
  - drift keeps one issue, filtered by the github-actions author, opened or closed by exit code.
- **`docs/ci-identity-runbook.md`:** the owner's steps.
- **Results:** `make check` green with no tfvars (bats 44).
- **Expected owner plan:** 11 to add.

- [x] **Owner acceptance:** the owner applies the identity from a reviewed plan ("N to add, 0 to change, 0 to destroy"). A PR shows its plan summary, and a drift run reports "No changes".

**Executed (2026-11-27):**
- Applied 2026-11-27: 12 added, including the Cloud Billing API (`google_project_service.cloudbilling`, added by a fix PR after the first plan failed with `SERVICE_DISABLED`; the earlier estimate was 11).
- 16 secrets and 2 variables set; the workflows no longer skip.
- The first drift run succeeded with no drift (`No changes`).
- The public log was scanned for every identifying value: 0 identifiers.
- Follow-up: the tfvars append in the runbook is now idempotent (the owner's second run hit "Attribute redefined"); the operations runbook has the sequence in 12.4.

**Phase 1 closed (2026-11-27).**
- **Live:** the state bucket and key (bootstrap); the imported project APIs, network, node service account, cluster and secrets (envs/apps, "No changes"); the GKE hardening of L1.4; the budget; the application deploy identity; the read-only CI identity with PR plan summaries and the weekly drift run. The registry stays off.
- **Deferred:**
  - `roles/viewer` for the planner, to a possible custom role;
  - an optional separate service account for PR plans (today one planner serves PRs and `main`);
  - the `startsWith` condition on the secrets bindings: changing it would replace the bindings;
  - the node scopes and spot to on-demand, at the one pool swap before go-live.

### Task L2.0: The tunnel token's secret container and access grant (added 2026-11-27)
**Files:** `modules/gcp-platform-secret`, the `envs/apps` wiring, tests, and `docs/operations/`.
- [x] **The module:** a map of secret IDs to namespaces. For each secret:
  - one Secret Manager container, with user-managed replication in the region;
  - one conditional `secretAccessor` member for the namespace's `external-secrets` principal, titled `eso-<namespace>`, with the expression `resource.name.startsWith("projects/<number>/secrets/<id>/")`;
  - no version resource: the token value never enters OpenTofu.
- [x] **`envs/apps`:** `cloudflared-tunnel-token` for namespace `cloudflared`. `modules/gcp-secrets` and `imports.tf` are untouched.
- [ ] **Owner acceptance:** at the tunnel step of the Cloudflare setup, the plan shows `2 to add, 0 to change, 0 to destroy`; then apply; then "No changes". The token version is added by hand, from stdin.

**Executed (2026-11-27, commits 04d3440 and ea1977d, PR #7):**
- Tests pin the principal, title, expression, role and region, and cover sibling-secret exclusion and the 63-character namespace cap.
- The `envs/apps` composition still has 7 app secrets and 5 bindings.
- `make check` is green with no tfvars. The review was approved; its 3 minor findings were fixed.

### Task L2.1: Cloudflare zone baseline
**Files:** `modules/cloudflare-zone`. It covers:
- the zone settings: Full (strict), Always Use HTTPS, TLS 1.2 minimum, TLS 1.3, Automatic HTTPS Rewrites, and HSTS staged through a variable;
- DNSSEC;
- the CAA, SPF and DMARC records;
- the WAF managed ruleset.

The registrar stays manual.
- [ ] **Tests:** each setting.

### Task L2.2: Tunnel and Access
**Files:** `modules/cloudflare-tunnel` (the tunnel, its routes as input data, and the proxied CNAMEs) and `modules/cloudflare-access` (Access applications per hostname, with policies and an optional service token for CI smoke tests).
- [ ] **Tests:** every route hostname gets a proxied record; every non-public hostname is covered by an Access application.

### Task L2.3: R2 (optional)
**Files:** `modules/cloudflare-r2` (a private bucket and lifecycle rules). No public domain is allowed: a variable validation refuses one.
- [ ] **Tests:** the validation refuses a public domain.

### Task L3.1: The `envs/dev` composition
**Files:** `envs/dev/{main.tf,variables.tf,outputs.tf,backend.tf,terraform.tfvars.example}`. The outputs map one-to-one onto the GitHub variables table in the template's `wiki/platform-setup.md`.
- [ ] **Also add a service-level module** for routes and Access applications per app, used by the template and Kynosura (`modules/app-edge`).

### Task L3.2: CI
**Superseded (2026-11-27) by L1.6 and L1.7.** What remains here: extend the CI to the Cloudflare roots once phase 2 exists.
**Files (original):** `.github/workflows/ci.yml`, with no credentials. It runs fmt-check, validate (with `-backend=false`), tflint, checkov, `tofu test`, gitleaks and actionlint, plus zizmor on itself. Every action is SHA-pinned; there are timeouts, `concurrency`, and read-only permissions.

### Task L3.3: Docs
**Files:** `docs/apply-runbook.md` and `docs/mapping.md`.
- **The apply runbook:** bootstrap; set `TF_VAR_*` or local tfvars; `tofu plan` reviewed; apply; then run the guides' checks.
- **The mapping:** each guide step mapped to its resource.

Also cover drift detection, which runs as `tofu plan` on a schedule once credentials exist; that's for later.

### Task L3.4: Split the operations runbook into `docs/operations/` (added 2026-11-27, owner "yes")
**Files:** `docs/operations/{README,workstation,gcp-foundation,gke,github-identity,secrets,github-settings,opentofu,troubleshooting,glossary}.md`, the `docs/operations-runbook.md` stub, inbound references, `tests/operations-docs.bats` and its fixture.
- [x] **The split preserves the content, proven by tests against a byte-identical copy of the original:**
  - every code block (116), Expect line (70), table row, heading and prose line survives;
  - the only exceptions are an explicit, documented list (the old contents list, intro, production pointer and two link rewrites).
- [x] **Six pre-existing zsh traps fixed:** 3 comments in code blocks moved to prose, and 3 `echo` lines became `printf`. A guard stops new ones.
- [x] **Section numbers and anchors are kept,** so references like "ops 5.3" stay valid.

**Executed (2026-11-27):**
- Built in an isolated worktree.
- The review approved it; the controller verified the fixture with `cmp` and ran the tests (21/21).
- Two fix rounds: the prose-preservation test, the zsh traps, the stub table, and two prose lines aligned with `printf`.
- `cloudflare.md` is written from the owner's real Cloudflare run.

## Phase 4: A separate production environment (added 2026-11-27, owner-approved design)

**Spec:** `docs/designs/2026-11-27-production-environment.md`, approved 2026-11-27. The owner answered:
- the production cluster hosts **all three projects**;
- the pool is capped at **4 nodes in total**;
- it uses the **same billing account** as `apps`, in EUR.

**Order:**
- The code can be built now.
- The owner applies after the Cloudflare by-hand setup, and before the first production deploy.
- Every task's PR shows the `apps` plan as **"No changes"**, except L4.6.

**Review focus (phase 4):**
1. **`apps` drift from a new module input.** Every new input's default must render `apps` byte-identically. The PR plan job and a drift run prove it.
2. **A fresh-project creation order.** Resources are created, not imported, so the APIs, the container service agent and the cluster's Workload Identity pool must exist before the grants that need them. Explicit `depends_on`, with a test that the graph has them.
3. **A production identity reachable from `apps`.** No `apps` principal may get a role on production resources, and the production provider must admit only `environment:production` subjects of the listed repositories.
4. **The state migration of the production bootstrap**, with the same proof as `bootstrap/` before any local state is deleted.
5. **A public control-plane IP on a newly created cluster.** Production must set `enable_public_endpoint = false`, with a test.

### Task L4.1: Module inputs with byte-identical defaults
**Files:** `modules/gcp-gke`, `modules/gcp-github-wif`, their tests, and the envs/apps composition test.
- [x] **`gcp-gke`:**
  - `node_locations` (default `null`);
  - `location_policy` (default `"ANY"`; validation `ANY` | `BALANCED`);
  - `oauth_scopes` (default: today's two scopes);
  - the maintenance window days and times (default: today's weekend window);
  - the pool's `initial_node_count = var.min_node_count` (already ignored in `lifecycle`);
  - the `location` description says "zone or region".
- [x] **`gcp-github-wif`:**
  - an optional `allowed_environment` term in the provider's attribute condition (default `null`: unchanged);
  - one pool serving **several repositories**, each with its owner and repository IDs, its immutable subject prefix and its own deployer;
  - deployer IDs as an input, validated at 30 characters or fewer (the service account limit).

  Choose between one provider per repository and one provider with a repository list, record the ruling, and keep `apps` byte-identical.
- [x] **Tests:** for each input, the default renders today's exact values, and the production values render as specified. For WIF: a two-repository case, a foreign repository refused, and a non-production environment refused when `allowed_environment` is set.

**Executed (2026-11-27, PR #10; review plus 1 fix round, re-review clean):** the `gcp-gke` inputs `node_locations`, `location_policy`, `oauth_scopes`, the maintenance window (with a 48h-per-32-days validation) and the per-zone, create-only `initial_node_count`; the `gcp-github-wif` inputs `allowed_environment` (CEL-safe, refusing previews and drift in a production call) and `deployer_account_ids` (6–30 characters), with the multi-call rules in its README. Ruling: per-zone limits 1–2 across 2 zones instead of a total cap, because only per-zone limits guarantee a node in each zone. All defaults keep `apps` byte-identical.

### Task L4.2: The state module and the production bootstrap
**Files:** `modules/gcp-state-backend` (new), `bootstrap/` (refactored), a production bootstrap root, the Makefile root discovery if needed, `dependabot.yml`, and tests.
- [x] **The module:** the bucket, the KMS ring and key, `state_admins` (objectAdmin) and `state_readers` (objectViewer plus EncrypterDecrypter), with the bootstrap's existing validations.
- [x] **`bootstrap/` calls the module, with `moved` blocks for every resource.** Its tests move with the resources they check. Owner acceptance is the owner's local plan: moves only, 0 to add, 0 to change, 0 to destroy. Hard stop otherwise.
- [x] **The production bootstrap root:** the same module for the production project, with a git-ignored `override.tf` backend and the same state-migration proof steps as `bootstrap/`. Its lock file carries the linux_amd64 and darwin_arm64 hashes, and the Makefile validates, lints, scans and tests it.

**Executed (2026-11-27, PR #10; review plus 1 fix round):** `modules/gcp-state-backend`. `bootstrap/` calls it with `moved` blocks, so the expected owner plan is exactly 3 moves (key ring, key, bucket) and 0 / 0 / 0; a bats test proves every live address is covered. `bootstrap/prod` (prefix `bootstrap-prod`) enables 4 APIs, including Cloud Resource Manager. Ruling: no `state_readers` input, because the CI planner grants itself read access. Owner step pending: init, the 3-move plan and apply (production runbook step 0).

### Task L4.3: The `envs/prod` composition
**Files:** `envs/prod/{versions,providers,backend,main,variables,outputs}.tf`, `terraform.tfvars.example`, and tests under `tests/envs-prod/`.
- [x] **Modules:**
  - `gcp-project` (no `artifactregistry`; no `cloudkms`, which the bootstrap owns);
  - `gcp-network`: `prod-vpc`, `prod-subnet` 10.40.0.0/20, pods 10.50.0.0/16, services 10.60.0.0/20, `prod-router`, `prod-nat`;
  - the node service account;
  - `gcp-gke`: cluster `prod`, regional `europe-west1`, nodes in `-b` and `-c`, `spot = false`, `location_policy = "BALANCED"`, `min_node_count = 1` and `max_node_count = 2` per zone (a cap of 4, with a node guaranteed in each zone), the Tuesday/Wednesday window, `enable_public_endpoint = false`, `deletion_protection`;
  - `gcp-gke-secrets-key`;
  - `gcp-github-wif`: the three repositories, production only;
  - `gcp-secrets`: one instance per service with `app_environments = ["production"]` and `db_environments = []`;
  - `gcp-platform-secret`: the production tunnel token;
  - `gcp-ci-planner`;
  - `gcp-budget`: €250, with alerts at 50/90/100/150 %.
- [x] **Explicit `depends_on`:** everything on `module.project`; the secrets key's agent grant on the container API; the External Secrets grants on `module.gke`.
- [x] **Tests:**
  - every setting above;
  - no `apps` identifier or principal anywhere in the root;
  - no forbidden role;
  - the `depends_on` edges;
  - `make check` green with no tfvars.

**Executed (2026-11-27, PR #10; review plus 1 fix round):** `envs/prod` for 3 services. One `gcp-github-wif` call per service (`for_each`), with the custom role created once in `modules/gcp-gke-connect-role`, so adding or renaming a service never recreates another pool. Exact-string tests cover each pool's condition and each deployer's subject. The `depends_on` chain is explicit (APIs, then the cluster, then the Workload Identity bindings). The audit config waits for the APIs. A first plan creates 36 + 6S + K resources (58 for 3 services and 4 keys).

### Task L4.4: CI for the production root
**Files:** `.github/workflows/plan.yml`, `.github/workflows/drift.yml`, `scripts/ci-plan.sh` (if needed), the bats tests, and `docs/ci-identity-runbook.md`.
- [x] **Separate explicit production jobs:**
  - each has its own "configured yet?" check and its own `TF_PROD_*` secrets, and authenticates through production's own planner;
  - drift has its own issue title per root;
  - no dynamic `secrets[...]` lookup, no `&&/||` fallback between roots, and no reusable workflow.
- [x] **The runbook:** the production planner's secrets (names only), and the first production drift run with the public-log identifier scan.
- [x] **Tests:** actionlint and zizmor clean; bats asserting that each job reads only its own root's secrets.

**Executed (2026-11-27, PR #10; review plus 1 fix round):** `plan-prod` and `drift-prod` with their own `TF_PROD_*` secrets (12 secrets, 2 variables) and production's own planner. A per-job path filter (`scripts/ci-changed.sh`). Every leaf of `TF_PROD_SERVICES` is masked before any tofu command and redacted longest first, including the regex-escaped forms. Summaries and drift issue bodies are redacted for both roots (also shipped to `main` as PR #9).

### Task L4.5: The owner's production runbook
**Files:** `docs/production-runbook.md`, and the operations-runbook index.
- [x] **Steps, in order:**
  1. create the project and link billing;
  2. the production bootstrap apply and state migration, with its proof;
  3. the `envs/prod` plan, apply and "No changes";
  4. the cluster add-ons: the namespaces bootstrap per service, External Secrets with a `secret-manager` SecretStore per namespace, and `cloudflared` with 2 or more replicas across zones and a PDB;
  5. verification, with the same checks as `apps`: private endpoint only, Secrets encryption, flow and audit logs, the Workload Identity probe per namespace;
  6. entering the production secret values;
  7. the template's environment-level variables.

  Expected output for every step, zsh-safe, no comments in code blocks, and no real values.

**Executed (2026-11-27, PR #10; review plus 2 fix rounds):** `docs/production-runbook.md`, steps 0 to 10 with Expect lines and a troubleshooting table. A bats test runs `zsh -n` and `bash -n` on every block and checks that nothing is echoed. It verifies the template's zone spread before applying `deploy/cloudflared/`. A final whole-phase review followed; its fix wave added `envs/prod` to Dependabot, plus a test that covers every root.

### Task L4.6: Remove production from `apps`
**Files:** `envs/apps/main.tf` (`local.environments`, the `app_environments` passed to `module.secrets`, `local.secret_keys`), its tests, and the runbook.
- [ ] **Code:** the plan destroys exactly the production-only `apps` resources: the production deployer and its IAM members, the production External Secrets grant, and the production secret containers. Tests list the exact remaining addresses.
- [ ] **Owner acceptance:**
  - the reviewed destroy list matches, resource by resource; anything else is a hard stop;
  - apply, then "No changes";
  - the `apps` production namespaces are deleted by hand, following the runbook.
  - **Precondition:** production is verified (L4.5) and its secret values are entered.

### Task L4.7: The `apps` budget
- [ ] Raise the `apps` budget from €20 to its real non-production cost, read from its first full months of bills. Owner acceptance: the plan shows only the budget amount changing.

### Task L4.8: Live-drift identities for the template's drift check (added 2026-11-27, owner "yes")
**Files:** `modules/gcp-github-wif` (`drift_environments`, `drift_account_ids`, the relaxed production guard, new outputs), `envs/apps`, `envs/prod`, tests, `docs/operations/github-identity.md` and `docs/production-runbook.md`.
- [x] **The module:** drift on a subset of environments, with drift account IDs as an input. Defaults keep both roots byte-identical. A production call may enable drift on exactly `[production]`; previews are still refused.
- [x] **`envs/apps`:** drift on dev and qa only. The expected owner plan is 8 to add (a provider, SA, WIU member and connect-role member per environment), 0 to change, 0 to destroy.
- [x] **`envs/prod`:** one `drift-production` reader per service (`gh-drift-<key>`). A deployer ID may not start with `gh-drift-`. A first plan creates 36 + 10S + K resources.
- [x] **Runbooks:**
  - a read-only pre-check for hand-made drift identities, with a `tofu import` path (never delete: a deleted provider ID stays reserved);
  - the `drift-<env>` environment variables;
  - production's in-cluster drift binding and its `can-i` check;
  - `DRIFT_ENABLED` only after the first deploy.
- [ ] **Owner acceptance (`apps`):** the pre-check finds nothing (or the imports are done); the plan shows the 8 adds; apply; then "No changes"; the `drift-dev` and `drift-qa` variables are set.

**Executed (2026-11-27):**
- Built in an isolated worktree.
- The opus review found 3 Important runbook gaps (the hand-made pre-check, production's RBAC name, the part-4 pointer); one fix round addressed all 9 items, and the re-review is clean.
- The docs-preservation test now checks old blocks are a subset of new.

## Carried from the setup-guide fixes (2026-11-25)

The guides were corrected before the owner's by-hand setup. Their settings are this plan's source, so these land in the modules:
- **L1.3, the maintenance window:** 00:00 to 08:00 UTC on Saturday and Sunday. GKE needs at least 48 hours of maintenance time in any 32 days, counted in blocks of 4 hours or more; the old 4-hour window is refused. Add a test that the window meets the rule.
- **L1.2, `gcp-github-wif`:** a second provider for pull request previews (`github-oidc-preview`, condition on `assertion.environment=='preview'` and `preview.yml` on a pull request merge ref or `main`), and a `preview` deployer. The deployers' cluster role is `roles/container.clusterViewer` if it still holds `container.clusters.connect`, otherwise a custom role with exactly `container.clusters.get` and `container.clusters.connect`.
- **L1.2, `gcp-network`:** an optional proxy-only subnet (`10.129.0.0/23`, `REGIONAL_MANAGED_PROXY`) for the previews' internal Gateway.
- **L2.1, the zone:** the encryption mode set explicitly (Custom, Full (strict)); new zones start in Automatic SSL/TLS.
- **L2.2, tunnel and Access:** the optional wildcard preview route (last in the route list), its wildcard Access application with an `owner` Allow policy and a `preview-smoke` Service Auth policy, and the service token.
- **A new platform add-ons task** (already noted): the in-cluster connector now also has a NetworkPolicy (no ingress; egress to kube-dns, 7844 TCP and UDP and 443 outside private ranges, and the `tier` app namespaces), and the Kyverno install.

## Carried from the template's secrets and drift work (2026-11-26)

The template now reads its app secrets through External Secrets from Google Secret Manager by default, and it has an optional read-only live-drift check. Its GKE guide (sections 12.6 and 14) is the source of these settings:
- **L1.2, `gcp-project` (or a new `gcp-secrets` module):** enable `secretmanager.googleapis.com`. For each app namespace `<service>-<env>` (dev, qa, production), grant `roles/secretmanager.secretAccessor` to `principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<service>-<env>/sa/external-secrets`, with the condition `resource.name.startsWith("projects/<number>/secrets/<service>-<env>-")` and the title `eso-<service>-<env>`. Each database namespace `<service>-<env>-db` (dev, qa) gets the same binding, limited to the exact name `<service>-<env>-db-password`. Use project-level conditional bindings (`google_project_iam_member` with `condition`), never an unconditioned one. Add tests: exactly five bindings, each with its condition, and none without one.
- **Secret values never go through OpenTofu.** A `google_secret_manager_secret_version` with `secret_data` puts the value in state. The module may create the empty secrets (`google_secret_manager_secret`, with replication set). The owner adds the versions by hand, as in guide 14.4. Add a test that no `google_secret_manager_secret_version` resource exists.
- **The platform add-ons task:** install External Secrets from the template's pinned chart, with the template's values file `deploy/external-secrets/external-secrets-values.yaml` (`processClusterStore: false`) and `--server-side=true --force-conflicts`. The per-namespace `ServiceAccount` named `external-secrets` and its `SecretStore` (`deploy/external-secrets/secretstore-secret-manager.yaml`) stay with the template, not here, because the app's namespaces belong to the template's bootstrap.
- **L1.2, `gcp-github-wif`, optional live drift:** one provider per environment, `github-oidc-drift-<env>`, with the attribute condition on the owner ID, the repository ID, `assertion.environment=='drift-<env>'` and `assertion.job_workflow_ref` equal to `<owner>/<repo>/.github/workflows/drift.yml@refs/heads/main`. Grant the provider's principal only the cluster-connect role the deployers use. The drift Role (get and list only, no secrets) comes from the template's bootstrap. Off by default: a variable, `enable_drift`, creates nothing when false.

## Carried from the owner's by-hand setup (2026-11-27)

The owner built the GKE side by hand from the template's guides (owner decision 2026-11-26, option A), and every guide check passed. That includes the first keyless `check` run from GitHub for dev and qa. Phase 1 now **imports** that setup. The modules must describe the live resources exactly, so that the owner's plan shows no change. The inventory (names and settings, no IDs) is in the template's SDD ledger, entry "IMPORT INVENTORY", 2026-11-27. These carry into the tasks:

- **L1.1, the state bootstrap:**
  - The bucket name is a variable (globally unique).
  - Add OpenTofu's native state encryption, with the `gcp_kms` key provider: a key ring and a key in the bootstrap, and rotation set. The bootstrap's own local state migrates into the bucket after the first apply.
  - This is the only new resource of phase 1. The owner applies it, on an explicit go.
- **L1.2, the modules,** with defaults set to the guide's values and every name a variable:
  - **`gcp-project`:** the APIs the owner enabled: compute, container, artifactregistry, iam, iamcredentials, sts, cloudresourcemanager, billingbudgets and secretmanager. `disable_on_destroy = false`.
  - **`gcp-network`:**
    - VPC `apps-vpc`;
    - subnet `apps-subnet`, with `pods`/`services` secondary ranges and Private Google Access;
    - router `apps-router`;
    - NAT `apps-nat`, with auto-allocated IPs, all subnets and ranges, and logging `ERRORS_ONLY`.
  - **`gcp-node-sa`:** `gke-nodes` with `roles/container.defaultNodeServiceAccount`, or the four classic roles where that role doesn't exist.
  - **`gcp-registry`:** optional and **off by default**. The template pushes to GHCR, and the owner created no registry.
  - **`gcp-github-wif`:**
    - The WIF subject prefix is an input (`sub_claim_prefix`, read by the owner from `GET repos/{repo}/actions/oidc/customization/sub`). The members are `<prefix>:environment:<env>`.
    - The deployers get **no** registry writer role (the guide grants none).
  - **`gcp-secrets`:**
    - the ESO bindings as already carried;
    - the secret containers with user-managed replication in the region;
    - the owner's seven secrets (dev/qa db-user, db-password and stats-pass, plus production stats-pass); production's db-user and db-password come with Cloud SQL;
    - never a secret version.
  - **`gcp-budget`** (optional): the project-scoped budget, with the billing account a variable kept in untracked tfvars.
- **L1.3, the cluster:**
  - Name `apps`; channel a variable (the owner chose `STABLE`); spot a variable (on); `enable_cost_allocation`; labels a variable (`cluster=apps`).
  - The node pool is `e2-standard-2`, `pd-balanced` 50 GB, autoscaling 1 to 3, starting at 2.
  - gcloud created the cluster with an inline `default-pool`. Model it so the import shows no change: manage the pool as its own `google_container_node_pool`, and have the cluster ignore its node-pool fields, or match whatever the provider needs. The no-change plan decides.
  - Ignore `node_count` drift from the autoscaler.
- **The edge is the Cloudflare tunnel.** The cluster needs no public Gateway or load balancer from this repository.
- **Shell:** the owner uses zsh. Runbook commands brace every variable that a `:` follows, and print values with `printf`, not `echo`.
- **Not in OpenTofu, now or later:**
  - secret values;
  - the template's namespace bootstrap, the External Secrets release and the SecretStores (Helm and kubectl, later GitOps);
  - the GitHub repository settings, which the template's `scripts/github-settings.sh` already holds as code.
