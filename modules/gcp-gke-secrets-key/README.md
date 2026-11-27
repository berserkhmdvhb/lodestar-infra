# gcp-gke-secrets-key

The Cloud KMS key for application-layer Secrets encryption of the GKE cluster: key ring `gke` in the
cluster's region (a zonal cluster in europe-west1-b uses europe-west1), key `secrets` (ENCRYPT_DECRYPT,
rotated every 90 days), and the grant of `roles/cloudkms.cryptoKeyEncrypterDecrypter` to the GKE service
agent `service-<project_number>@container-engine-robot.iam.gserviceaccount.com`.

The ring and the key carry `prevent_destroy = true`: losing the key makes every Secret in the cluster
unreadable (and Cloud KMS never deletes a ring or key name anyway). The `key_id` output waits for the
grant (`depends_on`), so the cluster never references the key before the agent may use it.

Inputs: `project_id`, `project_number` (digits only; both required), `region`, `key_ring_name`, `key_name`,
`rotation_period` (default `7776000s`). Outputs: `key_id`.
