# Production runbook: the production project and its regional cluster

You run every command here yourself, by hand, in zsh, with your own `gcloud` login, and paste the output back
when something differs. Nothing in this repository applies anything on its own. It builds the production
project from [`envs/prod`](../envs/prod) and [`bootstrap/prod`](../bootstrap/prod): its own project, state bucket,
KMS keys, regional GKE cluster `prod`, deploy identities, secret containers and budget. The design is in
`docs/designs/2026-11-27-production-environment.md`. The commands of each stage are adapted from what was run for `apps`: the
[operations runbook](operations-runbook.md) (stages named "ops 5.3" and so on), the
[import runbook](import-runbook.md), the [hardening runbook](hardening-runbook.md) and the
[CI identity runbook](ci-identity-runbook.md).

This page is public. It holds no real project ID, number, account, e-mail, ID or secret: every value is a
variable from `~/prod-setup.env` or a placeholder.

## Contents

0. [Prerequisites](#0-prerequisites)
1. [Create the project and link billing](#1-create-the-project-and-link-billing)
2. [The production bootstrap: state bucket and key](#2-the-production-bootstrap-state-bucket-and-key)
3. [`envs/prod`: plan, apply, "No changes"](#3-envsprod-plan-apply-no-changes)
4. [The CI planner secrets and the first drift run](#4-the-ci-planner-secrets-and-the-first-drift-run)
5. [Cluster access](#5-cluster-access)
6. [Add-ons](#6-add-ons)
7. [Verification](#7-verification)
8. [Production secret values](#8-production-secret-values)
9. [The template's `production` environment variables](#9-the-templates-production-environment-variables)
10. [Rollback and teardown notes](#10-rollback-and-teardown-notes)
11. [Troubleshooting](#11-troubleshooting)

## How to read this runbook

Marks, as in [the operations runbook](operations-runbook.md#legend): 🔍 read-only, ✏️ changes something,
🔐 handles a secret (read with `read -rs`, never echoed, never on a command line). Every command block is followed
by an `Expect` line. If the output differs, stop, and do what the "If it differs" line says; where there is none,
paste the output and do not go on.

- **Run from** the root of this repository, unless a step says "template root". Commands that start with
  `tofu -chdir=` or `make` always run here.
- **One terminal for production,** from step 1 on. Do not `source ~/gke-setup.env` in it: that file sets
  `PROJECT_ID`, `KUBECONFIG` and `GH_REPO` of `apps`, and a production command would then act on `apps`. The
  production variables are all named `PROD_*` for that reason. Every `gcloud` command here names the project.
- **zsh:** brace every variable (`${PROD_PROJECT_ID}`, never `$PROD_PROJECT_ID:...`: zsh reads `$VAR:e` and
  similar as a modifier), use `printf`, not `echo`, and paste only code blocks, never prose. The blocks contain
  no comments for that reason.
- **Saved plans** are applied by file and then deleted; a second apply of the same file fails, so plan again.
- **Never commit** `~/prod-setup.env`, anything in `~/platform-config`, `*.tfvars`, `override.tf` or `*.tfplan`.

## 0. Prerequisites

### 0.1 The `apps` bootstrap refactor is applied first

Why: the state bucket and key of `apps` moved into `modules/gcp-state-backend`, with `moved` blocks. The moves
reach the live state only after you apply them. Use the terminal and the variables of `apps` for this one stage
(`bootstrap/override.tf` from the import runbook must still be there; it is the only record of the backend).

🔍 ✏️ (the first command installs the module; the plan changes nothing)

```bash
export PATH="${PWD}/.tools/bin:${PATH}"
tofu -chdir=bootstrap init
tofu -chdir=bootstrap plan
```

Expect: exactly 3 moves (the key ring, the key and the bucket, each `has moved to module.state...`) and
`Plan: 0 to add, 0 to change, 0 to destroy.` If it differs (an add, a change or a destroy): stop and paste the
plan. Do not apply.

✏️ (state only; nothing changes in Google Cloud)

```bash
tofu -chdir=bootstrap apply
tofu -chdir=bootstrap plan
```

Expect: the apply records the 3 moves (`Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`), then
`No changes. Your infrastructure matches the configuration.` The same steps are in
[`bootstrap/README.md`](../bootstrap/README.md#after-the-module-refactor).

### 0.2 Tools and logins (the production terminal)

Open a new terminal. It never sources `~/gke-setup.env`.

🔍

```bash
export PATH="${PWD}/.tools/bin:${PATH}"
export LODESTAR_ROOT="${PWD}"
unset GH_REPO
tofu version
gcloud auth list --filter=status:ACTIVE --format='value(account)'
gh auth status
```

Expect: `OpenTofu v1.13.9` (`LODESTAR_ROOT` remembers this repository's root for the steps that run in the template; if the command is not found, run `make tools` from this root first), your Google
account, and a logged-in GitHub account. `unset GH_REPO` matters: `gh` honours that variable over the current
directory, and the one from the `apps` env file names the template repository.

✏️ (opens a browser; Application Default Credentials are a second, separate login)

```bash
gcloud auth application-default login
```

Expect: a browser login, then `Credentials saved to file`. The quota project is set in step 3, once the production
project exists.

### 0.3 The production env file

✏️ (writes a file with placeholders; then edit the two placeholders by hand)

```bash
cat > ~/prod-setup.env <<'EOF'
export PROD_PROJECT_ID="your-production-project-id"
export PROD_REGION="europe-west1"
export PROD_CLUSTER="prod"
export PROD_KUBECONFIG="${HOME}/.kube/gke-prod.yaml"
export LODESTAR_REPO="your-github-user/lodestar-infra"
EOF
chmod 600 ~/prod-setup.env
```

Expect: no output. Open `~/prod-setup.env` and replace `your-production-project-id` (a new, globally unique project
ID, 6 to 30 characters, lowercase letters, digits and hyphens) and `your-github-user`. Then load it:

🔍

```bash
source ~/prod-setup.env
printf 'project=%s region=%s cluster=%s repo=%s\n' "${PROD_PROJECT_ID}" "${PROD_REGION}" "${PROD_CLUSTER}" "${LODESTAR_REPO}"
```

Expect: your values. An empty one means the file was not sourced or has a typo. Use `export` for every line you
add later, or scripts and child processes do not see the variable.

### 0.4 The private tfvars files and the private folder

The two tfvars files are git-ignored. `envs/prod/terraform.tfvars` is copied once here and filled in by hand in
step 3. `bootstrap/prod/terraform.tfvars` is written at the end of step 1, once the project ID is known to be free
(always with `cat >`, never `>>`: appending twice gives `Attribute redefined`).

✏️

```bash
mkdir -p ~/platform-config
chmod 700 ~/platform-config
[ -e envs/prod/terraform.tfvars ] || cp envs/prod/terraform.tfvars.example envs/prod/terraform.tfvars
git status --porcelain bootstrap/prod envs/prod
```

Expect: no output from `git status` (the file is ignored). The state bucket name must be globally unique;
a clash shows up as an error in step 2, and you then edit the name in the file. If `git status` lists a tfvars
file: stop, it is not ignored.

## 1. Create the project and link billing

Why: the project is the only hand-made resource; everything inside it is OpenTofu. Billing is linked by hand so
that billing-account administration stays out of the code. Use the same billing account as `apps` (EUR).

🔍 Read the billing account of `apps`. The subshell loads the `apps` env file without touching this terminal.

```bash
BILLING_ACCOUNT="$(source ~/gke-setup.env && gcloud billing projects describe "${PROJECT_ID}" --format='value(billingAccountName)' | cut -d/ -f2)"
printf '%s\n' "${BILLING_ACCOUNT}"
```

Expect: one account ID of the form `XXXXXX-XXXXXX-XXXXXX`. If it prints nothing, list the accounts with
`gcloud billing accounts list` and set `BILLING_ACCOUNT` to the right one by hand.

✏️

```bash
printf 'export BILLING_ACCOUNT="%s"\n' "${BILLING_ACCOUNT}" >> ~/prod-setup.env
gcloud projects create "${PROD_PROJECT_ID}"
gcloud billing projects link "${PROD_PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"
```

Expect: `Create in progress for [https://cloudresourcemanager.googleapis.com/v1/projects/<project>]` and the operation
finishing, then the link's output with `billingEnabled: true` and your project. If the create says the ID
is taken, choose another in `~/prod-setup.env`, source it again and repeat. If your account belongs to an organisation
that requires a parent, add `--organization=<organization-id>` or `--folder=<folder-id>` to the create command.

🔍 Verify, and keep the project number (the tfvars and the IAM names use the number, not the ID).

```bash
gcloud billing projects describe "${PROD_PROJECT_ID}" --format='value(billingEnabled)'
PROD_PROJECT_NUMBER="$(gcloud projects describe "${PROD_PROJECT_ID}" --format='value(projectNumber)')"
printf 'export PROD_PROJECT_NUMBER="%s"\n' "${PROD_PROJECT_NUMBER}" >> ~/prod-setup.env
printf '%s\n' "${PROD_PROJECT_NUMBER}"
```

Expect: `True`, then a 10 to 12 digit number. Nothing that costs money works before billing is on.

✏️ Now that the ID is yours, write the bootstrap's tfvars (whole file, safe to repeat).

```bash
cat > bootstrap/prod/terraform.tfvars <<EOF
project_id        = "${PROD_PROJECT_ID}"
state_bucket_name = "${PROD_PROJECT_ID}-tofu-state"
EOF
git status --porcelain bootstrap/prod
```

Expect: no output (the file is git-ignored). If you later change the project ID, run this block again.

## 2. The production bootstrap: state bucket and key

Why: production state lives in its own bucket, encrypted with its own key, in the production project, so it never
depends on `apps`. The full procedure, with the exact `override.tf` files, is in
[`bootstrap/prod/README.md`](../bootstrap/prod/README.md); this step is its summary with the checks. Order:
(1) apply with a local state, (2) migrate the state into the bucket in a form that still reads plain state,
(3) prove the object is encrypted, (4) switch to the enforced form and plan, (5) only then delete the local state.

### 2.1 The first apply (local state)

✏️ Enables 4 APIs and creates the key ring, the key and the bucket.

```bash
tofu -chdir=bootstrap/prod init
tofu -chdir=bootstrap/prod plan -out=bootstrap-prod.tfplan
```

Expect: `Plan: 7 to add, 0 to change, 0 to destroy.` The 7 are the 4 APIs (Cloud KMS, Cloud Storage, Service Usage,
Cloud Resource Manager), the key ring, the key and the bucket; this is computed from `bootstrap/prod/main.tf` and the
module, not read from a run. A different number: stop and paste the plan.

✏️

```bash
tofu -chdir=bootstrap/prod apply bootstrap-prod.tfplan
rm -f bootstrap/prod/bootstrap-prod.tfplan
```

Expect: `Apply complete! Resources: 7 added, 0 changed, 0 destroyed.` If it fails with `SERVICE_DISABLED` right after an
API was enabled: wait 2 to 3 minutes, then plan again into a new file (the old file is stale: delete it) and apply
that. The state is a plain local `terraform.tfstate` until step 2.2.

### 2.2 Migrate the state into the bucket, encrypted

🔍 The two values the `override.tf` files need. Keep this terminal: the variables are used below.

```bash
BUCKET="$(tofu -chdir=bootstrap/prod output -raw state_bucket)"
KEY="$(tofu -chdir=bootstrap/prod output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"
```

Expect: both lines carry a value (the key is `projects/<project>/locations/europe-west1/keyRings/tofu-state/cryptoKeys/tofu-state`).

✏️ Now run the first `cat > bootstrap/prod/override.tf` block (the one with the fallback) and its `init -migrate-state` of
[`bootstrap/prod/README.md`, section 3](../bootstrap/prod/README.md#3-migrate-the-state-into-the-bucket-encrypted),
in this terminal (they read `${BUCKET}` and `${KEY}`). The first `override.tf` has the fallback to plain state; answer
`yes` to copying the state. Then the proof, before anything is deleted:

🔍

```bash
gcloud storage cat "gs://${BUCKET}/bootstrap-prod/default.tfstate" --project "${PROD_PROJECT_ID}" | grep -c encrypted_data
gcloud storage cat "gs://${BUCKET}/bootstrap-prod/default.tfstate" --project "${PROD_PROJECT_ID}" | grep -c '"resources"'
```

Expect: `1` or more, then `0`. If the second is not `0` the object is plain JSON: keep the fallback, run
`tofu -chdir=bootstrap/prod apply` (it must say `No changes` and saves the state again with the new method), and check
again.

✏️ Then the second `override.tf` of the README (no fallback, encryption enforced) and the plan:

```bash
tofu -chdir=bootstrap/prod plan
```

Expect: `No changes. Your infrastructure matches the configuration.` Without the fallback OpenTofu refuses plain state,
so this is a second proof. If it differs: do not delete anything; put the first `override.tf` back and paste the output.

✏️ Only now delete the local copies, and back up the only record of the backend.

```bash
rm -f bootstrap/prod/terraform.tfstate bootstrap/prod/terraform.tfstate.backup
cp bootstrap/prod/override.tf ~/platform-config/bootstrap-prod-override.tf
chmod 600 ~/platform-config/bootstrap-prod-override.tf
```

Expect: no output. `bootstrap/prod/override.tf` is git-ignored: it, or its backup, is the only record of the backend.

🔍 Verify the bucket.

```bash
gcloud storage buckets describe "gs://${BUCKET}" --project "${PROD_PROJECT_ID}" \
  --format='yaml(versioning,uniform_bucket_level_access,public_access_prevention,retention_policy)'
```

Expect: `versioning.enabled: true`, uniform access enabled, `public_access_prevention: enforced`, and no
`retention_policy`.

## 3. `envs/prod`: plan, apply, "No changes"

Why: this creates everything else in the production project, from scratch (nothing is imported), in an explicit
order: the APIs first, the secrets key before the cluster, and the secret grants after the cluster.

### 3.1 The tfvars

✏️ Point Application Default Credentials at the production project (they bill the provider's requests to it).

```bash
gcloud auth application-default set-quota-project "${PROD_PROJECT_ID}"
```

Expect: `Quota project "<project>" was added to ADC`. This changes your credentials file for every project: for the
`apps` terminal, set it back with the `apps` project (ops 2.5), though the providers of both roots also set
`billing_project` themselves.

🔍 For each service repository, and once for this repository, read the numeric IDs and the immutable subject prefix
(an owner or repository name can be renamed; its ID cannot). Set `REPO`, run the block, copy the three values into the
tfvars; repeat per repository.

```bash
REPO="example-owner/example-repo"
printf 'owner_id=%s\nrepo_id=%s\nsub_claim_prefix=%s\n' "$(gh api "users/${REPO%%/*}" --jq .id)" "$(gh api "repos/${REPO}" --jq .id)" "$(gh api "repos/${REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
```

Expect: two numbers, then `repo:<owner>@<owner-id>/<repo>@<repo-id>`. An empty prefix: build the immutable form
from the IDs, and know the risk, as in [CI identity runbook section 1](ci-identity-runbook.md#1-this-repositorys-ids-and-subject-prefix).
Use the same block with `REPO="${LODESTAR_REPO}"` for the `ci_github_*` values.

✏️ Edit `envs/prod/terraform.tfvars` by hand (it was copied from the example in step 0.4): `project_id`,
`project_number` (`${PROD_PROJECT_NUMBER}`), `billing_account` (`${BILLING_ACCOUNT}`), the `ci_*` values, one entry
in `services` per service hosted in production, and the two state values printed here:

```bash
printf 'state_bucket=%s\nstate_kms_key_id=%s\n' "$(tofu -chdir=bootstrap/prod output -raw state_bucket)" "$(tofu -chdir=bootstrap/prod output -raw kms_key_id)"
```

Expect: both values. Rules the variables enforce: service keys are generic and 3 to 20 characters (they build the
pool IDs `gh-<key>` and appear in resource addresses), `deployer_account_id` is 6 to 30 characters and unique,
`sub_claim_prefix` must equal the one built from that entry's owner, repository and IDs. CI sets `region` and
`node_locations` itself (`TF_PROD_REGION`, `TF_PROD_NODE_LOCATIONS`, step 4), so they must match the tfvars; leave
`budget_display_name` and `state_prefix` at their defaults, because CI cannot set them. Edit the file, do not append to it.

### 3.2 Init and plan

✏️ (writes a saved plan; nothing changes in Google Cloud)

```bash
tofu -chdir=envs/prod init
tofu -chdir=envs/prod plan -out=prod.tfplan
```

Expect: `OpenTofu has been successfully initialized!`, then a plan that ends in
`Plan: N to add, 0 to change, 0 to destroy.` with N computed in 3.3. If `init` cannot reach the bucket, or the plan
fails on a permission or on `SERVICE_DISABLED`, see the troubleshooting table; do not apply a plan that ended in an
error.

### 3.3 The expected add count

The L4.3 report counted 51 resources for 2 services (one with 1 secret key, one with 2). By module:

| Module | Resources | Depends on |
| --- | --- | --- |
| `project` | 9: the 8 APIs and the container audit config | nothing |
| `network` | 4: VPC, subnet, router, NAT | once per root |
| `node_sa` | 2 | once per root |
| `gke` | 2: the cluster and its node pool | once per root |
| `gke_secrets_key` | 3: key ring, key, the GKE service agent's grant | once per root |
| `connect_role` | 1: the custom role every deployer holds | once per root |
| `ci_planner` | 12 | once per root |
| `platform_secrets` | 2: the tunnel token container and its grant | once per root |
| `budget` | 1 | once per root |
| `github_wif["<key>"]` | 5 each | per service |
| `secrets["<key>"]` | 1 each (the conditional grant) plus 1 per secret key | per service, per key |

The fixed part is 9 + 4 + 2 + 2 + 3 + 1 + 12 + 2 + 1 = 36. With S services and K secret keys in total:

`N = 36 + 6 * S + K`

Check against the report: S = 2, K = 3 gives 36 + 12 + 3 = 51. For three services with 1, 2 and 1 keys, S = 3 and
K = 4, so N = 36 + 18 + 4 = 58. This count is derived from the report's inventory, not read from a run: if the
number of your plan differs, compare the per-module counts below before deciding; only a destroy or a replace is a
hard stop (3.4).

🔍 Compute N for your own tfvars (the console only evaluates variables; it changes nothing).

```bash
S="$(printf 'length(var.services)' | tofu -chdir=envs/prod console)"
K="$(printf 'length(flatten([for s in values(var.services) : s.secret_keys]))' | tofu -chdir=envs/prod console)"
printf 'S=%s K=%s N=%s\n' "${S}" "${K}" "$(( 36 + 6 * S + K ))"
```

Expect: your S and K, and N equal to the `Plan: N to add` of 3.2. If they differ:

```bash
tofu -chdir=envs/prod show -no-color prod.tfplan | awk '/ will be created$/ {split($2, a, "."); print a[1] "." a[2]}' | sort | uniq -c
```

Expect: one count per module as in the table (for example `5 module.github_wif["web"]`). A module with a different
count tells you which resource is missing or extra; paste it.

### 3.4 Nothing may be destroyed or replaced

🔍 Both checks must pass before any apply.

```bash
tofu -chdir=envs/prod show -no-color prod.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
tofu -chdir=envs/prod show -no-color prod.tfplan | grep -cE ' will be (updated in-place|destroyed)'
```

Expect: the first prints one line only, the summary `... 0 to destroy.`; the second prints `0`. A line saying
`must be replaced`, `-/+` or `will be destroyed` is a HARD STOP: delete the plan (`rm -f envs/prod/prod.tfplan`),
do not apply, and paste the plan.

### 3.5 Apply, then "No changes"

Wait times: the APIs take about a minute to propagate; a regional cluster takes about 10 to 15 minutes to create,
and its node pool a few more, so the whole apply takes about 15 to 25 minutes. Do not interrupt it. These times are
estimates, not promises.

✏️ Creates the production infrastructure and starts billing.

```bash
tofu -chdir=envs/prod apply prod.tfplan
tofu -chdir=envs/prod plan
```

Expect: `Apply complete! Resources: N added, 0 changed, 0 destroyed.`, then
`No changes. Your infrastructure matches the configuration.` Anything else: stop and paste it.

If the apply fails part way: the saved plan is stale. Do not reuse it:

```bash
rm -f envs/prod/prod.tfplan
sleep 180
tofu -chdir=envs/prod plan -out=prod.tfplan
```

Expect: a new plan with fewer adds than before and still `0 to change, 0 to destroy`. Review it with 3.4, then apply
that file. The known first-apply pitfalls, all of them waits for propagation, so re-running is the fix:

- `SERVICE_DISABLED` on an API just enabled: wait 2 to 3 minutes.
- The cluster fails on the key (`cloudkms ... permission`): the GKE service agent's grant has not propagated; wait a few
  minutes and run again.
- `Identity Pool does not exist` on an External Secrets grant: the cluster's pool `<project>.svc.id.goog` appears only
  once the cluster is up; run again once the cluster exists (the code orders the grants after the cluster).
- `SERVICE_DISABLED` for `cloudbilling.googleapis.com` on a billing-account grant: the `ci_planner` module enables the
  Cloud Billing API; wait 2 to 3 minutes and run again.

✏️ Delete the plan file.

```bash
rm -f envs/prod/prod.tfplan
```

Expect: no output.

### 3.6 Save the service list

The later steps loop over the services. This writes them to the private folder, tab separated: the key, the service
name (the namespace prefix), the deployer account ID and the repository. Nothing is printed to a log.

✏️ (writes two files of identifiers in the private folder)

```bash
printf 'jsonencode(var.services)' | tofu -chdir=envs/prod console | jq -r . | jq -r 'to_entries[] | [.key, .value.service_name, .value.deployer_account_id, .value.github_repository] | @tsv' > ~/platform-config/prod-services.tsv
printf 'jsonencode(var.services)' | tofu -chdir=envs/prod console | jq -r . | jq -r 'to_entries[] | .key as $k | .value.service_name as $s | .value.secret_keys[] | [$k, $s, .] | @tsv' > ~/platform-config/prod-secrets.tsv
chmod 600 ~/platform-config/prod-services.tsv ~/platform-config/prod-secrets.tsv
wc -l ~/platform-config/prod-services.tsv ~/platform-config/prod-secrets.tsv
```

Expect: `wc` shows S lines for the first file and K lines for the second, matching 3.3.

## 4. The CI planner secrets and the first drift run

Why: `plan-prod` and `drift-prod` plan `envs/prod` with its own read-only planner, so nothing in the `apps` project
can read production state. Follow [CI identity runbook, section 9](ci-identity-runbook.md#9-production-planner)
in full, with `LODESTAR_REPO` from your env file and `GH_REPO` unset: the 12 secrets and 2 variables, the first
drift run and the public-log identifier scan. Do not copy its commands here.

Expect (from that section): `gh secret list` shows 12 `TF_PROD_*` secrets and `gh variable list` shows 2; the run
`Drift envs/prod` succeeds and its summary says `No changes.`; the log scan prints `0`. A permission error right after
the apply is IAM propagation: wait and run the drift again. A scan count above `0` is a leak: delete the run first,
then follow that section.

## 5. Cluster access

Why: a separate kubeconfig keeps production from mixing with `apps` and with local clusters, and the DNS endpoint is
the only way in (the cluster has no IP endpoint), the same way CI connects.

✏️ (writes `~/.kube/gke-prod.yaml`)

```bash
export KUBECONFIG="${PROD_KUBECONFIG}"
gcloud container clusters get-credentials "${PROD_CLUSTER}" --region "${PROD_REGION}" --project "${PROD_PROJECT_ID}" --dns-endpoint
kubectl config current-context
```

Expect: `Fetching cluster endpoint and auth data.` and `kubeconfig entry generated for prod.`, then a context named
`gke_<project>_europe-west1_prod`. Set `KUBECONFIG` in every new production terminal (it is not in the env file on
purpose: the `apps` env file sets the same variable). If `kubectl` reports `gke-gcloud-auth-plugin not found`,
install the plugin (ops 1.1).

🔍 Both nodes, one in each zone, and no external address (private nodes).

```bash
kubectl get nodes -o wide
```

Expect: 2 nodes `Ready` (1 to 2 per zone, the pool starts with 1 in each), `<none>` in `EXTERNAL-IP`. If `kubectl` hangs,
check `printf '%s\n' "${KUBECONFIG}"` and that `gcloud container clusters describe` says `status: RUNNING`.

🔍 The IP endpoint is disabled: the control plane answers on its DNS name only.

```bash
gcloud container clusters describe "${PROD_CLUSTER}" --region "${PROD_REGION}" --project "${PROD_PROJECT_ID}" \
  --format='yaml(controlPlaneEndpointsConfig)'
```

Expect: `dnsEndpointConfig` with `allowExternalTraffic: true` and an `endpoint` host name, and `ipEndpointsConfig` with
`enabled: false`: the module sets `enabled = var.enable_public_endpoint` and `envs/prod` passes `false`. No public
address may appear anywhere in it. The exact field layout of this output was not seen in a run (the `apps` runbook
checks `enablePublicEndpoint: false`, the field of the earlier private-endpoint switch); if the layout differs but
there is still an IP address, paste it, because that is the one result that must not happen.

## 6. Add-ons

Run from the template root (your clone of the fullstack template) with `source ~/prod-setup.env` and
`export KUBECONFIG="${PROD_KUBECONFIG}"` done. The template owns these steps; this section only says which
guide section to follow and what differs in production. The helper files hold identifiers: keep them in
`~/platform-config`, never in a repository.

| Add-on | Template guide section | Differs in production |
| --- | --- | --- |
| namespaces and deployer RBAC | `wiki/gke-cluster-setup.md`, 13.2 (ops section 7) | one `<service_name>-production` per service; no database namespace; the deployer is `<deployer_account_id>@<project>` |
| External Secrets operator | `wiki/gke-cluster-setup.md`, 14.1 (ops 8.1) | the same chart version as `apps` |
| Secret Manager grants | `wiki/gke-cluster-setup.md`, 14.2 (ops 8.2) | do NOT run: `envs/prod` created them |
| a `secret-manager` store per namespace | `wiki/gke-cluster-setup.md`, 14.3 (ops 8.3) | stores for the production namespaces and `cloudflared` only |
| the tunnel and `cloudflared` | `wiki/cloudflare-setup.md`, 8.2, 8.3 and 8.7 | its own tunnel `prod`; the secret and the grant exist already; 2 or more replicas across zones |

### 6.1 The namespaces bootstrap, per service

Why: the chart creates no namespaces. The bootstrap creates, per service, the namespace `<service_name>-production`
(restricted Pod Security, a quota and a limit range) and binds the deployer service account to a Role in it. The
deployer's Kubernetes user name is its service account's e-mail, built from the `deployer_account_id` of the tfvars.

🔍 The list to work through:

```bash
cat ~/platform-config/prod-services.tsv
```

Expect: one row per service: key, service name, deployer account ID, repository.

✏️ Run the block once per service, from that service's template-derived repository root (a service that does not use
the template's bootstrap follows its own guide for the namespace and the Role). Set the two values from its row. It
renders and applies only; the render never contacts the cluster.

```bash
SVC="your-service-name"
DEP="gh-deployer-web"
export PATH="${PWD}/.tools/bin:${PATH}"
printf 'deployer:\n  name: %s@%s.iam.gserviceaccount.com\n' "${DEP}" "${PROD_PROJECT_ID}" > ~/platform-config/bootstrap-values-${SVC}-production.yaml
scripts/k8s-bootstrap.sh production --release "${SVC}" --values ~/platform-config/bootstrap-values-${SVC}-production.yaml > ~/platform-config/bootstrap-${SVC}-production.yaml
yq 'select(.kind == "Namespace")' ~/platform-config/bootstrap-${SVC}-production.yaml | kubectl apply -f -
kubectl apply --dry-run=server -f ~/platform-config/bootstrap-${SVC}-production.yaml
kubectl apply -f ~/platform-config/bootstrap-${SVC}-production.yaml
```

Expect: `namespace/<service>-production created`, then every dry-run line ends `(server dry run)`, then the objects
`created`. The namespaces are applied first because a server dry run of an object in a missing namespace fails with
`NotFound`. A rerun is safe (`configured`). Use a short `SVC`: the chart's `<fullname>-pg-backup-verify` CronJob name
is refused above 52 characters (ops 7).

🔍 Each deployer may deploy in its own namespace and may not change quotas:

```bash
kubectl auth can-i create deployments -n "${SVC}-production" --as="${DEP}@${PROD_PROJECT_ID}.iam.gserviceaccount.com"
kubectl auth can-i create resourcequotas -n "${SVC}-production" --as="${DEP}@${PROD_PROJECT_ID}.iam.gserviceaccount.com"
```

Expect: `yes`, then `no`. Repeat the whole of 6.1 for every row of the list.

### 6.2 External Secrets, the same chart version as `apps`

Why: both clusters must run the same operator version. The version is the `external-secrets-chart` row of the
template's `tools/pins.tsv`, which is what ops 8.1 installs.

🔍 The version `apps` runs, then the version the pin file gives:

```bash
KUBECONFIG="${HOME}/.kube/gke-apps.yaml" .tools/bin/helm -n external-secrets list --output json | jq -r '.[0].chart'
awk -F'\t' '$1 == "external-secrets-chart" {print $2}' tools/pins.tsv
```

Expect: `external-secrets-<version>` and then the same `<version>`. If they differ, stop: someone moved the pin after
`apps` was installed. Decide which version both clusters should run (upgrade `apps` first by its own runbook) before
you install here. The `apps` kubeconfig path is the `KUBECONFIG` of `~/gke-setup.env`; adjust it if yours differs.

✏️ Install into the production cluster (the active `KUBECONFIG`). It installs helm and the chart into `.tools`.

```bash
scripts/tools.sh install helm4 external-secrets-chart
ESO_VERSION="$(awk -F'\t' '$1 == "external-secrets-chart" {print $2}' tools/pins.tsv)"
.tools/bin/helm upgrade --install external-secrets ".tools/opt/external-secrets-chart-${ESO_VERSION}/external-secrets" \
  --server-side=true --force-conflicts \
  --namespace external-secrets --create-namespace \
  -f deploy/external-secrets/external-secrets-values.yaml --wait --timeout 5m
```

Expect: `STATUS: deployed`.

🔍

```bash
.tools/bin/helm -n external-secrets list --output json | jq -r '.[0].chart'
kubectl -n external-secrets get deployments
kubectl get crd secretstores.external-secrets.io externalsecrets.external-secrets.io
```

Expect: `external-secrets-<the pinned version>`; three deployments (`external-secrets`,
`external-secrets-cert-controller`, `external-secrets-webhook`), each `1/1`; both CRDs listed. If you set the
production terminal's `KUBECONFIG` wrong, this lands in `apps`: check `kubectl config current-context` first.

### 6.3 The grants are already there; a store in each namespace

The apps runbook created one conditional `secretAccessor` grant per namespace by hand (ops 8.2). In production
`module.secrets` and `module.platform_secrets` of `envs/prod` created them, one per `<service_name>-production`
namespace and one for `cloudflared`. Do not create or change them by hand: it would show as drift.

🔍

```bash
gcloud projects get-iam-policy "${PROD_PROJECT_ID}" --flatten=bindings \
  --filter='bindings.role=roles/secretmanager.secretAccessor' \
  --format='table(bindings.condition.title,bindings.condition.expression)'
```

Expect: one row `eso-<service_name>-production` per service and one `eso-cloudflared`, each with a `startsWith(...)`
condition, and no row without a condition. A missing row: re-run the `envs/prod` plan (3.5); never create it here.

✏️ Apply the store, from the template root, in each production namespace (the one for `cloudflared` is applied in 6.4,
after its namespace exists).

```bash
while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME DEP_ID REPO_NAME; do
  kubectl apply -n "${SVC_NAME}-production" -f deploy/external-secrets/secretstore-secret-manager.yaml
done 3< ~/platform-config/prod-services.tsv
```

Expect: `serviceaccount/external-secrets created` and `secretstore.external-secrets.io/secret-manager created` per
production namespace.

🔍

```bash
kubectl get secretstores --all-namespaces
```

Expect: `secret-manager` in each production namespace (and in `cloudflared` after 6.4), `STATUS Valid`, `READY True`. A first run
can show the store not ready until the operator's webhook is up: apply again after a minute.

### 6.4 `cloudflared`: a tunnel `prod`, 2 or more replicas across zones, a PDB

Why: production's edge is its own tunnel, with its connector in this cluster, so a non-production failure or token
leak cannot touch production traffic. Follow `wiki/cloudflare-setup.md`, sections 8.2 (create the tunnel, named
`prod` after the cluster, and copy its token), 8.3 (run the connector) and 8.7 (notifications). That guide is on the
template's `phase-11` branch until merged. Its production note (9.1) says production repeats 8.2, 8.3 and 8.7. What
differs from the guide's text, which assumes one cluster and the default project:

- Skip its `gcloud secrets create` and `gcloud projects add-iam-policy-binding`: `module.platform_secrets` already
  created the container `cloudflared-tunnel-token` and the grant `eso-cloudflared` (the output
  `CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID` names it).
- Do not `source ~/gke-setup.env`. Name the project in every `gcloud` command, as below.
- Do the namespace and priority class first, then the store for `cloudflared`, then the rest.

Prerequisite, before any manifest of `deploy/cloudflared/` is applied: the connector must carry a zone spread, which
older copies of the template lack. 🔍 From the template root:

```bash
grep -c 'topology.kubernetes.io/zone' deploy/cloudflared/deployment.yaml
```

Expect: `1`. If it prints `0`, the template checkout is too old: run `git switch phase-11` (or use the template's
`main` once that work is merged) and check again. Do not go on with `0`: both replicas could land in one zone.

✏️ From the template root: the namespace, the priority class and the namespace's store.

```bash
kubectl apply -f deploy/cloudflared/namespace.yaml
kubectl apply -f deploy/cloudflared/priorityclass.yaml
kubectl apply -n cloudflared -f deploy/external-secrets/secretstore-secret-manager.yaml
kubectl -n cloudflared get secretstore secret-manager
```

Expect: `namespace/cloudflared created`, `priorityclass.scheduling.k8s.io/cloudflared created`, the service account and the
store `created`, then the store with `STATUS Valid` and `READY True` (apply again after a minute if the webhook was not
up).

✏️ 🔐 The token goes in as a new version of the existing secret, from the prompt, never echoed or put on a command line.

```bash
printf 'Paste the production tunnel token, then press Enter (nothing is shown): '
read -rs TUNNEL_TOKEN
printf '\n'
printf '%s' "${TUNNEL_TOKEN}" | gcloud secrets versions add cloudflared-tunnel-token --project "${PROD_PROJECT_ID}" --data-file=-
unset TUNNEL_TOKEN
```

Expect: `Created version [1] of the secret [cloudflared-tunnel-token].` If it says the secret does not exist, the `envs/prod`
apply (step 3) did not finish: do not create it by hand.

✏️ The token's ExternalSecret, then the connector.

```bash
kubectl apply -f deploy/cloudflared/externalsecret.yaml
kubectl -n cloudflared wait --for=condition=Ready externalsecret/tunnel-token --timeout=120s
kubectl apply -f deploy/cloudflared/deployment.yaml -f deploy/cloudflared/pdb.yaml
kubectl -n cloudflared rollout status deployment/cloudflared --timeout=180s
```

Expect: `condition met`, then `deployment "cloudflared" successfully rolled out`. If the wait times out:
`kubectl -n cloudflared describe externalsecret tunnel-token`; a permission error means the grant of 6.3 is missing.

The connector spreads its replicas over nodes and zones through the constraint checked above (`ScheduleAnyway`), so no
patch is needed. Close its network:

✏️

```bash
kubectl apply -f deploy/cloudflared/networkpolicy.yaml
kubectl -n cloudflared rollout restart deployment/cloudflared
kubectl -n cloudflared rollout status deployment/cloudflared --timeout=180s
```

Expect: the policy `created`, `deployment.apps/cloudflared restarted`, and the rollout completing. The restart makes
new connections under the policy, so the check below cannot pass on connections made before it. Keep `replicas` at 2
or more: with 1 the zone rule and the budget protect nothing.

🔍 Two Pods, in two different zones, and a budget that lets one go at a time.

```bash
kubectl -n cloudflared get pods -l app=cloudflared -o json | jq -r '.items[].spec.nodeName' | while read -r NODE; do
  kubectl get node "${NODE}" -L topology.kubernetes.io/zone --no-headers
done
kubectl -n cloudflared get pdb cloudflared
kubectl -n cloudflared logs deployment/cloudflared --since=3m | grep -c 'Registered tunnel connection'
```

Expect: two node lines ending in different zones (`europe-west1-b` and `europe-west1-c`); the budget with
`MIN AVAILABLE 1` and `ALLOWED DISRUPTIONS 1`; and a count of 1 or more `Registered tunnel connection` lines (the connector reaches Cloudflare through the policy). In the Cloudflare
dashboard the tunnel `prod` shows Healthy. If both Pods share a zone, a zone had no Ready node when they were scheduled (the rule is best effort): check
`kubectl get nodes -L topology.kubernetes.io/zone`, and once nodes in both zones are Ready run
`kubectl -n cloudflared rollout restart deployment/cloudflared` and check again.

## 7. Verification

The same checks as `apps` (hardening runbook section 4, import runbook 11.7, ops 12.3), with production's names.
All are read-only. Use the production terminal.

### 7.1 Private endpoint only

Done in step 5 (`ipEndpointsConfig.enabled: false`). Run it again here after any cluster change.

### 7.2 Secrets are encrypted at the application layer with production's key

🔍

```bash
gcloud container clusters describe "${PROD_CLUSTER}" --region "${PROD_REGION}" --project "${PROD_PROJECT_ID}" \
  --format='yaml(databaseEncryption,rbacBindingConfig,securityPostureConfig)'
```

Expect: `databaseEncryption.state: ENCRYPTED` with `keyName` ending
`/keyRings/prod-gke/cryptoKeys/prod-secrets`, both `rbacBindingConfig` switches `false`, and posture mode `BASIC`.
The key name must be production's, never the `gke/cryptoKeys/secrets` of `apps`.

### 7.3 Flow logs

🔍

```bash
gcloud compute networks subnets describe prod-subnet --region "${PROD_REGION}" --project "${PROD_PROJECT_ID}" \
  --format='yaml(logConfig)'
```

Expect: `enable: true`, `aggregationInterval: INTERVAL_10_MIN`, `flowSampling: 0.1`, `metadata: INCLUDE_ALL_METADATA`.

### 7.4 The container audit config

🔍

```bash
gcloud projects get-iam-policy "${PROD_PROJECT_ID}" --format=json \
  | python3 -c 'import json,sys; [print(c["service"], sorted(l["logType"] for l in c["auditLogConfigs"])) for c in json.load(sys.stdin).get("auditConfigs", []) if c["service"] == "container.googleapis.com"]'
```

Expect: `container.googleapis.com ['ADMIN_READ', 'DATA_WRITE']`, and nothing else (reads would log every get and watch).

### 7.5 Nodes in both zones, and no anonymous bindings

🔍

```bash
kubectl get nodes -L topology.kubernetes.io/zone
{ kubectl get clusterrolebindings -o json; kubectl get rolebindings -A -o json; } \
  | jq -r '.items[] | select(any(.subjects[]?; .name == "system:authenticated" or .name == "system:unauthenticated" or .name == "system:anonymous")) | "\(.kind) \(.metadata.namespace // "-") \(.metadata.name)"'
```

Expect: at least 2 nodes `Ready`, with `europe-west1-b` and `europe-west1-c` each present at least once (a floor of 1 per
zone, a cap of 2). Then only `ClusterRoleBinding - system:basic-user`, `ClusterRoleBinding - system:discovery` and
`ClusterRoleBinding - system:public-info-viewer`. Anything else: stop and paste it; delete nothing. Only one zone shown:
the pool has not balanced yet; wait a few minutes, and if it stays so, paste `gcloud container node-pools describe default-pool --cluster "${PROD_CLUSTER}" --region "${PROD_REGION}" --project "${PROD_PROJECT_ID}"`.

### 7.6 The budget

🔍

```bash
gcloud billing budgets list --billing-account="${BILLING_ACCOUNT}" \
  --format='yaml(displayName,amount.specifiedAmount,budgetFilter.projects,thresholdRules)'
```

Expect: among the account's budgets, one named `Production monthly budget` with `currencyCode: EUR` and `units: '250'`
scoped to `projects/<production project number>`, with `thresholdPercent` 0.5, 0.9, 1.0 and 1.5 of current spend. A
budget alerts; it never stops spending.

### 7.7 The Workload Identity probe, per namespace

Why: it proves a namespace's `secret-manager` store reads its own service's secrets and is refused the secrets of
another service. It needs a value in the secrets, so do step 8 for at least the first key of every service first, then
come back. With one service only, run the first probe and skip the second.

✏️ Creates two `ExternalSecret`s per namespace, then deletes them. `OWN` is the service's first secret, `OTHER` the
first secret of a different service.

```bash
probe() {
kubectl -n "${1}" apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${2}
spec:
  secretStoreRef: {name: secret-manager, kind: SecretStore}
  refreshInterval: 1h
  target: {name: ${2}}
  data:
    - secretKey: value
      remoteRef: {key: ${3}}
EOF
}
while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME DEP_ID REPO_NAME; do
  OWN="$(awk -F'\t' -v s="${SVC_NAME}" '$2 == s {print $2 "-production-" $3; exit}' ~/platform-config/prod-secrets.tsv)"
  OTHER="$(awk -F'\t' -v s="${SVC_NAME}" '$2 != s {print $2 "-production-" $3; exit}' ~/platform-config/prod-secrets.tsv)"
  probe "${SVC_NAME}-production" probe-own "${OWN}"
  kubectl -n "${SVC_NAME}-production" wait externalsecret/probe-own --for=condition=Ready --timeout=60s
  if [ -n "${OTHER}" ]; then
    probe "${SVC_NAME}-production" probe-other "${OTHER}"
    kubectl -n "${SVC_NAME}-production" wait externalsecret/probe-other --for=condition=Ready=false --timeout=60s
    kubectl -n external-secrets logs deployment/external-secrets --tail=500 | grep '"name":"probe-other"' | grep "\"namespace\":\"${SVC_NAME}-production\"" | grep -m1 -o 'PermissionDenied'
    kubectl -n "${SVC_NAME}-production" delete externalsecret probe-other
  fi
  kubectl -n "${SVC_NAME}-production" delete externalsecret probe-own
done 3< ~/platform-config/prod-services.tsv
```

Expect: per namespace, `externalsecret.external-secrets.io/probe-own condition met`; with a second service,
`probe-other condition met` for `Ready=false` and a `PermissionDenied` line from the operator's log (the event itself
only says the data could not be read); then the deletes (they remove the Secret that `probe-own` made too). If
`probe-other` synced: a binding has no condition or a wrong one; stop, and do not deploy. If `probe-own` fails with a
`NotFound`-type message, its secret has no value yet (step 8); with `PermissionDenied`, the grant of 6.3 is missing or
names another namespace.

After the first deploy, `kubectl get externalsecrets --all-namespaces` must show `SecretSynced`, `READY True` for every
one.

## 8. Production secret values

Why: `envs/prod` created only empty secret containers, named `<service_name>-production-<key>`. The values are never in
code or in OpenTofu state, and nothing copies them from `apps`. Each value is typed at a prompt, goes to `gcloud` on
standard input and is unset. Nothing is echoed.

🔍 The containers that exist, one per key of the tfvars (no value printed):

```bash
gcloud secrets list --project "${PROD_PROJECT_ID}" --format='value(name.basename())' | sort
```

Expect: `cloudflared-tunnel-token` and one `<service_name>-production-<key>` per row of `prod-secrets.tsv`, K + 1 names in
all. A name missing: the apply of step 3 did not finish.

✏️ 🔐 Add the first version of every service secret, one prompt per secret. The loop reads the list on file descriptor 3
so the prompt can read your keyboard.

```bash
while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME SECRET_KEY; do
  printf 'Value of %s-production-%s (nothing is shown): ' "${SVC_NAME}" "${SECRET_KEY}"
  read -rs VALUE
  printf '\n'
  printf '%s' "${VALUE}" | gcloud secrets versions add "${SVC_NAME}-production-${SECRET_KEY}" --project "${PROD_PROJECT_ID}" --data-file=-
  unset VALUE
done 3< ~/platform-config/prod-secrets.tsv
```

Expect: one `Created version [1] of the secret [<service>-production-<key>].` per secret. `printf '%s'` adds no trailing
newline to the value; paste or type the value without one. A random password can come from `openssl rand -hex 24`
piped into the same `gcloud secrets versions add` instead of the prompt. The database values of a production
database (Cloud SQL) come with that database, in its own design.

🔍 Each secret now has one enabled version (the names and states only):

```bash
while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME SECRET_KEY; do
  gcloud secrets versions list "${SVC_NAME}-production-${SECRET_KEY}" --project "${PROD_PROJECT_ID}" --format='value(name.basename(),state)'
done 3< ~/platform-config/prod-secrets.tsv
```

Expect: one line `1	ENABLED` (the version number, then the state) per secret, nothing else. Rotation is the same command, which adds version 2; it does not delete
version 1. Now run 7.7.

## 9. The template's `production` environment variables

Why: the template's deploy jobs read `GCP_PROJECT_ID`, `GKE_CLUSTER`, `GKE_LOCATION`, `GCP_WIF_PROVIDER` and
`GCP_DEPLOYER_SA` inside `environment: production` jobs, so production variables set on that environment override any
repository-level value, and no workflow changes. They are set per repository, from the `envs/prod` outputs. The
template's settings script will gain support for this (template task 11.3); until then, these commands. The
`production` environment must already exist in each repository (the settings script of the template creates it): on a
`404` for the environment, create it first, with its reviewers and its `v*` tag rule.

Run from this repository's root (step 6 left you in the template), with `GH_REPO` unset (step 0.2).

🔍 The values to be set (no secret among them; the WIF provider and the deployer account are identifiers):

```bash
cd "${LODESTAR_ROOT}"
pwd
tofu -chdir=envs/prod output
```

Expect: this repository's root, then `GCP_PROJECT_ID`, `GKE_CLUSTER = "prod"`, `GKE_LOCATION = "europe-west1"`, the maps `GCP_WIF_PROVIDER` and
`GCP_DEPLOYER_SA` with one entry per service key, `CI_WIF_PROVIDER`, `CI_SERVICE_ACCOUNT`,
`CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID` and `dns_endpoint`.

✏️ Set them in every service repository. The outputs are read once; any empty value stops the loop before a variable is set.

```bash
cd "${LODESTAR_ROOT}"
OUT_PROJECT="$(tofu -chdir=envs/prod output -raw GCP_PROJECT_ID)"
OUT_CLUSTER="$(tofu -chdir=envs/prod output -raw GKE_CLUSTER)"
OUT_LOCATION="$(tofu -chdir=envs/prod output -raw GKE_LOCATION)"
OUT_WIF="$(tofu -chdir=envs/prod output -json GCP_WIF_PROVIDER)"
OUT_SA="$(tofu -chdir=envs/prod output -json GCP_DEPLOYER_SA)"
if [ -z "${OUT_PROJECT}" ] || [ -z "${OUT_CLUSTER}" ] || [ -z "${OUT_LOCATION}" ] || [ -z "${OUT_WIF}" ] || [ -z "${OUT_SA}" ]; then
  printf 'an output is empty: stop\n'
else
  while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME DEP_ID REPO_NAME; do
    WIF="$(printf '%s' "${OUT_WIF}" | jq -r --arg k "${SVC_KEY}" '.[$k] // empty')"
    SA="$(printf '%s' "${OUT_SA}" | jq -r --arg k "${SVC_KEY}" '.[$k] // empty')"
    if [ -z "${WIF}" ] || [ -z "${SA}" ]; then
      printf 'no output for service key %s: skipped\n' "${SVC_KEY}"
      continue
    fi
    gh variable set GCP_PROJECT_ID --env production --body "${OUT_PROJECT}" -R "${REPO_NAME}"
    gh variable set GKE_CLUSTER --env production --body "${OUT_CLUSTER}" -R "${REPO_NAME}"
    gh variable set GKE_LOCATION --env production --body "${OUT_LOCATION}" -R "${REPO_NAME}"
    gh variable set GCP_WIF_PROVIDER --env production --body "${WIF}" -R "${REPO_NAME}"
    gh variable set GCP_DEPLOYER_SA --env production --body "${SA}" -R "${REPO_NAME}"
  done 3< ~/platform-config/prod-services.tsv
fi
```

Expect: one `Created variable ...` (or `Updated variable ...`) line per command. `an output is empty: stop` means
the `envs/prod` apply did not finish; `no output for service key <key>` means that key is not in
`tofu -chdir=envs/prod output -json GCP_WIF_PROVIDER` (compare it with the tfvars). Nothing is set in either case.

🔍 Names only per repository, never a value to paste anywhere public:

```bash
while IFS=$'\t' read -r -u 3 SVC_KEY SVC_NAME DEP_ID REPO_NAME; do
  printf '%s: ' "${REPO_NAME}"
  gh variable list --env production -R "${REPO_NAME}" | cut -f1 | sort | tr '\n' ' '
  printf '\n'
done 3< ~/platform-config/prod-services.tsv
```

Expect: per repository, `GCP_DEPLOYER_SA GCP_PROJECT_ID GCP_WIF_PROVIDER GKE_CLUSTER GKE_LOCATION`, plus whatever else the
template put in that environment (for example `EDGE_DOMAIN`). Deploys stay off (`DEPLOY_ENABLED` unset) until the
platform rollout.

## 10. Rollback and teardown notes

A short list; nothing here has been run.

- **`deletion_protection`** on the cluster: a destroy of `module.gke` is refused until `envs/prod/main.tf` passes
  `deletion_protection = false` to the module and that change is applied. Nothing but a deliberate edit turns it off.
- **`prevent_destroy`** on the production state key ring, key and bucket (`bootstrap/prod`), and on the secrets key
  ring and key (`envs/prod`): a plan that would destroy them fails. Cloud KMS keeps key names and never fully
  deletes a ring. Never remove the protection to "clean up".
- **To undo a bad `envs/prod` apply** that has not served traffic: fix the code and apply a reviewed plan. A destroy
  of anything is a hard stop that needs your explicit review.
- **Teardown order, if it is ever needed:**
  1. Remove the workloads and the Cloudflare routes and tunnel (no traffic first).
  2. Delete the production secrets only after their values are saved elsewhere: they are not recoverable.
  3. Set `deletion_protection = false` for the cluster, apply, then `tofu -chdir=envs/prod destroy` (the key ring and
     key stop it; remove them from state with `tofu -chdir=envs/prod state rm` rather than lifting `prevent_destroy`).
  4. Delete the 12 secrets and 2 variables of the production planner (the rollback of
     [CI identity runbook section 9](ci-identity-runbook.md#rollback-of-the-production-planner)) and the
     `production` environment variables of step 9.
  5. The state bucket and its key come last, and are removed by deleting the project
     (`gcloud projects delete "${PROD_PROJECT_ID}"`), which Google keeps recoverable for 30 days.

## 11. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `403 ... serviceusage.googleapis.com ... SERVICE_DISABLED`, or `SERVICE_DISABLED` for another API right after the first apply | the API was enabled seconds ago and has not propagated, or `bootstrap/prod` was not applied (it enables Service Usage, which the `envs/prod` provider bills to) | wait 2 to 3 minutes; for a skipped bootstrap apply it first (step 2); then plan into a new file and apply it |
| `Attribute redefined` for a tfvars key | a block was appended (`>>`) to `terraform.tfvars` twice, so a key is in it twice | keep the first occurrence of each key, then `tofu fmt envs/prod/terraform.tfvars`; edit the file, do not append |
| a `gh` command acts on the template repository, or `Could not resolve to a PullRequest` | `GH_REPO` is set (the `apps` env file sets it) and `gh` prefers it to the current directory | `unset GH_REPO`, or add `-R "<owner>/<repo>"` to the command |
| `command not found`, or an odd path or name such as `nvironment:production` | zsh read `$VAR:e` (or `:h`, `:t`, `:r`, `:a`, `:l`, `:u`, `:s`, `:q`, `:x`, `:p`, `:c`) as a modifier | brace the variable before a colon: `${VAR}:...` |
| a permission error right after an IAM change or an apply: `Permission ... denied`, `getAccessToken denied`, a failed first drift run | IAM changes take up to about 7 minutes to propagate | wait and run again; for a drift run, run the workflow again |
| `Identity Pool does not exist` on an External Secrets grant | `<project>.svc.id.goog` exists only after the first Workload Identity cluster does, and the grant ran before the cluster was ready | run the apply again once the cluster exists (the grants wait for `module.gke`); never create the pool by hand |
| `tofu apply <file>`: no such file, or "Failed to load" a plan | the plan was deleted after its apply, or the path is wrong | plan again into a new file and use `tofu -chdir=envs/prod apply prod.tfplan` |
| a kubectl or helm command lands in `apps` | `KUBECONFIG` points at the `apps` file, or `~/gke-setup.env` was sourced in this terminal | `export KUBECONFIG="${PROD_KUBECONFIG}"`, check `kubectl config current-context`, and open a new terminal if `~/gke-setup.env` was sourced |
| a `gcloud` command acts on the `apps` project | the project was not named and the default project is `apps` | pass `--project "${PROD_PROJECT_ID}"` to every `gcloud` command |
| `gke-gcloud-auth-plugin not found` | the auth plugin is not installed | install it (ops 1.1) |
| `Error acquiring the state lock`, or the backend refuses to initialise | an interrupted run left the lock, or `bootstrap/prod/override.tf` or the tfvars `state_*` values are wrong | read the lock ID in the message; check the bucket and key values; unlock with `tofu -chdir=envs/prod force-unlock <id>` only when no run is active |
