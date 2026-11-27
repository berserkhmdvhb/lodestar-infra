# Operations: OpenTofu, live-config export, state, import, hardening and the CI identity

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

## 10. Read-only live-config export

Run from: anywhere, env file sourced. Goal: a private snapshot of the hand-built setup, the input for writing
and checking the OpenTofu code. Every command only reads; the files hold IDs, so the folder is private.

🔍 ✏️ (writes files in `~/platform-config/live`, mode `600`)

```bash
source ~/gke-setup.env
D="${HOME}/platform-config/live"; mkdir -p "${D}" && chmod 700 "${D}"

gcloud container clusters describe "${CLUSTER}" --location="${ZONE}" --format=yaml > "${D}/cluster.yaml"
gcloud container node-pools describe default-pool --cluster="${CLUSTER}" --location="${ZONE}" --format=yaml > "${D}/node-pool.yaml"
gcloud compute networks describe "${NETWORK}" --format=yaml > "${D}/network.yaml"
gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" --format=yaml > "${D}/subnet.yaml"
gcloud compute routers describe apps-router --region="${REGION}" --format=yaml > "${D}/router.yaml"
gcloud iam workload-identity-pools providers describe github-oidc --location=global \
  --workload-identity-pool=github --format=yaml > "${D}/wif-provider.yaml"
gcloud secrets describe "${SERVICE_NAME}-dev-db-user" --format=yaml > "${D}/secret-sample.yaml"

BILLING_ACCOUNT="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingAccountName)' | cut -d/ -f2)"
gcloud billing budgets list --billing-account="${BILLING_ACCOUNT}" --format=yaml > "${D}/budget.yaml"

chmod 600 "${D}"/*.yaml && ls -l "${D}"
```

Expect: eight files, each `-rw-------`. The secret export is metadata only (name, replication, labels), never a
value. Run the whole block: a paste that leaves out the first lines leaves `D` undefined, and the
`> "${D}/..."` redirects then fail. The budget file is also where section 11 reads the budget's ID.


---

## 11. OpenTofu: state, import, apply

Run from: this repository's root. Needs: ADC and the quota project (2.5), the tools (1.2), and the live export
(section 10). Every command here is run by hand; CI never holds credentials and never applies.

Concepts:

- **State** is OpenTofu's record of which real resource each block of code owns. It is a file; whoever
  holds it holds sensitive data.
- **Remote state** here is a versioned GCS bucket. **State encryption** (`gcp_kms` key provider plus the
  `aes_gcm` method) encrypts the state and the plan files with a Cloud KMS key *before* they are written, so
  even a reader of the bucket sees only `encrypted_data`.
- The **bootstrap root** creates that bucket and key. It starts with local state (nothing to store the state
  in yet), then migrates it into the bucket it created.
- The **fallback** (`unencrypted` method) lets the first migration read the old plain state. It is removed in
  the final form, which also sets `enforced = true`, so OpenTofu refuses to read or write plain state.
- **`import` blocks** (`envs/apps/imports.tf`) tell OpenTofu "this existing resource is that block". A plan
  with imports changes nothing in the cloud; applying the plan only writes state.
- **Saved plans** (`-out=file`) are reviewed, then applied by name, so what runs is exactly what you read.
- **Drift** is any difference between the code, the state and the real resource. `tofu plan` showing
  `No changes` after the import is the proof there is none.

### 11.1 Prepare the budget values and the bootstrap variables

🔍 ✏️ (writes the git-ignored `bootstrap/terraform.tfvars`)

```bash
make tools
export PATH="${PWD}/.tools/bin:${PATH}"
tofu version

source ~/gke-setup.env
printf 'project=%s region=%s zone=%s\n' "${PROJECT_ID}" "${REGION}" "${ZONE}"

grep -c '^name:' ~/platform-config/live/budget.yaml
BUDGET_NAME="$(sed -n 's/^name: //p' ~/platform-config/live/budget.yaml)"
BILLING_ACCOUNT="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f2)"
BUDGET_ID="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f4)"
BUDGET_DISPLAY_NAME="$(sed -n 's/^displayName: //p' ~/platform-config/live/budget.yaml | sed "s/^['\"]//; s/['\"]\$//")"
printf 'account=%s id=%s name=%s\n' "${BILLING_ACCOUNT}" "${BUDGET_ID}" "${BUDGET_DISPLAY_NAME}"

cat > bootstrap/terraform.tfvars <<EOF
project_id        = "${PROJECT_ID}"
state_bucket_name = "${PROJECT_ID}-tofu-state"
EOF
```

Expect: `1` from the `grep -c` (the parsing below assumes exactly one budget on the billing account; with
more, trim the export to the right one first), then all three budget values print non-empty (`name` has the form
`billingAccounts/<account>/budgets/<id>`). The bucket name must be globally unique; if the apply later says it
is taken, choose another in `bootstrap/terraform.tfvars`, plan again and apply the new plan. Never commit a `*.tfvars` file.

### 11.2 Plan and apply the bootstrap (local state)

✏️ `init` downloads providers; `plan -out` writes the saved plan (no change); `apply` creates the key ring,
key, bucket and three APIs.

```bash
tofu -chdir=bootstrap init
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
```

Expect: `Plan: 6 to add, 0 to change, 0 to destroy.` (the APIs `cloudkms`, `storage`, `serviceusage`; key ring,
key, bucket). Read it, then apply exactly that plan:

✏️

```bash
tofu -chdir=bootstrap apply bootstrap.tfplan
rm -f bootstrap/bootstrap.tfplan
```

Pitfall: the plan file is in `bootstrap/`. `tofu apply "bootstrap.tfplan"` from the repository root, without
`-chdir=bootstrap`, fails to find it. A second apply of a deleted plan file also fails; plan again. If the
apply reports `SERVICE_DISABLED` for Cloud KMS right after the API was enabled, wait a minute, plan
again into a new file and apply that file: the saved plan was deleted, and is stale after a partial apply. The key ring, key and bucket have `prevent_destroy`: key rings can never be deleted in Cloud KMS.

### 11.3 Migrate the bootstrap's own state into the bucket, encrypted

✏️ Read the bucket and key, write the migration form of `bootstrap/override.tf` (git-ignored), and migrate.
`override.tf` has the backend and the encryption block, with the plain fallback.

```bash
BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket)"
KEY="$(tofu -chdir=bootstrap output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"

cat > bootstrap/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap"
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = "${KEY}"
      key_length         = 32
    }

    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }

    method "unencrypted" "migrate" {}

    state {
      method = method.aes_gcm.state
      fallback {
        method = method.unencrypted.migrate
      }
    }

    plan {
      method = method.aes_gcm.state
      fallback {
        method = method.unencrypted.migrate
      }
    }
  }
}
EOF
tofu -chdir=bootstrap init -migrate-state
```

Answer `yes` to copying the state to the new backend.

🔍 Proof 1: the object in the bucket is encrypted.

```bash
gcloud storage cat "gs://${BUCKET}/bootstrap/default.tfstate" --project "${PROJECT_ID}" | grep -c encrypted_data
gcloud storage cat "gs://${BUCKET}/bootstrap/default.tfstate" --project "${PROJECT_ID}" | grep -c '"resources"'
```

Expect: a count of `1` or more for `encrypted_data`, and `0` for `"resources"`. If it is plain JSON, keep the
fallback, run `tofu -chdir=bootstrap apply` (expect `No changes`; it saves the state again with the new
method) and check again.

✏️ Write the final form: no fallback, no `unencrypted` method, encryption enforced.

```bash
cat > bootstrap/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap"
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = "${KEY}"
      key_length         = 32
    }

    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
EOF
tofu -chdir=bootstrap plan
```

🔍 Proof 2: expect `No changes`. Without the fallback OpenTofu refuses plain state, so this also proves the
state is encrypted. Only then delete the old local copies, and back up the only record of the backend:

✏️

```bash
rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
cp bootstrap/override.tf ~/platform-config/bootstrap-override.tf
chmod 600 ~/platform-config/bootstrap-override.tf
ls -la bootstrap/ | grep -E 'tfstate|override'
```

Expect: only `override.tf` is listed (no `tfstate`). Why the backup: `override.tf` is git-ignored and holds the bucket
name; if it is lost, the state in the bucket cannot be found again by the code.

### 11.4 The import plan

✏️ Writes the git-ignored `envs/apps/terraform.tfvars`, initialises, and writes the saved import plan (no
change in the cloud).

```bash
tofu -chdir=bootstrap plan

STATE_BUCKET="${BUCKET}"
STATE_KMS_KEY_ID="${KEY}"

cat > envs/apps/terraform.tfvars <<EOF
project_id          = "${PROJECT_ID}"
project_number      = "${PROJECT_NUMBER}"
region              = "${REGION}"
zone                = "${ZONE}"
github_repository   = "${GH_REPO}"
github_owner_id     = "${GH_OWNER_ID}"
github_repo_id      = "${GH_REPO_ID}"
sub_claim_prefix    = "${SUB_PREFIX}"
billing_account     = "${BILLING_ACCOUNT}"
budget_display_name = "${BUDGET_DISPLAY_NAME}"
budget_id           = "${BUDGET_ID}"
state_bucket        = "${STATE_BUCKET}"
state_kms_key_id    = "${STATE_KMS_KEY_ID}"
EOF
grep -c '""' envs/apps/terraform.tfvars
git status --porcelain envs/apps

tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=import.tfplan
```

Expect: `No changes` for the bootstrap plan; `0` from the `grep` (no empty value); nothing from `git status`
(the tfvars file is ignored); then a plan ending in
`Plan: 41 to import, 0 to add, N to change, 0 to destroy.` with at most 10 in-place updates. The owner's
actual run said `41 to import, 0 to add, 1 to change, 0 to destroy`: only the cluster's state-only labels
changed, and the APIs showed no change.

**Pitfall: Service Usage 403.** If the plan ends in errors with
`403 ... serviceusage.googleapis.com ... SERVICE_DISABLED`, the Service Usage API is not enabled in the
project (or has not propagated yet). The root bills its requests to the project (`user_project_override`),
so the nine `google_project_service` reads fail without it. The current bootstrap already enables it (it is
among the 6 additions of 11.2), so today this means the bootstrap apply was skipped or has not propagated: wait
2 to 3 minutes. The owner's first plan failed this way because his bootstrap had been applied *before* that API
was added to it. A plan that ends in errors must never be applied: delete it. Only for a bootstrap applied
before the fix, add the API through the bootstrap root and plan again:

✏️

```bash
rm -f envs/apps/import.tfplan
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
tofu -chdir=bootstrap show -no-color bootstrap.tfplan | grep -E '# .* will be|^Plan:'
```

Expect (for that older bootstrap only): exactly one addition,
`google_project_service.apis["serviceusage.googleapis.com"]`, `Plan: 1 to add`.
Apply that saved plan, delete it, and wait for the API to propagate before planning `envs/apps` again:

✏️

```bash
tofu -chdir=bootstrap apply bootstrap.tfplan
rm -f bootstrap/bootstrap.tfplan

sleep 180
gcloud services list --enabled --project "${PROJECT_ID}" --filter='config.name=serviceusage.googleapis.com' --format='value(config.name)'
```

Expect: `serviceusage.googleapis.com`. If the apply of a saved plan finds no file (it was deleted after an earlier apply), or the API is not yet
visible, plan again into a new file.

### 11.5 Two mechanical checks on the saved plan

✏️ (writes a saved plan file locally; nothing in the cloud) 🔍 Both checks must pass before any apply. The
first must match only the summary line.

```bash
tofu -chdir=envs/apps plan -out=import.tfplan
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE '^ *[-+~] |will be updated in-place'
```

Expect, check 1: one line only, the summary `... 0 to destroy.` A line saying `must be replaced`, `-/+`
or `will be destroyed` is a **hard stop**: do not apply; paste the plan to someone who can read it.

Expect, check 2, and nothing else: the legend line `~ update in-place`; at most 10 `will be updated in-place`
headers (9 `google_project_service` and 1 `google_container_cluster`); under each API that appears a
`~ disable_dependent_services` and a `~ disable_on_destroy` line; under the cluster a
`~ resource_labels = {` and a `~ terraform_labels = {` line, each followed by `+ "cluster" = "apps"`. These
are provider-side or state-only fields; applying them does not change Google Cloud. In the owner's run only the
cluster line appeared (`1 to change`) and the APIs showed no change.

The summary also lists what is imported: 9 APIs, 4 network, 2 node service account, 11 Workload Identity, 5
conditional secret accessors, 7 secrets, 1 budget, 2 cluster and pool: 41 in all. Any other changed
attribute (for example a node pool `kubelet_config`) is a stop.

### 11.6 Apply the import, then prove "No changes"

✏️ Writes state only. Nothing is created or deleted in Google Cloud.

```bash
tofu -chdir=envs/apps apply import.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 41 imported, 0 added, N changed, 0 destroyed.` (N was 1 in the owner's run) and then
`No changes. Your infrastructure matches the configuration.` Anything else: stop.

✏️ Delete the plan file.

```bash
rm -f envs/apps/import.tfplan
```

### 11.7 Three live checks

🔍 The cluster is still healthy.

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(status,releaseChannel.channel,controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic,privateClusterConfig.enablePrivateNodes)'
```

Expect: `status: RUNNING`, channel `STABLE`, external traffic allowed on the DNS endpoint, private nodes on.

🔍 The provider's condition still pins your IDs and the workflow file.

```bash
actual="$(gcloud iam workload-identity-pools providers describe github-oidc \
  --project "${PROJECT_ID}" --location=global --workload-identity-pool=github --format='value(attributeCondition)')"
[[ "${actual}" == *"repository_owner_id=='${GH_OWNER_ID}'"* && "${actual}" == *"repository_id=='${GH_REPO_ID}'"* && "${actual}" == *"deploy-ops"* ]] \
  && printf 'condition matches\n' || printf 'DIFFERENT: compare by eye\n'
```

🔍 Each deployer can be impersonated only by its own environment.

```bash
for env in dev qa production; do
  printf '%s: ' "${env}"
  gcloud iam service-accounts get-iam-policy "gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project "${PROJECT_ID}" --format='value(bindings.members)'
done
```

Expect: each line ends with `/subject/<SUB_PREFIX>:environment:<env>` for its own environment and has no other
member.

### 11.8 Rollback of the import

Nothing in Google Cloud changed, so to undo, remove the resources from state (`state rm` never deletes
anything in the cloud) and start again at 11.4:

✏️ (state only)

```bash
tofu -chdir=envs/apps state list
for m in project network node_sa github_wif secrets budget gke; do
  tofu -chdir=envs/apps state rm "module.${m}"
done
```

The outputs (`GCP_PROJECT_ID`, `GKE_CLUSTER`, `GKE_LOCATION`, `GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SA`,
`dns_endpoint`) are the GitHub variables of 9.1; read them with `tofu -chdir=envs/apps output`.

**From here on, the resources of sections 2 to 6, 8.2 and the secret containers of 8.4 are managed by OpenTofu in `envs/apps`: change the
code and plan; do not change them by hand.** A manual change shows up as drift in the next `plan`.


---

## 12. OpenTofu: GKE hardening

Run from: this repository's root, in the terminal of section 11 (or re-source the env file and set the `PATH`).
Goal: the first change to live resources after the import, all in place: Secrets encrypted with a Cloud KMS
key, new RBAC bindings to the all-users groups (`system:authenticated`, `system:unauthenticated`) refused, VPC flow logs, and Data Access audit logs for the container
API. The detail and the acceptance rules are in [`hardening-runbook.md`](../hardening-runbook.md); this is the
command sequence as it was run.

### 12.1 Plan, and the two checks

✏️ (writes a saved plan; changes nothing in the cloud)

```bash
export PATH="${PWD}/.tools/bin:${PATH}"
source ~/gke-setup.env
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

🔍

```bash
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE '^ *[-~] |will be |^ *\+ (log_config|key_name)'
```

Expect: `Plan: 4 to add, 2 to change, 0 to destroy.` The 4 additions are the KMS key ring, the key, the
key's grant to GKE's service agent, and the project's container audit config. The 2 in-place changes are the
cluster (`database_encryption` `DECRYPTED` to `ENCRYPTED` with a known key name, and the two
`rbac_binding_config` switches `true` to `false`) and the subnet (a `log_config` block added). The first check
may match only the summary; anything else is a hard stop. No line may start with `-`.

### 12.2 Apply, then plan again

Before applying: enabling Secrets encryption **restarts the cluster control plane**. On a zonal cluster the
control plane is unavailable meanwhile: running Pods keep serving, but `kubectl`, CI deploys, External Secrets
syncs and the autoscaler pause until it is back (an estimate: 10 to 30 minutes, not a promise). Pick a quiet
window and start no deploys.

✏️ Changes the live cluster, subnet and project IAM.

```bash
tofu -chdir=envs/apps apply hardening.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 4 added, 2 changed, 0 destroyed.` then `No changes.`

If the apply fails after the four creations (for example while the new KMS grant propagates), the saved plan
is stale. Delete it, wait, and plan into a new file. Review with 12.1 (now `0 to add, 2 to change, 0 to
destroy` with the same two changes) and apply that file:

✏️

```bash
rm -f envs/apps/hardening.tfplan
sleep 180
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

### 12.3 Verify against the live setup

🔍

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(databaseEncryption,rbacBindingConfig,securityPostureConfig)'
gcloud compute networks subnets describe apps-subnet --region "${REGION}" --project "${PROJECT_ID}" --format='yaml(logConfig)'
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json \
  | python3 -c 'import json,sys; [print(c["service"], sorted(l["logType"] for l in c["auditLogConfigs"])) for c in json.load(sys.stdin).get("auditConfigs", []) if c["service"] == "container.googleapis.com"]'
{ kubectl get clusterrolebindings -o json; kubectl get rolebindings -A -o json; } \
  | jq -r '.items[] | select(any(.subjects[]?; .name == "system:authenticated" or .name == "system:unauthenticated" or .name == "system:anonymous")) | "\(.kind) \(.metadata.namespace // "-") \(.metadata.name)"'
```

Expect: `databaseEncryption.state: ENCRYPTED`, both RBAC switches `false`, posture `BASIC`; flow logs enabled
(10-minute interval, sampling 0.1); `container.googleapis.com ['ADMIN_READ', 'DATA_WRITE']`; and only the
three built-in bindings `system:basic-user`, `system:discovery`, `system:public-info-viewer`. The RBAC switches
block only *new* bindings; they do not remove existing ones, which is why the last command lists them.

✏️ Clean up.

```bash
rm -f envs/apps/hardening.tfplan
```

Rollback and the one allowed destroy (the audit config) are in the hardening runbook. Never destroy the KMS
key or ring (`prevent_destroy`).

### 12.4 The CI identity (L1.7), as run on 2026-11-27

Run from: this repository's root, in the terminal of section 11. Goal: a read-only, keyless identity so that pull
requests show a plan summary and a weekly run plans `main` against the live project. The reasons, the limits of
the identity and the rollback are in [`ci-identity-runbook.md`](../ci-identity-runbook.md); this is the command
sequence as it was run.

**Cloud Billing pre-check.** The identity reads the billing account, and the provider bills such calls to the
project (`user_project_override`), so the Cloud Billing API must be on in the project. The `ci_planner` module
enables it (`google_project_service.cloudbilling`); the first plan of the identity failed with `SERVICE_DISABLED`
before that resource existed. Enabling an enabled API succeeds, so the pre-check only tells you what to expect.

🔍

```bash
source ~/gke-setup.env
gcloud services list --enabled --project "${PROJECT_ID}" --filter='config.name=cloudbilling.googleapis.com' --format='value(config.name)'
```

Expect: empty output (the plan enables it), or the name when it is already on. Both are fine.

**The IDs and the immutable prefix.**

🔍

```bash
unset GH_REPO
export LODESTAR_REPO="${GH_OWNER}/lodestar-infra"
export LODESTAR_REPO_ID="$(gh api "repos/${LODESTAR_REPO}" --jq .id)"
export LODESTAR_SUB_PREFIX="$(gh api "repos/${LODESTAR_REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
printf '%s\n' "${LODESTAR_REPO_ID}" "${LODESTAR_SUB_PREFIX}"
```

Expect: a number, then `repo:<owner>@<number>/lodestar-infra@<number>`. If the second line is empty, build the
immutable form from the IDs as the CI identity runbook (step 1) shows.

**The tfvars lines, appended once.**

✏️ Local files only.

```bash
grep -q '^ci_github_repository ' envs/apps/terraform.tfvars || printf 'ci_github_repository = "%s"\n' "${LODESTAR_REPO}" >> envs/apps/terraform.tfvars
grep -q '^ci_github_repo_id ' envs/apps/terraform.tfvars || printf 'ci_github_repo_id    = "%s"\n' "${LODESTAR_REPO_ID}" >> envs/apps/terraform.tfvars
grep -q '^ci_sub_claim_prefix ' envs/apps/terraform.tfvars || printf 'ci_sub_claim_prefix  = "%s"\n' "${LODESTAR_SUB_PREFIX}" >> envs/apps/terraform.tfvars
tofu fmt envs/apps/terraform.tfvars
```

Expect: `tofu fmt` prints the file name only when it changed it. A block run twice without the `grep -q` guards
appends every key twice, and the next plan stops with `Attribute redefined`. To repair such a file, keep the
first occurrence of each key:

✏️ Local files only.

```bash
awk -F' *= *' 'NF < 2 || !seen[$1]++' envs/apps/terraform.tfvars > envs/apps/terraform.tfvars.new
mv envs/apps/terraform.tfvars.new envs/apps/terraform.tfvars
tofu fmt envs/apps/terraform.tfvars
```

Expect: no output from the `awk` and `mv` lines; each key once (`grep -c '^ci_' envs/apps/terraform.tfvars` prints 3).

**Plan, apply, "No changes".**

✏️ (writes a saved plan; changes nothing in the cloud)

```bash
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=ci-identity.tfplan
```

Expect: `Plan: 12 to add, 0 to change, 0 to destroy.` The 12 adds are listed, with the two mechanical checks, in the CI
identity runbook (step 4). Anything else is a hard stop.

✏️ Changes the live project, its IAM and the billing account's IAM.

```bash
tofu -chdir=envs/apps apply ci-identity.tfplan
rm -f envs/apps/ci-identity.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 12 added, 0 changed, 0 destroyed.` then `No changes.`

**The 16 secrets and the 2 variables.**

🔐 Each value goes from OpenTofu's output or `terraform.tfvars` straight into `gh`; nothing is printed.

```bash
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_WIF_PROVIDER)" | gh secret set GCP_CI_WIF_PROVIDER --repo "${LODESTAR_REPO}"
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_SERVICE_ACCOUNT)" | gh secret set GCP_CI_SA --repo "${LODESTAR_REPO}"
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
gh variable set TF_REGION --body "${REGION}" --repo "${LODESTAR_REPO}"
gh variable set TF_ZONE --body "${ZONE}" --repo "${LODESTAR_REPO}"
```

🔍

```bash
gh secret list --repo "${LODESTAR_REPO}" | cut -f1 | sort | wc -l
gh variable list --repo "${LODESTAR_REPO}" | cut -f1 | sort
```

Expect: `16`, then `TF_REGION` and `TF_ZONE`.

**The first drift run, and the scan of its public log.** The repository is public, so its Actions log is public.
Before trusting the setup, count the occurrences of each identifying value in the log. The values are read from
`terraform.tfvars` and never printed; only the count per key name is.

✏️ Starts a workflow run (read-only against the project).

```bash
gh workflow run drift.yml --repo "${LODESTAR_REPO}"
sleep 10
gh run watch "$(gh run list --workflow drift.yml --limit 1 --json databaseId --jq '.[0].databaseId' --repo "${LODESTAR_REPO}")" --repo "${LODESTAR_REPO}"
```

Expect: the run succeeds with `Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace.` and `No changes.` in its job
summary, and no drift issue is opened.

🔍

```bash
LOG="$(mktemp)"
gh run view "$(gh run list --workflow drift.yml --limit 1 --json databaseId --jq '.[0].databaseId' --repo "${LODESTAR_REPO}")" --log --repo "${LODESTAR_REPO}" > "${LOG}"
for key in project_id project_number billing_account budget_id state_bucket state_kms_key_id github_owner_id github_repo_id ci_github_repo_id; do
  value="$(sed -n "s/^${key} *= *\"\(.*\)\"\$/\1/p" envs/apps/terraform.tfvars | head -n 1)"
  printf '%s: %s\n' "${key}" "$(grep -cF -- "${value}" "${LOG}")"
done
rm -f "${LOG}"
```

Expect: `0` for every key (GitHub shows each secret as `***`). Any other number is a leak: delete the run
(`gh run delete`), then find the step that printed it before running again.

