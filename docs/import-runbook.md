# Import runbook: bring the hand-built setup under OpenTofu

You run every command here yourself. Nothing in this repository applies anything on its own.
Commands work in bash and zsh. Run them from the repository root, in the same terminal, in order.

What this does: `envs/apps` describes the cluster you built by hand with the guides. An import
puts each existing resource into OpenTofu's state and changes nothing in Google Cloud. The plan
must say it imports and creates, replaces and destroys nothing.

## 0. Prerequisites

```bash
make tools
export PATH="${PWD}/.tools/bin:${PATH}"
tofu version                                   # OpenTofu v1.13.9

source ~/gke-setup.env                         # PROJECT_ID, PROJECT_NUMBER, REGION, ZONE, GH_*, SUB_PREFIX
gcloud auth application-default login
gcloud auth application-default set-quota-project "${PROJECT_ID}"
printf 'project=%s region=%s zone=%s\n' "${PROJECT_ID}" "${REGION}" "${ZONE}"
```

The budget's id, billing account and name come from your live export (`name` has the form
`billingAccounts/<account>/budgets/<id>`):

```bash
BUDGET_NAME="$(sed -n 's/^name: //p' ~/platform-config/live/budget.yaml)"
BILLING_ACCOUNT="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f2)"
BUDGET_ID="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f4)"
BUDGET_DISPLAY_NAME="$(sed -n 's/^displayName: //p' ~/platform-config/live/budget.yaml | sed "s/^['\"]//; s/['\"]\$//")"
printf 'account=%s id=%s name=%s\n' "${BILLING_ACCOUNT}" "${BUDGET_ID}" "${BUDGET_DISPLAY_NAME}"
```

All three must print a value. The tfvars files you write below are git-ignored; never commit them.

## 1. Bootstrap once: the state bucket and key

```bash
cat > bootstrap/terraform.tfvars <<EOF
project_id        = "${PROJECT_ID}"
state_bucket_name = "${PROJECT_ID}-tofu-state"
EOF
tofu -chdir=bootstrap init
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
```

Expected: `Plan: 6 to add, 0 to change, 0 to destroy.` (3 APIs: cloudkms, storage, serviceusage; key ring, key, bucket) and nothing else.
Review it, then apply exactly that plan:

```bash
tofu -chdir=bootstrap apply bootstrap.tfplan
rm -f bootstrap/bootstrap.tfplan
```

If you applied the bootstrap before `serviceusage.googleapis.com` was added, `tofu -chdir=bootstrap plan -out=bootstrap.tfplan`
now shows exactly `1 to add` (`google_project_service.apis["serviceusage.googleapis.com"]`). Apply that saved plan,
delete it, and wait 2-3 minutes for the API to propagate before step 2.

If the apply fails with `SERVICE_DISABLED` right after the Cloud KMS API was enabled, wait a minute and
run the apply again (plan again first if the saved plan was deleted). If it fails on the bucket name (a
plan cannot detect a taken name), choose another `state_bucket_name` in `bootstrap/terraform.tfvars` and
apply again; the key ring and key already exist and stay (key rings are permanent).

### Move bootstrap's own state into the bucket, encrypted

Until now the bootstrap state is a plain local file. Every command runs from the repository root.

```bash
BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket)"
KEY="$(tofu -chdir=bootstrap output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"
```

Both must print a value. Write the migration form (it can still read the plain state):

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

Answer `yes` to copying the state to the new backend. Proof that the object in the bucket is encrypted:

```bash
gcloud storage cat "gs://${BUCKET}/bootstrap/default.tfstate" --project "${PROJECT_ID}" | head -c 300
```

It must show `encrypted_data` and no `resources`. If it shows plain JSON: keep the fallback, run
`tofu -chdir=bootstrap apply` (expect `No changes`; it saves the state again with the new method), and
check again.

Now write the final form (no fallback, no `unencrypted` method, encryption enforced):

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

It must say `No changes`. Without the fallback OpenTofu refuses plain state, so this is a second proof.
Only then delete the old local copies:

```bash
rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
```

`bootstrap/override.tf` is now the only record of the backend. It is git-ignored, so keep it (or back it
up to `~/platform-config`).

Read the two values for step 2:

```bash
STATE_BUCKET="${BUCKET}"
STATE_KMS_KEY_ID="${KEY}"
```

## 2. The import plan

```bash
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

tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=import.tfplan
```

A 403 `SERVICE_DISABLED` for `serviceusage.googleapis.com` means the bootstrap apply above was skipped or has
not propagated yet. A plan that ends in errors must never be applied: delete it with `rm -f envs/apps/import.tfplan`.

The saved plan is `envs/apps/import.tfplan`. It is encrypted, and `*.tfplan` is git-ignored. Delete it when
you are done.

### Acceptance

The last lines must read:

```text
Plan: 41 to import, 0 to add, N to change, 0 to destroy.
```

- 41 imports: 9 APIs, 4 network, 2 node service account, 11 Workload Identity (pool, provider, 3
  service accounts, 3 impersonation members, 3 cluster-viewer members), 5 conditional secret
  accessors, 7 secrets, 1 budget, 2 cluster and pool.
- `0 to add` and `0 to destroy`, exactly.
- `N to change` is at most 10 in-place updates: 9 `google_project_service` (`disable_on_destroy`,
  `disable_dependent_services`) and 1 `google_container_cluster` (`resource_labels` and
  `terraform_labels` gaining `"cluster" = "apps"`). `deletion_protection` does not appear (the importer
  sets it to true). These are provider-side or state-only fields; applying them does not change the
  cluster in Google Cloud.
- A "to change" line on anything else, or on any other attribute, is a stop: paste the plan.

### HARD STOP

> If any line says `must be replaced`, `-/+`, `will be destroyed`, or the summary says anything but
> `0 to destroy`: DO NOT APPLY. Stop and paste the plan.

Check with:

```bash
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
```

Only the summary line (`... 0 to destroy.`) may match. Anything else is a hard stop.

Then check every changed attribute of the saved plan:

```bash
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE '^ *[-+~] |will be updated in-place'
```

Expected, and nothing else:

- the legend line `~ update in-place`;
- 10 `will be updated in-place` lines, each with a `~ resource` header: 9 `google_project_service`
  and 1 `google_container_cluster`;
- under each API: a `~ disable_dependent_services` line and a `~ disable_on_destroy` line;
- under the cluster: a `~ resource_labels = {` line and a `~ terraform_labels = {` line, each followed by
  `+ "cluster" = "apps"`.

Any other line: stop and paste the plan.

### Possible differences to expect in the cluster and pool (each means stop and paste)

These come from the GKE module review: the live cluster was made with `gcloud`, which sets values the
module may not state.

| Where in the plan | What it looks like | Why |
| --- | --- | --- |
| Node pool `kubelet_config` | `- kubelet_config { ... }` or `+ kubelet_config { ... }` (for example `cpu_cfs_quota`, `pod_pids_limit`) | GKE fills defaults the module leaves unset |
| Node pool `network_config`, `max_pods_per_node` | `~ network_config { ... }` or `~ max_pods_per_node` (often `forces replacement`) | create-time settings that cannot change in place |
| Cluster `ip_endpoints_config` sub-fields | `~ ip_endpoints_config { ... }` with `enabled`, `private_endpoint_enforcement_enabled`, `global_access` | the public endpoint is on and private enforcement is reported back |

Do not edit the modules to silence one yourself. Paste the plan section; the fix is a deliberate change.

## 3. Apply the saved plan, then plan again

Only if step 2 passed every check above:

```bash
tofu -chdir=envs/apps apply import.tfplan
```

Expected: `Apply complete! Resources: 41 imported, 0 added, N changed, 0 destroyed.` This writes state and
imports only. Nothing is created or deleted in Google Cloud. Then:

```bash
tofu -chdir=envs/apps plan
```

Expected: `No changes. Your infrastructure matches the configuration.` Anything else: stop and paste it.

```bash
tofu -chdir=envs/apps output
rm -f envs/apps/import.tfplan
```

The outputs (`GCP_PROJECT_ID`, `GKE_CLUSTER`, `GKE_LOCATION`, `GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SA`,
`dns_endpoint`) are the GitHub variables from Platform Setup.

## 4. Three quick checks against the live setup

The cluster, in place and healthy:

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(status,releaseChannel.channel,controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic,privateClusterConfig.enablePrivateNodes)'
```

Expect `status: RUNNING`, channel `STABLE`, external traffic allowed on the DNS endpoint, private nodes on.

The provider condition still pins your owner and repository IDs and the two workflow files:

```bash
actual="$(gcloud iam workload-identity-pools providers describe github-oidc \
  --project "${PROJECT_ID}" --location=global --workload-identity-pool=github --format='value(attributeCondition)')"
[[ "${actual}" == *"repository_owner_id=='${GH_OWNER_ID}'"* && "${actual}" == *"repository_id=='${GH_REPO_ID}'"* && "${actual}" == *"deploy-ops"* ]] \
  && printf 'condition matches\n' || printf 'DIFFERENT: compare by eye\n'
```

Each deployer can be impersonated only by its own environment:

```bash
for env in dev qa production; do
  printf '%s: ' "${env}"
  gcloud iam service-accounts get-iam-policy "gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project "${PROJECT_ID}" \
    --format='value(bindings.members)'
done
```

Each line must end with `/subject/${SUB_PREFIX}:environment:<env>` for its own `<env>` and show no other member.

## 5. Rollback

Nothing in Google Cloud changed. To undo, remove the resources from state (`state rm` never deletes anything in the cloud):

```bash
tofu -chdir=envs/apps state list
for m in project network node_sa github_wif secrets budget gke; do
  tofu -chdir=envs/apps state rm "module.${m}"
done
```

Or delete the state object under the `envs/apps` prefix in the bucket. Then start again at step 2.
