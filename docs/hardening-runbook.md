# Hardening runbook: the GKE security baseline (task L1.4)

You run every command here yourself. Nothing in this repository applies anything on its own.
Commands work in bash and zsh. Run them from the repository root, in the same terminal, in order.

What this does: the first change to live resources after the import. Everything is in place: nothing is
replaced or destroyed, and the cluster keeps serving.

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
    `database_encryption` `DECRYPTED` to `ENCRYPTED` with the key;
  - `module.network.google_compute_subnetwork.this`: a `log_config` block added.
- 0 to destroy, nothing replaced.

### HARD STOP

> If any line says `must be replaced`, `-/+`, `will be destroyed`, or the summary says anything but
> `0 to destroy`: DO NOT APPLY. Stop and paste the plan.

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
- under the cluster: `~ database_encryption {` with `~ state = "DECRYPTED" -> "ENCRYPTED"` and a `key_name`
  line (`~` or `+`, value `(known after apply)`), and `~ rbac_binding_config {` with
  `~ enable_insecure_binding_system_authenticated = true -> false` and
  `~ enable_insecure_binding_system_unauthenticated = true -> false`;
- under the subnet: one `+ log_config {` line;
- no line starting with `-`.

Any other line: stop, `rm -f envs/apps/hardening.tfplan`, and paste the plan.

## 3. Apply the saved plan

```bash
tofu -chdir=envs/apps apply hardening.tfplan
```

The cluster update re-encrypts every Secret and can take 10-30 minutes; the cluster keeps serving. Then:

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

## 5. Clean up

```bash
rm -f envs/apps/hardening.tfplan
```

## 6. Rollback

- RBAC and flow logs are reversible by variable: set `enable_insecure_binding_system_*` to `true` in the
  `gke` module call, or `enable_flow_logs = false` in the `network` call, then plan and apply as above.
- Decrypting Secrets is possible (`database_encryption_key = null` gives state `DECRYPTED`), but the key must
  stay: never destroy it. The ring and key have `prevent_destroy`, and Cloud KMS keeps the names anyway.
- The audit config is removed with `enable_container_audit_logs = false` in the `project` call.
