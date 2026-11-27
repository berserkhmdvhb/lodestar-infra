# Hardening runbook: the GKE security baseline (task L1.4)

You run every command here yourself. Nothing in this repository applies anything on its own.
Commands work in bash and zsh. Run them from the repository root, in the same terminal, in order.

What this does: the first change to live resources after the import. Everything is in place: nothing is
replaced or destroyed. But enabling Secrets encryption restarts the cluster control plane, and on a zonal
cluster the control plane is unavailable meanwhile (see step 3). Pick a quiet window.

- RBAC bindings to `system:anonymous`, `system:unauthenticated` and `system:authenticated` are refused.
- Secrets are encrypted at the application layer with a new Cloud KMS key (rotated every 90 days).
- VPC flow logs on the node subnet (10-minute aggregation, 10 percent sampling).
- Data Access audit logs for the container API: `ADMIN_READ` and `DATA_WRITE` only (no reads, which would
  log every get, list and watch). Writes to Kubernetes objects are already in the always-on, free Admin
  Activity logs. The audit config is authoritative for `container.googleapis.com` only.
- Security posture stays `BASIC` (free). Not in this task: node OAuth scopes and spot to on-demand (they
  need a new node pool, planned before go-live).

## 0. Prerequisites

```bash
export PATH="${PWD}/.tools/bin:${PATH}"
source ~/gke-setup.env                         # PROJECT_ID, PROJECT_NUMBER, REGION, ZONE, CLUSTER
gcloud auth application-default login
gcloud auth application-default set-quota-project "${PROJECT_ID}"
printf 'project=%s region=%s zone=%s\n' "${PROJECT_ID}" "${REGION}" "${ZONE}"
```

`envs/apps/terraform.tfvars` from the import runbook must still be there. Then `tofu -chdir=envs/apps init`.

## 1. Plan

```bash
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

## 2. Acceptance

The last line must read:

```text
Plan: 4 to add, 2 to change, 0 to destroy.
```

- 4 to add: `module.gke_secrets_key.google_kms_key_ring.gke`, `...google_kms_crypto_key.secrets`,
  `...google_kms_crypto_key_iam_member.gke_agent`, and `module.project.google_project_iam_audit_config.container[0]`.
- 2 to change in place:
  - `module.gke.google_container_cluster.this`: `rbac_binding_config` both `true` to `false`, and
    `database_encryption` `DECRYPTED` to `ENCRYPTED` with the key (`key_name` is a known value, not `(known after apply)`);
  - `module.network.google_compute_subnetwork.this`: a `log_config` block added.
- 0 to destroy, nothing replaced.

### HARD STOP

> If any line says `must be replaced`, `-/+`, `will be destroyed`, or the summary says anything but
> `0 to destroy`: DO NOT APPLY. Delete the plan file (`rm -f envs/apps/hardening.tfplan`), stop and
> paste the plan.

```bash
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
```

Only the summary line (`... 0 to destroy.`) may match.

Then check every changed attribute of the saved plan:

```bash
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE '^ *[-~] |will be |^ *\+ (log_config|key_name)'
```

Expected, and nothing else:

- the legend line `~ update in-place`;
- 4 `will be created` lines, 2 `will be updated in-place` lines, and no other `will be` line;
- 2 `~ resource` headers: `google_container_cluster` and `google_compute_subnetwork`;
- under the cluster: `~ database_encryption {` with `~ state = "DECRYPTED" -> "ENCRYPTED"` (never `(known after apply)`) and a `key_name`
  line (`~` or `+`) with the value `"projects/<project>/locations/europe-west1/keyRings/gke/cryptoKeys/secrets"`, and `~ rbac_binding_config {` with
  `~ enable_insecure_binding_system_authenticated = true -> false` and
  `~ enable_insecure_binding_system_unauthenticated = true -> false`;
- under the subnet: one `+ log_config {` line;
- no line starting with `-`.

Any other line: stop, delete the plan file, and paste the plan:

```bash
rm -f envs/apps/hardening.tfplan
```

## 3. Apply the saved plan

Before you apply: enabling Secrets encryption restarts the cluster control plane, and for a zonal cluster
the control plane is unavailable during the restart. Running Pods keep serving, but `kubectl`, CI deploys,
External Secrets syncs and autoscaling stop until it is back. Choose a quiet window and run no deploys (no
GitHub deploy workflows) meanwhile. The update also re-encrypts every Secret; 10-30 minutes is an estimate,
not a promise.

```bash
tofu -chdir=envs/apps apply hardening.tfplan
```

If the apply fails after the four creations (for example while the new KMS grant propagates): delete the
old plan file, wait a few minutes, plan again into a new file and review it with step 2. Expect
`0 to add, 2 to change, 0 to destroy` with the same two in-place changes, then apply that file.

```bash
rm -f envs/apps/hardening.tfplan
sleep 180
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

When the apply is done:

```bash
tofu -chdir=envs/apps plan
```

It must print `No changes. Your infrastructure matches the configuration.`

## 4. Verify against the live setup

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(databaseEncryption,rbacBindingConfig,securityPostureConfig)'
```

Expect `databaseEncryption.state: ENCRYPTED` (with the `gke/cryptoKeys/secrets` key) and both
`rbacBindingConfig` switches `false`; the security posture mode stays `BASIC`.

```bash
gcloud compute networks subnets describe apps-subnet --region "${REGION}" --project "${PROJECT_ID}" \
  --format='yaml(logConfig)'
```

Expect `logConfig.enable: true`, `INTERVAL_10_MIN`, `flowSampling: 0.1`, `INCLUDE_ALL_METADATA`.

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json \
  | python3 -c 'import json,sys; [print(c["service"], sorted(l["logType"] for l in c["auditLogConfigs"])) for c in json.load(sys.stdin).get("auditConfigs", []) if c["service"] == "container.googleapis.com"]'
```

Expect `container.googleapis.com ['ADMIN_READ', 'DATA_WRITE']`.

The RBAC switches only block NEW bindings; they do not remove existing ones. List every binding whose
subjects include the three groups:

```bash
{ kubectl get clusterrolebindings -o json; kubectl get rolebindings -A -o json; } \
  | jq -r '.items[] | select(any(.subjects[]?; .name == "system:authenticated" or .name == "system:unauthenticated" or .name == "system:anonymous")) | "\(.kind) \(.metadata.namespace // "-") \(.metadata.name)"'
```

Expected, and only these: `ClusterRoleBinding - system:basic-user`, `ClusterRoleBinding - system:discovery`
and `ClusterRoleBinding - system:public-info-viewer`. Anything else: stop and paste it; delete nothing.

## 5. Clean up

```bash
rm -f envs/apps/hardening.tfplan
```

## 6. Rollback

- RBAC and flow logs are reversible by variable: set `enable_insecure_binding_system_*` to `true` in the
  `gke` module call, or `enable_flow_logs = false` in the `network` call, then plan and apply as above.
- Decrypting Secrets is possible (`database_encryption_key = null` gives state `DECRYPTED`), but wait until
  the cluster has been stable for more than 4 hours first, and keep the key: never destroy the key or the
  ring. The ring and key have `prevent_destroy`, and Cloud KMS keeps the names anyway.
- The audit config is removed with `enable_container_audit_logs = false` in the `project` call. That plan
  shows `1 to destroy` (the audit config only): the one exception to the hard stop. Any other destroy, and
  above all of the KMS key or ring, is still a stop.
