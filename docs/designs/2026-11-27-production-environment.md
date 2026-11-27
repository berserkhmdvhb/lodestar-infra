# Design: a separate production environment (2026-11-27)

Status: **approved (2026-11-27).** The builder check is done, and the owner answered Q1–Q3. This becomes lodestar-infra
phase P, planned task by task in `docs/plans/2026-11-20-lodestar-infra-plan.md`.

## Intent

Today one zonal cluster, `apps`, hosts dev, qa and production as namespaces, on spot nodes, in one zone. So a broken
experiment, a GKE upgrade, a spot preemption or a zone outage can take production down along with everything else.
Production must stop sharing a failure domain, an upgrade moment, a node pool and a blast radius with development work.

## Goals

- **Its own project and cluster.** Production lives in its own GCP project, on its own regional GKE Standard cluster.
- **Built with OpenTofu from the same modules as `apps`.** Creating the project itself is the only hand-made step.
- **Parity with qa.** The same cluster type and hardening, so what passes in qa behaves the same in production.
- **Survives the loss of a node or a zone**, for workloads that run at least two replicas spread across zones.
- **Upgrades after `apps`.** Production's maintenance window trails the non-production cluster's.
- **Its own edge and its own CI identity.** Production's tunnel runs inside its cluster. Credentials from the
  non-production project can neither reach production traffic nor read production state.
- **`apps` becomes non-production only** (dev, qa, previews). It stays cheap, on spot nodes.

## Non-goals and anti-goals

**Non-goals:**
- Cloud SQL for production: its own design, before the first production deploy.
- Multi-region.
- GitOps (Argo CD or Flux).
- Changing the non-production cluster beyond removing production from it.

**Anti-goals:** any change that alters a live `apps` resource. The `apps` plan must stay "No changes" through every module
change, except for the one reviewed migration step at the end.

## Decisions already made by the owner

| Decision | Choice |
|---|---|
| Production isolation | a separate GCP project and cluster ("it worths the cost") |
| Cluster shape | regional GKE Standard |
| Order | Cloudflare first (the lab domain and the non-production tunnel on `apps`), then production, before the first production deploy |
| Real domains | never in the public template (`EDGE_DOMAIN`) |
| Domains | one production domain per independent project; one shared non-production lab domain |

## Questions answered by the owner (2026-11-27)

- **Q1: all three projects.** The production cluster hosts the production of the template's app, the training platform
  and the personal site. The deploy identity admits a list of repositories, with one deployer per repository, and
  secrets are keyed per service.
- **Q2: the cap is agreed.** The production pool is capped at 4 nodes in total (`total_max_node_count = 4`).
- **Q3: the same billing account as `apps`, in EUR.**

The questions as asked:

- **Q1. Tenants: what runs in the production cluster?** The production cluster could serve the production of all three
  projects (the template's app, the training platform and the personal site), or only the template's. Several tenants
  change the build now, because today's modules assume one repository and one service:
  - one repository per Workload Identity pool;
  - deployers named `gh-deployer-<env>`;
  - a single service name per secrets module.

  **Recommendation: all three.** That is the point of one platform. The deploy identity would then admit a list of
  repositories, with one deployer per repository, and secrets would be keyed per service.
- **Q2. The node ceiling.** Node pool limits are per zone, so "1–3 per zone in 2 zones" allows up to 6 on-demand nodes:
  about $390 a month including the fee. A budget only alerts; it never caps spend.
  **Recommendation: cap the pool at 4 nodes in total** (`total_max_node_count`), about $280 in the worst case. Steady
  state is 2 nodes.
- **Q3. The billing account.** Is it the same billing account as `apps`, in EUR? The budget's currency and the planner's
  billing role assume so.

## Architecture

```text
GCP project <apps>  (non-production)                 GCP project <prod>  (production)
├── VPC (apps ranges)                                ├── VPC prod-vpc: 10.40.0.0/20, pods 10.50.0.0/16, services 10.60.0.0/20
├── zonal cluster apps (europe-west1-b, spot)        ├── REGIONAL cluster prod (europe-west1; nodes in -b and -c, on demand)
│     dev · qa · previews                            │     production only
├── tunnel "apps" → the lab domain                   ├── tunnel "prod" → the production domains
├── WIF pool github: deployers dev, qa               ├── WIF pool github: production deployer(s)
├── WIF pool github-infra: tofu-planner (apps)       ├── WIF pool github-infra: tofu-planner (prod)
└── state bucket + KMS key (bootstrap)               └── state bucket + KMS key (bootstrap for prod)
```

Production's ranges don't overlap the `apps` VPC (checked against its live values), so the two VPCs could be peered
later. Today they don't talk.

### Project

The owner creates the project and links billing by hand: two commands, in the runbook. This mirrors `apps` and keeps
billing-account administration out of the code. Everything inside the project is OpenTofu: APIs, network, IAM, cluster,
keys and budget.

### Cluster (`modules/gcp-gke`, extended with byte-identical defaults)

**What already exists:** `location` is a variable used by both the cluster and the pool, so a regional location needs no
new input; only its description changes from "zone". `spot` is also already a variable, with a test.

**New inputs** (each default keeps `apps` exactly as it renders today):

| Input | Default (apps) | Production |
|---|---|---|
| `node_locations` | `null` | `["europe-west1-b", "europe-west1-c"]` |
| `location_policy` | `"ANY"` | `"BALANCED"` (spreads on-demand nodes across zones; ANY suits spot) |
| `total_max_node_count` | `null` (the per-zone limits apply) | per Q2 |
| `oauth_scopes` | the current two scopes | the same two scopes |
| maintenance window | today's weekend window | **Tuesday and Wednesday**, so `apps` upgrades first |

**Production settings:**
- `spot = false`, `cluster_name = "prod"`, label `cluster=prod`.
- `enable_public_endpoint = false`: production uses only the DNS-based control-plane endpoint, which the template's
  deploy action already uses. A newly created cluster would otherwise get an internet-reachable IP endpoint, because
  authorized networks aren't managed in the module.
- `deletion_protection` on.
- The pool's `initial_node_count` becomes `var.min_node_count`. It is in `ignore_changes`, so `apps` sees no diff.
  The module has so far only been used to import, never to create, so this was never needed before.

**Everything else matches `apps`:**
- the Stable channel, private nodes, Dataplane V2, Workload Identity, Gateway API standard, shielded nodes;
- application-layer Secrets encryption with production's own KMS key;
- insecure RBAC bindings off;
- flow logs and container audit logs.

**What surviving a zone loss requires:**
- Every production workload runs **2 or more replicas, spread across zones**, with a PodDisruptionBudget. That includes
  `cloudflared`.
- Persistent disks are zonal, so stateful data lives outside the cluster: Cloud SQL, high-availability per its own
  design.

### Creation order in a fresh project

`envs/apps` needs no `depends_on`, because everything in it was imported. `envs/prod` creates from scratch, so the order
must be explicit:
- every module depends on `module.project`, so the APIs are enabled first;
- the secrets key's grant to the GKE service agent depends on the container API, which creates that agent;
- the External Secrets grants depend on `module.gke`, because the cluster's Workload Identity pool
  (`<project>.svc.id.goog`) only exists once the first Workload Identity cluster does. IAM rejects bindings before then.

### Network

`modules/gcp-network` already takes its ranges as inputs. Production gets `prod-vpc`, `prod-subnet`, `prod-router` and
`prod-nat`, with the ranges above. Cloud NAT is outbound only, used by the tunnel and image pulls. There is no load
balancer and no public IP: the tunnel connects outbound.

### Identity and access

**Production deploys.**
- A Workload Identity pool and provider in the production project, with the same attribute condition as `apps` plus a
  new optional term that admits only the `production` environment subject. The default is null, so `apps` is
  unchanged.
- One deployer per repository (per Q1), each bound to its immutable `…:environment:production` subject.
- The GitHub `production` environment further restricts refs, to `v*` tags with reviewer approval, and carries
  environment-level `GCP_PROJECT_ID`, `GKE_CLUSTER`, `GKE_LOCATION` and the WIF variables. The template's deploy jobs
  already read these inside `environment:` jobs, so no workflow changes. The template's settings script learns to set
  them (template task 11.3).
- Why a pool per project and not the `apps` pool: through the `apps` pool, any `apps` IAM admin could add a provider
  that mints the production subject, and deleting that pool would break production deploys.

**CI planning (my call): production gets its own read-only planner.** `modules/gcp-ci-planner` is called unchanged in
`envs/prod`, which creates its own pool, provider, `tofu-planner` service account and read-only grants, including the
Cloud Billing API. The alternative was granting the `apps` planner access to production state, so anyone who could
impersonate it from `apps` could read production state. The cost is two more repository secrets.

**CI workflows:**
- `plan.yml` and `drift.yml` get a **separate explicit job per root**, each with its own "configured yet?" check, its own
  `TF_PROD_*` secrets and its own drift issue title.
- Not a matrix with a dynamic `secrets[...]` lookup: zizmor flags it as over-provisioning.
- Not a `cond && secrets.PROD || secrets.APPS` expression: an empty production secret would silently fall back to the
  `apps` value.
- Not a reusable workflow: the planner's trust is pinned to `plan.yml` and `drift.yml` by `job_workflow_ref`.

### State

Production state lives **in the production project**, with its own bucket and its own KMS key.

To avoid duplicating code, the state resources of `bootstrap/` move into a new `modules/gcp-state-backend`:
- **Inputs:** `state_admins` (objectAdmin) and a new `state_readers` (objectViewer plus EncrypterDecrypter: `gcp_kms`
  encrypts on every run, so decrypt-only is not enough).
- **Keeping the live addresses:** `bootstrap/` calls the module, with `moved` blocks. State encryption doesn't affect
  `moved` blocks.
- **Proving it:** CI never plans `bootstrap/`, whose backend is the local, git-ignored `override.tf`. So the proof is the
  owner's local plan: moves only, 0 to add, 0 to change, 0 to destroy. The moves persist only after the owner applies.
- **Tests:** `bootstrap/`'s tests move with the resources they check.

A second bootstrap root for production calls the same module and migrates its own state into its bucket, with the same
proof steps as `bootstrap/`. It goes where the Makefile discovers roots (or the discovery is widened), so validate,
tflint, checkov and the tests cover it. It is added to `dependabot.yml`, and its lock file carries the linux_amd64 and
darwin_arm64 hashes.

### Secrets

- **Production secrets:** `modules/gcp-secrets` with `app_environments = ["production"]`, `db_environments = []` and
  production's own `secret_keys`.
- **Production tunnel token:** `modules/gcp-platform-secret`, added for the non-production tunnel in task L2.0.
- **Values:** never in code. The owner enters them in the production project; nothing copies them from `apps`.

### Edge

A second tunnel, `prod`, has its connector in the production cluster's `cloudflared` namespace, with at least 2 replicas
across zones and a PodDisruptionBudget. It serves only the production domains, so a non-production failure or token
leak can't touch production traffic.

Which OpenTofu root owns the Cloudflare side (zones, both tunnels, Access, DNS) is decided in the Cloudflare phase's own
design. That decision includes whether CI plans it, which needs a read-only Cloudflare token.

### Budget and alerts

- **Production project:** its own budget, at **€250 a month**, with alerts at 50 %, 90 %, 100 % and 150 %.
- **`apps`:** its budget (€20 today) is raised to match its real spot cost, read from its first full months of bills.

## Cost (approximate list prices, europe-west1, before Cloud SQL)

| Item | ≈ per month | Source |
|---|---|---|
| GKE management fee, one regional cluster | $73 | confirmed: $0.10 per cluster-hour. The free credit covers only zonal and Autopilot clusters, so a regional cluster always pays it |
| 2 × e2-standard-2 on demand (steady state) | ~$105 | approximate; confirm in the Pricing Calculator |
| 2 × 50 GB pd-balanced boot disks | ~$11 | approximate |
| Cloud NAT (2 nodes, low traffic) plus its IP | ~$6 | approximate: per node-hour plus processed data |
| Traffic between zones b and c | ~$1–5 | $0.01/GB, depends on traffic |
| KMS (state and secrets keys) | <$1 | confirmed: $0.06 per key version, $0.03 per 10,000 operations |
| Egress through the tunnel; logging within the free allotment | a few $ | depends on traffic |
| **Steady state** | **≈ $200, about €185** | |
| **Worst case at the node ceiling** | **≈ $280 with a 4-node cap; ≈ $390 with 6** | see Q2 |

Cloud SQL for PostgreSQL comes on top: roughly $50 for the smallest dedicated-core zonal instance, about double for
high availability. **Before applying, confirm the node and disk prices in the Google Cloud Pricing Calculator**
(europe-west1, no discounts).

## Migration of production out of `apps`

Nothing is deployed to production yet, so there is no traffic to move.

1. Build production (phase P) and verify it, with the same runbook checks as `apps`.
2. Enter production's secret values in the production project.
3. Point the template's `production` environment at the new project; the first `v*` tag deploys there.
4. Remove production from `apps` in code:
   - drop `production` from `local.environments`, which feeds the deploy identity;
   - pass `app_environments` without production to `module.secrets`;
   - remove production's key from `local.secret_keys`.

   The plan then destroys exactly the production-only `apps` resources: the production deployer and its IAM members,
   the production External Secrets grant, and the production secret containers (their values go with them, hence
   step 2). The list is reviewed resource by resource. This is the one allowed destroy in phase P; anything else is a
   hard stop.
5. Delete the `apps` cluster's production namespaces and their bootstrap, by hand, following the runbook.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| A module change alters `apps` | defaults keep `apps` byte-identical; the PR's plan job and the drift run must show "No changes" for `apps` before merge |
| The bootstrap refactor moves live state resources | `moved` blocks only; the owner's local plan must show 0 / 0 / 0; hard stop otherwise |
| Production state migration loses state | the same migration as `bootstrap/`: an encrypted-copy proof before any local file is deleted |
| Cost overrun | the node cap (Q2) and the €250 budget alert |
| A deploy to the wrong project | environment-level variables, plus a production provider that admits only the `production` environment subject |
| A new cluster exposed on a public IP | `enable_public_endpoint = false` for production, with a test |
| Both clusters upgrade together | production's maintenance window trails `apps` |

## Calls made in this design (for the owner to check)

- Production gets its own read-only CI planner, not grants for the `apps` planner.
- A Workload Identity pool per project.
- Production's maintenance window is Tuesday and Wednesday.
- The network ranges and names above.
- The default OAuth scopes are kept.
- Each root gets its own explicit CI jobs.
- `state_readers` is a new input on the state module.
- Which root owns the Cloudflare side is deferred to the Cloudflare design.
- **The deferred `apps` pool swap is dropped.** `apps` is now non-production, so it stays on spot nodes. Narrowing its
  OAuth scopes would replace its node pool, so it becomes a separate, deliberate change later.

## Phase P tasks (outline, planned in detail after approval)

1. **P.1 `gcp-gke` inputs:** `node_locations`, `location_policy`, `total_max_node_count`, `oauth_scopes`, the maintenance
   window and `initial_node_count`, all with byte-identical defaults. Also `gcp-github-wif`'s optional environment term,
   and per Q1, multi-repository deployers and per-service secrets. Each change is proven by tests, and by the `apps`
   PR plan showing "No changes".
2. **P.2 The state module:** `modules/gcp-state-backend`, `bootstrap/` refactored with `moved` blocks, and the
   production bootstrap root. The owner applies and migrates.
3. **P.3 `envs/prod`:** APIs, network, node service account, cluster, secrets key, deploy identity, production secrets,
   the tunnel token container, the CI planner and the budget. Explicit `depends_on` throughout.
4. **P.4 CI:** separate production jobs in `plan.yml` and `drift.yml`, and the `TF_PROD_*` secrets runbook.
5. **P.5 The owner's production runbook:** project creation, the production bootstrap, the `envs/prod` apply, cluster
   add-ons (namespaces bootstrap, External Secrets, `cloudflared`), and verification.
6. **P.6 Migration:** remove production from `apps`, with the reviewed destroy list.
7. **P.7** The `apps` budget adjusted to its real cost.
