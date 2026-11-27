# CI identity runbook: PR plans and weekly drift (task L1.7)

You run every command here yourself. Nothing in this repository applies anything on its own.
Commands work in bash and zsh. Run them from the repository root, in the same terminal, in order.

What this does: gives this repository's CI a read-only, keyless identity, so that:

- every pull request that touches `envs/`, `modules/` or the plan workflow shows a plan summary in its job
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
printf 'export LODESTAR_REPO="%s"\n' "${LODESTAR_REPO}" >> ~/gke-setup.env
printf 'export LODESTAR_REPO_ID="%s"\n' "${LODESTAR_REPO_ID}" >> ~/gke-setup.env
printf 'export LODESTAR_SUB_PREFIX="%s"\n' "${LODESTAR_SUB_PREFIX}" >> ~/gke-setup.env
```

## 2. Add the three variables

```bash
printf 'ci_github_repository = "%s"\n' "${LODESTAR_REPO}" >> envs/apps/terraform.tfvars
printf 'ci_github_repo_id    = "%s"\n' "${LODESTAR_REPO_ID}" >> envs/apps/terraform.tfvars
printf 'ci_sub_claim_prefix  = "%s"\n' "${LODESTAR_SUB_PREFIX}" >> envs/apps/terraform.tfvars
```

`terraform.tfvars` is git-ignored: never commit it.

## 3. Plan

```bash
git pull
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=ci-identity.tfplan
```

## 4. Acceptance

The `Plan:` line must read (with `-out`, the notes on outputs and the saved plan follow it):

```text
Plan: 11 to add, 0 to change, 0 to destroy.
```

The 11 adds, and nothing else:

- `module.ci_planner.google_iam_workload_identity_pool.ci`
- `module.ci_planner.google_iam_workload_identity_pool_provider.ci`
- `module.ci_planner.google_service_account.planner`
- 2 x `module.ci_planner.google_service_account_iam_member.wif[...]` (one per subject: `...:pull_request` and `...:ref:refs/heads/main`)
- 3 x `module.ci_planner.google_project_iam_member.planner[...]` (`roles/viewer`, `roles/iam.securityReviewer`, `roles/serviceusage.serviceUsageConsumer`)
- `module.ci_planner.google_storage_bucket_iam_member.state`
- `module.ci_planner.google_kms_crypto_key_iam_member.state`
- `module.ci_planner.google_billing_account_iam_member.viewer`

Two mechanical checks:

```bash
tofu -chdir=envs/apps show -no-color ci-identity.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|will be updated|to change|to destroy'
```

Only the summary line (`... 0 to change, 0 to destroy.`) may match.

```bash
tofu -chdir=envs/apps show -no-color ci-identity.tfplan | grep -E '^  # .* will be ' | sort
```

Expect exactly 11 lines, all `will be created`, all starting with `module.ci_planner.`, matching the list above.

### HARD STOP

> If the summary says anything but `11 to add, 0 to change, 0 to destroy`, if any other address appears, if
> any line says `must be replaced` or `will be destroyed`, or if one of the three role lists differs: DO NOT
> APPLY. Delete the plan file (`rm -f envs/apps/ci-identity.tfplan`), stop and paste the plan.

## 5. Apply

```bash
tofu -chdir=envs/apps apply ci-identity.tfplan
rm -f envs/apps/ci-identity.tfplan
tofu -chdir=envs/apps plan
```

The last command must print `No changes. Your infrastructure matches the configuration.`

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

Check that all sixteen secrets exist (names only):

```bash
gh secret list --repo "${LODESTAR_REPO}" | cut -f1 | sort
```

Expect these 16 names: `GCP_CI_SA`, `GCP_CI_WIF_PROVIDER`, `TF_BILLING_ACCOUNT`, `TF_BUDGET_DISPLAY_NAME`,
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

A pull request that touches `envs/`, `modules/`, `scripts/ci-plan.sh` or `plan.yml` now shows its plan
summary in the job summary of the `Plan` workflow.

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
