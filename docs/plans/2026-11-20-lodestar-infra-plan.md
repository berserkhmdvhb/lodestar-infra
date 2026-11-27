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
| 1 | State and Google Cloud | L1.1 to L1.5 | in progress (owner go 2026-11-27, terminal). It imports the owner's by-hand GKE setup; see "Carried from the owner's by-hand setup" below |
| 2 | Cloudflare | L2.1 to L2.3 | not started |
| 3 | Environments, CI and docs | L3.1 to L3.3 | not started |

### Task L0.1: Scaffold
**Files:** `README.md` (purpose, layout, the apply workflow, links to the guides), `LICENSE` (Apache-2.0), `.gitignore`, `.pre-commit-config.yaml` (tofu fmt and validate, tflint, checkov, gitleaks), `tools/pins.tsv` and `scripts/tools.sh` (checksum-verified install into `.tools/bin` of tofu, tflint and checkov through `uv tool`), and a `Makefile` (`tools fmt validate lint test check`).
- [x] **Verify:** `make tools check` passes on an empty tree.

**Executed (2026-11-20, commits d5bf9e4 and 5494166):**
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

**Executed (2026-11-27, commits 0092ab2, dd2b3ea and bb13540):**
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

**L1.2a, `dfb063f`.** Each value matches the owner's live resources, and the optionals the owner never set stay unset:
- **`gcp-project`:** the nine APIs, `disable_on_destroy = false`.
- **`gcp-network`:**
  - `apps-vpc`;
  - `apps-subnet` with Private Google Access and `pods`/`services` in live order;
  - `apps-router`;
  - `apps-nat` (AUTO_ONLY, all subnets and ranges, logging `ERRORS_ONLY`);
  - an optional proxy-only subnet, off by default.
- **`gcp-node-sa`:** `gke-nodes` with `roles/container.defaultNodeServiceAccount`, or the four classic roles.
- **`gcp-registry`:** off by default, since the template uses GHCR.

**L1.2b, `581bc5a` (`gcp-github-wif`):**
- the pool and the `github-oidc` provider;
- the exact stored condition (owner ID, repo ID, `deploy|deploy-ops` on `main` or `v*`, with doubled backslashes);
- `gh-deployer-<env>`, bound to `<sub_claim_prefix>:environment:<env>`, so it works with immutable subjects;
- `roles/container.clusterViewer`, or a custom connect-only role;
- no registry writer;
- optional previews and drift per guide §12.5 and §12.6.

**L1.2c, `8bb7f0e`:**
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

**Executed (2026-11-27, commit db877a8):** `modules/gcp-gke`, import-shaped against the owner's live cluster. The values were written from the owner's private, read-only exports, and no identifying value is in Git.
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
- [ ] **Tests and checkov:** checkov is clean, with documented skips only.

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
2. **First import plan: failed.** The provider bills requests to the project, and the Service Usage API was off there, so the 9 API reads failed (403). The fix (commit 29eeb75, reviewed) has the bootstrap enable `serviceusage.googleapis.com`: 1 added.
3. **Import plan: `41 to import, 0 to add, 1 to change, 0 to destroy`.** The only change was the cluster's state-only `cluster = "apps"` labels. The APIs showed no change.
4. **After the import apply,** `tofu plan` reports **No changes. Your infrastructure matches the configuration.**

**Executed (2026-11-27, commits 633cd07 and 308b4f8, plus the phase-1 fix wave):**
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
**Files:** `.github/workflows/ci.yml`, with no credentials. It runs fmt-check, validate (with `-backend=false`), tflint, checkov, `tofu test`, gitleaks and actionlint, plus zizmor on itself. Every action is SHA-pinned; there are timeouts, `concurrency`, and read-only permissions.

### Task L3.3: Docs
**Files:** `docs/apply-runbook.md` and `docs/mapping.md`.
- **The apply runbook:** bootstrap; set `TF_VAR_*` or local tfvars; `tofu plan` reviewed; apply; then run the guides' checks.
- **The mapping:** each guide step mapped to its resource.

Also cover drift detection, which runs as `tofu plan` on a schedule once credentials exist; that's for later.

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
