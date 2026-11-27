# gcp-gke

The Standard zonal GKE cluster `apps` and its autoscaled node pool `default-pool`, as two resources
(`google_container_cluster.this`, `google_container_node_pool.this`). Private nodes, the DNS-based
control-plane endpoint (external traffic allowed; the public IP endpoint is on by default and
`enable_public_endpoint = false` turns it off), Dataplane V2, a Workload Identity pool, Gateway API
standard, Shielded nodes with Secure Boot, a release channel, a weekly Saturday/Sunday 8-hour maintenance
window, managed Prometheus plus system and workload logging, a spot node pool running as the dedicated
node service account, and labels. Binary Authorization is off until `binary_authorization_mode` is set
(phase 11).

Inputs: `project_id`, `network`, `subnetwork`, `node_service_account` (required; the default compute
account is refused), and defaults for the cluster, zone, channel, ranges, maintenance window, labels, pool
name, machine, disk, node counts and `spot`, and the security inputs below. For a regional cluster:
`node_locations`, `location_policy` (`ANY` or `BALANCED`), `total_max_node_count` (replaces the per-zone
maximum; `min_node_count` then is the total minimum) and `oauth_scopes`; defaults keep the zonal `apps` cluster. Outputs: `cluster_name`, `location`, `dns_endpoint`.

## Built to be imported

The cluster was first created by hand and both resources are meant to be imported, not created: every set
argument equals the live value, and everything else is left unset so the provider keeps what the API
reports. The cluster is declared with `remove_default_node_pool` and `initial_node_count` (GKE needs a pool
at creation) and ignores `node_pool`, `node_config`, `initial_node_count` and `remove_default_node_pool`, so
the pool managed by the separate resource never fights it. The pool ignores `node_count` (the autoscaler
owns it) and `initial_node_count` (create-only). `deletion_protection` is a provider-only setting.

The provider marks `remove_default_node_pool` deprecated for cluster versions 1.36.4 and later; plans show
that warning until the module moves to the node-pool-free form.

## Security baseline (task L1.4)

All in-place changes on the live cluster, each behind a variable whose default is the hardened value:

- `rbac_binding_config`: bindings to `system:anonymous`, `system:unauthenticated` and
  `system:authenticated` are refused (`enable_insecure_binding_system_unauthenticated` and
  `enable_insecure_binding_system_authenticated`, both false).
- `database_encryption`: application-layer Secrets encryption with `database_encryption_key` (the
  `key_id` output of `gcp-gke-secrets-key`). Null leaves Secrets DECRYPTED.
- `security_posture_config`: mode `BASIC` (free). Enterprise is paid and refused. `vulnerability_mode` is
  left unset: GKE shut down workload vulnerability scanning (container OS scanning on July 31, 2025,
  advanced insights on June 16, 2026), so there is no free tier left to set.

Deferred, not in this task: the node pool's OAuth scopes (`cloud-platform`) and spot to on-demand. Both
force a new node pool, so they wait for one planned pool swap before go-live.
