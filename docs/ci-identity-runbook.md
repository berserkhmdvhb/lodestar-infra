# CI identity runbook: PR plans and weekly drift (task L1.7)

You run every command here yourself. Nothing in this repository applies anything on its own.
Commands work in bash and zsh. Run them from the repository root, in the same terminal, in order.

What this does: gives this repository's CI a read-only, keyless identity, so that:

- every pull request that touches `envs/apps/`, `modules/` or the plan workflow shows a plan summary in its job
  summary (`plan.yml`);
- a weekly run (Monday 06:00 UTC, or on demand) plans `main` and opens one issue "Drift detected in
  envs/apps" when the live project differs from the code (`drift.yml`). It closes that issue when the drift is gone.

Until you finish this runbook both workflows succeed without planning and write "CI identity not configured yet"
to the job summary.

## What the identity can and cannot do

- A new pool `github-infra` and provider `lodestar-infra` (the pool of the application deploy workflows is not touched).
  The provider admits only this repository (immutable owner and repository IDs), only `plan.yml` and `drift.yml`,
  only on `main` or a pull request merge ref, and only for the events `pull_request`, `schedule` and `workflow_dispatch`.
- The service account `tofu-planner` can be impersonated by two subjects only: pull requests of this repository
  and `main`. The jobs use no GitHub environment.
- Roles, none of which writes: `roles/viewer`, `roles/iam.securityReviewer` and `roles/serviceusage.serviceUsageConsumer`
  on the project; `roles/storage.objectViewer` on the state bucket; `roles/cloudkms.cryptoKeyEncrypterDecrypter` on
  the state key (the state encryption calls Encrypt as well as Decrypt, so a decrypt-only role fails); and
  `roles/billing.viewer` on the billing account, **which includes cost data** (spend and budget). Custom
  billing roles need an organization, which this account does not have.
- It can read the encrypted state, and it is read-only, but anyone who can push a branch to this repository can
  read whatever the planner can read: the plan runs the branch's code with the planner identity, so a changed
  `plan.yml`, `scripts/ci-plan.sh`, a `.tf` file (for example a `data "external"`) or a provider change is enough.
  Give write access to this repository only to people you trust with that.
- Public logs: every identifying input is a repository secret, so GitHub masks it. The plan is never printed or
  uploaded; the job summary holds counts and resource addresses with their actions, never attribute values.
  A failing run prints only the `Error: ` lines, with every secret value replaced by `***` first (never cut).

## 1. This repository's IDs and subject prefix

```bash
source ~/gke-setup.env
unset GH_REPO
export LODESTAR_REPO="${GH_OWNER}/lodestar-infra"
export LODESTAR_REPO_ID="$(gh api "repos/${LODESTAR_REPO}" --jq .id)"
printf '%s\n' "${LODESTAR_REPO_ID}"
```

Expect: one number. Then the immutable subject prefix:

```bash
export LODESTAR_SUB_PREFIX="$(gh api "repos/${LODESTAR_REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
printf '%s\n' "${LODESTAR_SUB_PREFIX}"
```

Expect: `repo:<owner>@<number>/lodestar-infra@<number>`. Use the value the API gives, exactly.

If it prints nothing, the field is absent. Build the immutable form from the IDs, and know the risk:

```bash
export LODESTAR_SUB_PREFIX="repo:${GH_OWNER}@${GH_OWNER_ID}/lodestar-infra@${LODESTAR_REPO_ID}"
printf '%s\n' "${LODESTAR_SUB_PREFIX}"
```

The identity only works if GitHub puts that form in the token. If the first CI run later fails with
`iam.serviceAccounts.getAccessToken denied`, the repository still issues the plain `repo:<owner>/lodestar-infra`
form: put that in `ci_sub_claim_prefix`, plan and apply again (see the troubleshooting index of the operations runbook).

Save them:

```bash
grep -q '^export LODESTAR_REPO=' ~/gke-setup.env || printf 'export LODESTAR_REPO="%s"\n' "${LODESTAR_REPO}" >> ~/gke-setup.env
grep -q '^export LODESTAR_REPO_ID=' ~/gke-setup.env || printf 'export LODESTAR_REPO_ID="%s"\n' "${LODESTAR_REPO_ID}" >> ~/gke-setup.env
grep -q '^export LODESTAR_SUB_PREFIX=' ~/gke-setup.env || printf 'export LODESTAR_SUB_PREFIX="%s"\n' "${LODESTAR_SUB_PREFIX}" >> ~/gke-setup.env
```

## 2. Add the three variables

Each line is appended only if its key is absent, so running the block twice is harmless (a second copy of a
key fails every later plan with "Attribute redefined"):

```bash
grep -q '^ci_github_repository ' envs/apps/terraform.tfvars || printf 'ci_github_repository = "%s"\n' "${LODESTAR_REPO}" >> envs/apps/terraform.tfvars
grep -q '^ci_github_repo_id ' envs/apps/terraform.tfvars || printf 'ci_github_repo_id    = "%s"\n' "${LODESTAR_REPO_ID}" >> envs/apps/terraform.tfvars
grep -q '^ci_sub_claim_prefix ' envs/apps/terraform.tfvars || printf 'ci_sub_claim_prefix  = "%s"\n' "${LODESTAR_SUB_PREFIX}" >> envs/apps/terraform.tfvars
tofu fmt envs/apps/terraform.tfvars
```

`terraform.tfvars` is git-ignored: never commit it. If a key is already there with an old value, edit that line
by hand: the block never overwrites.

## 3. Plan

First check whether the Cloud Billing API is on in the project:

```bash
gcloud services list --enabled --project "${PROJECT_ID}" --filter='config.name=cloudbilling.googleapis.com' --format='value(config.name)'
```

Empty output is expected: the plan's `cloudbilling` resource enables it. If the name is printed, the API is already on;
that is fine, because enabling an enabled API succeeds, so the apply is idempotent.

```bash
git pull
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=ci-identity.tfplan
```

## 4. Acceptance

The `Plan:` line must read (with `-out`, the notes on outputs and the saved plan follow it):

```text
Plan: 12 to add, 0 to change, 0 to destroy.
```

The 12 adds, and nothing else:

- `module.ci_planner.google_iam_workload_identity_pool.ci`
- `module.ci_planner.google_iam_workload_identity_pool_provider.ci`
- `module.ci_planner.google_service_account.planner`
- 2 x `module.ci_planner.google_service_account_iam_member.wif[...]` (one per subject: `...:pull_request` and `...:ref:refs/heads/main`)
- 3 x `module.ci_planner.google_project_iam_member.planner[...]` (`roles/viewer`, `roles/iam.securityReviewer`, `roles/serviceusage.serviceUsageConsumer`)
- `module.ci_planner.google_storage_bucket_iam_member.state`
- `module.ci_planner.google_kms_crypto_key_iam_member.state`
- `module.ci_planner.google_project_service.cloudbilling`
- `module.ci_planner.google_billing_account_iam_member.viewer`

Two mechanical checks:

```bash
tofu -chdir=envs/apps show -no-color ci-identity.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|will be updated|to change|to destroy'
```

Only the summary line (`... 0 to change, 0 to destroy.`) may match.

```bash
tofu -chdir=envs/apps show -no-color ci-identity.tfplan | grep -E '^  # .* will be ' | sort
```

Expect exactly 12 lines, all `will be created`, all starting with `module.ci_planner.`, matching the list above.

### HARD STOP

> If the summary says anything but `12 to add, 0 to change, 0 to destroy`, if any other address appears, if
> any line says `must be replaced` or `will be destroyed`, or if one of the three role lists differs: DO NOT
> APPLY. Delete the plan file (`rm -f envs/apps/ci-identity.tfplan`), stop and paste the plan.

## 5. Apply

```bash
tofu -chdir=envs/apps apply ci-identity.tfplan
rm -f envs/apps/ci-identity.tfplan
tofu -chdir=envs/apps plan
```

The last command must print `No changes. Your infrastructure matches the configuration.`

If the apply fails on the billing member with `SERVICE_DISABLED` / "has not been used in project" right after the API was
enabled, the enablement has not propagated yet. Delete the plan file, wait, plan again into a new file (expect
`Plan: 1 to add, 0 to change, 0 to destroy.`, only the billing member) and apply that file:

```bash
rm -f envs/apps/ci-identity.tfplan
sleep 180
tofu -chdir=envs/apps plan -out=ci-identity-2.tfplan
tofu -chdir=envs/apps apply ci-identity-2.tfplan
rm -f envs/apps/ci-identity-2.tfplan
```

## 6. Set the secrets without printing them

Each value is its own repository secret, so GitHub masks each one in every log. Nothing below prints a value.

```bash
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_WIF_PROVIDER)" | gh secret set GCP_CI_WIF_PROVIDER --repo "${LODESTAR_REPO}"
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_SERVICE_ACCOUNT)" | gh secret set GCP_CI_SA --repo "${LODESTAR_REPO}"
```

The other fourteen secrets come from `envs/apps/terraform.tfvars`. The function reads one key and pipes it to `gh`:

```bash
set_secret() {
  sed -n "s/^${2} *= *\"\(.*\)\"\$/\1/p" envs/apps/terraform.tfvars | head -n 1 | tr -d '\n' | gh secret set "${1}" --repo "${LODESTAR_REPO}"
}
set_secret TF_PROJECT_ID project_id
set_secret TF_PROJECT_NUMBER project_number
set_secret TF_BILLING_ACCOUNT billing_account
set_secret TF_BUDGET_ID budget_id
set_secret TF_BUDGET_DISPLAY_NAME budget_display_name
set_secret TF_GITHUB_REPOSITORY github_repository
set_secret TF_GITHUB_OWNER_ID github_owner_id
set_secret TF_GITHUB_REPO_ID github_repo_id
set_secret TF_SUB_CLAIM_PREFIX sub_claim_prefix
set_secret TF_CI_GITHUB_REPOSITORY ci_github_repository
set_secret TF_CI_GITHUB_REPO_ID ci_github_repo_id
set_secret TF_CI_SUB_CLAIM_PREFIX ci_sub_claim_prefix
set_secret TF_STATE_BUCKET state_bucket
set_secret TF_STATE_KMS_KEY_ID state_kms_key_id
```

Check that all sixteen apps secrets exist (names only; once section 9 is done the list also holds the 12 `TF_PROD_*` secrets, 28 in total):

```bash
gh secret list --repo "${LODESTAR_REPO}" | cut -f1 | sort
```

Expect these 16 names (plus the `TF_PROD_*` ones after section 9): `GCP_CI_SA`, `GCP_CI_WIF_PROVIDER`, `TF_BILLING_ACCOUNT`, `TF_BUDGET_DISPLAY_NAME`,
`TF_BUDGET_ID`, `TF_CI_GITHUB_REPO_ID`, `TF_CI_GITHUB_REPOSITORY`, `TF_CI_SUB_CLAIM_PREFIX`,
`TF_GITHUB_OWNER_ID`, `TF_GITHUB_REPO_ID`, `TF_GITHUB_REPOSITORY`, `TF_PROJECT_ID`, `TF_PROJECT_NUMBER`,
`TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ID`, `TF_SUB_CLAIM_PREFIX`.

If a secret is wrong, run `set_secret` for it again. Never set a secret with `echo`.

The region and the zone are not identifying, so they are repository variables, not secrets. They must be
the values your live cluster uses (the ones in `~/gke-setup.env`): the workflows pass them to `region` and
`zone`, and a different value would plan a replacement of the cluster and everything in the region.

```bash
gh variable set TF_REGION --body "${REGION}" --repo "${LODESTAR_REPO}"
gh variable set TF_ZONE --body "${ZONE}" --repo "${LODESTAR_REPO}"
gh variable list --repo "${LODESTAR_REPO}"
```

Expect exactly these 2 variables, `TF_REGION` and `TF_ZONE`, with your region and zone. The workflows check all
18 values (16 secrets and 2 variables) and skip the plan with the "not configured yet" notice if one is missing.

## 7. First run

```bash
gh workflow run drift.yml --repo "${LODESTAR_REPO}"
gh run watch --repo "${LODESTAR_REPO}"
```

Expect: the run succeeds, its job summary says `Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace.` and
`No changes.`, and no drift issue is opened. A permission error right after the apply can be IAM propagation:
wait a few minutes and run it again.

A pull request that touches `envs/apps/`, `modules/`, `scripts/ci-plan.sh`, `scripts/ci-changed.sh` or `plan.yml` now
shows its plan summary in the job summary of the `Plan` workflow (the apps job; the production job is section 9).

## 8. Rollback

- Remove the `ci_planner` module call, its three variables, the two outputs and the three tfvars lines. Plan: only
  destroys of the 11 CI-only resources above (the one allowed destroy case; anything else is a stop), then apply.
- Delete the 2 variables and the 16 secrets:

```bash
for name in GCP_CI_SA GCP_CI_WIF_PROVIDER TF_BILLING_ACCOUNT TF_BUDGET_DISPLAY_NAME TF_BUDGET_ID TF_CI_GITHUB_REPO_ID TF_CI_GITHUB_REPOSITORY TF_CI_SUB_CLAIM_PREFIX TF_GITHUB_OWNER_ID TF_GITHUB_REPO_ID TF_GITHUB_REPOSITORY TF_PROJECT_ID TF_PROJECT_NUMBER TF_STATE_BUCKET TF_STATE_KMS_KEY_ID TF_SUB_CLAIM_PREFIX; do
  gh secret delete "${name}" --repo "${LODESTAR_REPO}"
done
gh variable delete TF_REGION --repo "${LODESTAR_REPO}"
gh variable delete TF_ZONE --repo "${LODESTAR_REPO}"
```

- A deleted Workload Identity pool or provider is soft-deleted for 30 days, and its id cannot be reused until
  it is purged: to recreate the identity right away, undelete it (`gcloud iam workload-identity-pools undelete`)
  and import it, or pick another `pool_id`.

## 9. Production planner

`envs/prod` has its own read-only planner (its own pool, provider and service account in the production project),
so nothing in the non-production project can read production state. The jobs `plan-prod` in `plan.yml` and
`drift-prod` in `drift.yml` use only the secrets and variable below. Until all of them exist the jobs succeed without
planning and write "Production CI identity not configured yet" to the job summary. The pull-request job plans only
when `envs/prod/`, `bootstrap/prod/`, `modules/`, `scripts/ci-plan.sh`, `scripts/ci-changed.sh` or `plan.yml` changed.

Apply `envs/prod` first (its own runbook), then set these. Where each value comes from:

| Name | Kind | Source |
|---|---|---|
| `TF_PROD_CI_WIF_PROVIDER` | secret | `envs/prod` output `CI_WIF_PROVIDER` |
| `TF_PROD_CI_SA` | secret | `envs/prod` output `CI_SERVICE_ACCOUNT` |
| `TF_PROD_PROJECT_ID` | secret | `envs/prod/terraform.tfvars`, `project_id` |
| `TF_PROD_PROJECT_NUMBER` | secret | tfvars, `project_number` |
| `TF_PROD_BILLING_ACCOUNT` | secret | tfvars, `billing_account` |
| `TF_PROD_SERVICES` | secret | tfvars, `services` as one compact JSON line (below) |
| `TF_PROD_CI_GITHUB_REPOSITORY` | secret | tfvars, `ci_github_repository` |
| `TF_PROD_CI_GITHUB_OWNER_ID` | secret | tfvars, `ci_github_owner_id` |
| `TF_PROD_CI_GITHUB_REPO_ID` | secret | tfvars, `ci_github_repo_id` |
| `TF_PROD_CI_SUB_CLAIM_PREFIX` | secret | tfvars, `ci_sub_claim_prefix` |
| `TF_PROD_STATE_BUCKET` | secret | `bootstrap/prod` output `state_bucket` (also tfvars `state_bucket`) |
| `TF_PROD_STATE_KMS_KEY_ID` | secret | `bootstrap/prod` output `kms_key_id` (also tfvars `state_kms_key_id`) |
| `TF_PROD_REGION` | variable | tfvars, `region` (the region is not identifying) |
| `TF_PROD_NODE_LOCATIONS` | variable | tfvars, `node_locations` as a JSON list |

The planner is not tied to any `apps` value. `TF_PROD_NODE_LOCATIONS` is a variable holding a JSON list of zones, for
example `["europe-west1-b","europe-west1-c"]` (it must equal `node_locations` in your tfvars). `budget_display_name`
and `state_prefix` must keep their defaults, because CI cannot set them. A different `state_prefix` makes CI plan
against an empty state: a full create plan and a drift issue listing every address.

Choose generic service keys in `services` (for example `site`, not a project's real name): the keys appear in resource
addresses and in the pool IDs `gh-<key>`, and they are not masked.

Set the two outputs without printing them. `GH_REPO` must be unset first, or `gh` targets another repository:

```bash
unset GH_REPO
printf '%s' "$(tofu -chdir=envs/prod output -raw CI_WIF_PROVIDER)" | gh secret set TF_PROD_CI_WIF_PROVIDER -R "${LODESTAR_REPO}"
printf '%s' "$(tofu -chdir=envs/prod output -raw CI_SERVICE_ACCOUNT)" | gh secret set TF_PROD_CI_SA -R "${LODESTAR_REPO}"
```

The string keys come from the tfvars file. The function reads one key and pipes it to `gh`:

```bash
set_prod_secret() {
  sed -n "s/^${2} *= *\"\(.*\)\"\$/\1/p" envs/prod/terraform.tfvars | head -n 1 | tr -d '\n' | gh secret set "${1}" -R "${LODESTAR_REPO}"
}
set_prod_secret TF_PROD_PROJECT_ID project_id
set_prod_secret TF_PROD_PROJECT_NUMBER project_number
set_prod_secret TF_PROD_BILLING_ACCOUNT billing_account
set_prod_secret TF_PROD_CI_GITHUB_REPOSITORY ci_github_repository
set_prod_secret TF_PROD_CI_GITHUB_OWNER_ID ci_github_owner_id
set_prod_secret TF_PROD_CI_GITHUB_REPO_ID ci_github_repo_id
set_prod_secret TF_PROD_CI_SUB_CLAIM_PREFIX ci_sub_claim_prefix
set_prod_secret TF_PROD_STATE_BUCKET state_bucket
set_prod_secret TF_PROD_STATE_KMS_KEY_ID state_kms_key_id
```

`services` is a map of objects, so it goes in as one secret holding compact JSON. `tofu console` evaluates the
variable from the tfvars file and `jq -c` makes it one line (GitHub masks a multi-line secret line by line, so a
pretty-printed value would mask `{` and `}`). Nothing is printed:

```bash
printf 'jsonencode(var.services)' | tofu -chdir=envs/prod console | jq -r . | jq -c . | gh secret set TF_PROD_SERVICES -R "${LODESTAR_REPO}"
```

If `tofu console` asks for a backend, run `tofu -chdir=envs/prod init` first. Then the region variable:

```bash
sed -n 's/^region *= *"\(.*\)"$/\1/p' envs/prod/terraform.tfvars | head -n 1 | tr -d '\n' | gh variable set TF_PROD_REGION -R "${LODESTAR_REPO}"
```

If `region` is not in the tfvars, the default is `europe-west1`: set it with `gh variable set TF_PROD_REGION --body europe-west1 -R "${LODESTAR_REPO}"`.
The zones (not identifying):

```bash
gh variable set TF_PROD_NODE_LOCATIONS --body '["europe-west1-b","europe-west1-c"]' -R "${LODESTAR_REPO}"
```

Check the names (never the values):

```bash
gh secret list -R "${LODESTAR_REPO}" | cut -f1 | grep '^TF_PROD_' | sort
gh variable list -R "${LODESTAR_REPO}" | cut -f1 | grep '^TF_PROD_'
```

Expect 12 secrets and 2 variables.

How the logs stay clean: every value is a secret, so GitHub masks it. For `TF_PROD_SERVICES` the job also parses the JSON
with `jq` before any `tofu` command and registers every string and number in it with `::add-mask::`, plus the owner
and the repository of every `<owner>/<repo>` value. The same values go to the literal redaction of error lines,
longest first. The JSON is read from the environment and never echoed; invalid JSON fails the job without printing it.

### First production drift run

```bash
gh workflow run drift.yml -R "${LODESTAR_REPO}"
gh run watch -R "${LODESTAR_REPO}"
```

Expect: the job `Drift envs/prod` succeeds, its summary says `No changes.`, and no issue "Drift detected in envs/prod"
exists. A permission error right after the apply can be IAM propagation: wait and run it again.

### Public-log identifier scan

The repository is public, so scan the finished run's log for every identifier before you trust the setup. The values are
read from the tfvars file and never printed; `grep -F -f` reads the patterns from stdin, and `-c` prints counts only:

```bash
RUN_ID="$(gh run list --workflow drift.yml -R "${LODESTAR_REPO}" --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "${RUN_ID}" -R "${LODESTAR_REPO}" --log > "${TMPDIR:-/tmp}/prod-run.log"
{
  sed -n -e '/^region /d' -e 's/^[a-z_]* *= *"\([^"]\{3,\}\)"$/\1/p' envs/prod/terraform.tfvars
  printf 'jsonencode(var.services)' | tofu -chdir=envs/prod console | jq -r . | jq -r '.. | strings | select(length > 2) | (., (select(test("^[^/]+/[^/]+$")) | split("/")[]))'
} | grep -F -f - -c "${TMPDIR:-/tmp}/prod-run.log"
rm -f "${TMPDIR:-/tmp}/prod-run.log"
```

Expect `0`. Any other number is a leak: delete the run (`gh run delete`), rotate what leaked, and fix the masking before
the next run. The `region` line is left out because the plan step always prints it (it is not identifying). A dotted
repository name appears regex-escaped (`\\.`) inside the provider's attribute condition, so an error line quoting that
condition is masked on the escaped form only if the job registered it: the job masks the plain and the escaped forms,
and the scan above would not find the escaped one, so also run `grep -c` for each dotted name written with `\.`.

### Rollback of the production planner

Delete the 12 secrets and the 2 variables:

```bash
for name in TF_PROD_CI_WIF_PROVIDER TF_PROD_CI_SA TF_PROD_PROJECT_ID TF_PROD_PROJECT_NUMBER TF_PROD_BILLING_ACCOUNT TF_PROD_SERVICES TF_PROD_CI_GITHUB_REPOSITORY TF_PROD_CI_GITHUB_OWNER_ID TF_PROD_CI_GITHUB_REPO_ID TF_PROD_CI_SUB_CLAIM_PREFIX TF_PROD_STATE_BUCKET TF_PROD_STATE_KMS_KEY_ID; do
  gh secret delete "${name}" -R "${LODESTAR_REPO}"
done
gh variable delete TF_PROD_REGION -R "${LODESTAR_REPO}"
gh variable delete TF_PROD_NODE_LOCATIONS -R "${LODESTAR_REPO}"
```

The production jobs then skip with the "not configured yet" notice.
