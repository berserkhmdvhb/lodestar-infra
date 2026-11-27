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
tofu -chdir=bootstrap plan
```

Expected: `Plan: 5 to add, 0 to change, 0 to destroy.` (2 APIs, key ring, key, bucket) and nothing else.
If the bucket name is taken, change `state_bucket_name` and plan again. Then:

```bash
tofu -chdir=bootstrap apply
```

Now move bootstrap's own state into the bucket, encrypted: follow `bootstrap/README.md`, step 3
("Migrate the state into the bucket, encrypted"), with `-chdir=bootstrap` on each command or from inside
`bootstrap/`. When its last `tofu plan` shows no changes, read the two values for step 2:

```bash
STATE_BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket)"
STATE_KMS_KEY_ID="$(tofu -chdir=bootstrap output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${STATE_BUCKET}" "${STATE_KMS_KEY_ID}"
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
- `N to change` may only be fields that exist in the provider and not in Google Cloud: the 9 APIs
  (`disable_on_destroy`, `disable_dependent_services`) and the cluster (`deletion_protection`). So N is
  at most 10. Applying them writes to state only.
- A "to change" line on anything else, or on any other attribute, is a stop: paste the plan.

### HARD STOP

> If any line says `must be replaced`, `-/+`, `will be destroyed`, or the summary says anything but
> `0 to destroy`: DO NOT APPLY. Stop and paste the plan.

Check with:

```bash
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
```

Only the summary line (`... 0 to destroy.`) may match. Anything else is a hard stop.

### Possible differences to expect in the cluster and pool (each means stop and paste)

These come from the GKE module review: the live cluster was made with `gcloud`, which sets values the
module may not state.

| Where in the plan | What it looks like | Why |
| --- | --- | --- |
| Node pool `kubelet_config` | `- kubelet_config { ... }` or `+ kubelet_config { ... }` (for example `cpu_cfs_quota`, `pod_pids_limit`) | GKE fills defaults the module leaves unset |
| Cluster `control_plane_egress` | a `control_plane_egress` / `private_cluster_config` line marked `~` | the live cluster reports a value the module does not set |
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
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" \
  --format='yaml(status,releaseChannel.channel,controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic,privateClusterConfig.enablePrivateNodes)'
```

Expect `status: RUNNING`, channel `STABLE`, external traffic allowed on the DNS endpoint, private nodes on.

The provider condition still pins your owner and repository IDs and the two workflow files:

```bash
actual="$(gcloud iam workload-identity-pools providers describe github-oidc \
  --location=global --workload-identity-pool=github --format='value(attributeCondition)')"
[[ "${actual}" == *"repository_owner_id=='${GH_OWNER_ID}'"* && "${actual}" == *"repository_id=='${GH_REPO_ID}'"* && "${actual}" == *"deploy-ops"* ]] \
  && printf 'condition matches\n' || printf 'DIFFERENT: compare by eye\n'
```

Each deployer can be impersonated only by its own environment:

```bash
for env in dev qa production; do
  printf '%s: ' "${env}"
  gcloud iam service-accounts get-iam-policy "gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com" \
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
