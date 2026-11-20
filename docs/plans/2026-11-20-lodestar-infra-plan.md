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

- **Nothing is applied.** No cloud credentials are used. No step calls a cloud API, except provider downloads from the OpenTofu registry.
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
  - WIF conditions on `repository_owner_id` **and** `repository_id`, and one deployer per environment, bound to `repo:<owner>/<repo>:environment:<env>`;
  - Cloudflare Full (strict), TLS 1.2 minimum, DNSSEC, and CAA/SPF/DMARC.
- **This is a public repository:** no secrets, no real domains or IDs in examples, and every action pinned by SHA.
- **TDD:** every module has a `tofu test` file with mock providers, asserting its security settings.

## Progress

| Phase | Theme | Tasks | Status |
|---|---|---|---|
| 0 | Scaffold | L0.1 | not started |
| 1 | State and Google Cloud | L1.1 to L1.4 | not started |
| 2 | Cloudflare | L2.1 to L2.3 | not started |
| 3 | Environments, CI and docs | L3.1 to L3.3 | not started |

### Task L0.1: Scaffold
**Files:** `README.md` (purpose, layout, the apply workflow, links to the guides), `LICENSE` (Apache-2.0), `.gitignore`, `.pre-commit-config.yaml` (tofu fmt and validate, tflint, checkov, gitleaks), `tools/pins.tsv` and `scripts/tools.sh` (checksum-verified install into `.tools/bin` of tofu, tflint and checkov through `uv tool`), and a `Makefile` (`tools fmt validate lint test check`).
- [ ] **Verify:** `make tools check` passes on an empty tree.

### Task L1.1: The state bootstrap
**Files:** `bootstrap/` (a GCS bucket with versioning, uniform bucket-level access, public access prevention, an optional CMEK key, and a retention lock on noncurrent versions), plus `bootstrap/README.md` (a one-time apply with local state, then migrate).
- [ ] **Tests:** the bucket is versioned, has uniform access and prevents public access.

### Task L1.2: Google Cloud network and identity modules
**Files:**
- `modules/gcp-network` (VPC, subnet with secondary ranges, Private Google Access, router plus NAT with error logging);
- `modules/gcp-node-sa` (the minimal node roles);
- `modules/gcp-registry` (Artifact Registry with immutable tags, cleanup policies and the reader binding);
- `modules/gcp-github-wif` (the pool, the provider with the owner-ID and repository-ID condition, per-environment deployer service accounts with subject bindings, the registry writer role and the cluster viewer role).
- [ ] **Tests:** the attribute condition includes both IDs; there's one service account per environment; no `roles/editor` or `roles/owner` is granted anywhere.

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
- [ ] **Tests:** every setting in the list above; the node service account isn't the default compute account.

### Task L1.4: The GKE security baseline extras
**Files:** VPC flow logs on the subnet, Data Access audit logging for the container API, and the `gke-security-posture` settings where the provider supports them.
- [ ] **Tests and checkov:** checkov is clean, with documented skips only.

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
