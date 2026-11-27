# gcp-state-backend

The OpenTofu state backend resources: a GCS bucket and a Cloud KMS key ring and key for OpenTofu native state
encryption (`aes_gcm` with the `gcp_kms` key provider). Used by `bootstrap/` and `bootstrap/prod/`.

- The bucket is versioned, uses uniform bucket-level access, enforces public access prevention and has no retention
  policy (a locked policy cannot be undone). An old version is deleted only when at least `noncurrent_versions_kept`
  newer versions exist and it has been noncurrent for `noncurrent_days`.
- The key ring, key and bucket have `prevent_destroy`. The key rotates every `kms_rotation_period` (default 90 days).
  With `bucket_cmek_enabled = true` the bucket's default encryption uses the same key, and the Cloud Storage service
  agent gets `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it.
- `state_admins` get `roles/storage.objectAdmin` on the bucket and `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key.
- Readers are not an input: a CI planner is granted by `modules/gcp-ci-planner` from the env root.
- The project APIs (Cloud KMS, Cloud Storage, Service Usage) stay in the calling root. Call the module with
  `depends_on = [google_project_service.apis]`.

Outputs: `state_bucket`, `kms_key_id`. The provider's `project` is the project that holds the bucket and the key.

Tests: `make test` (mock provider).
