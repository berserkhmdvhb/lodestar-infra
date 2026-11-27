# bootstrap

Creates the GCS bucket that holds OpenTofu state for the other roots, and the Cloud KMS key that
encrypts that state (OpenTofu native state encryption, `aes_gcm` with the `gcp_kms` key provider).

The bucket is versioned, uses uniform bucket-level access, enforces public access prevention and has
no retention policy (a locked policy cannot be undone). An old version is deleted only when at least
`noncurrent_versions_kept` newer versions exist and it has been noncurrent for `noncurrent_days`.
The key ring, key and bucket have `prevent_destroy`. With `bucket_cmek_enabled = true` the bucket's
default encryption uses the same key. `state_admins` get `roles/storage.objectAdmin` on the bucket
and `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key.

Nothing in this repository applies anything automatically. You run every command below yourself.

## Prerequisites

- OpenTofu 1.13.9 (`make tools` from the repository root installs it into `./.tools/bin`).
- Your own credentials: `gcloud auth application-default login`.
- A project you own, with billing on.

## 1. Variables

```bash
cp terraform.tfvars.example terraform.tfvars   # git-ignored; never commit it
```

Edit `terraform.tfvars`: at least `project_id` and a globally unique `state_bucket_name`.

## 2. First apply (local state)

From the repository root:

```bash
tofu -chdir=bootstrap init
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
tofu -chdir=bootstrap apply bootstrap.tfplan
```

The state is a plain local `terraform.tfstate` (git-ignored) until step 3.

## 3. Migrate the state into the bucket, encrypted

The exact commands, with a proof after each step before anything is deleted, are in
[`docs/import-runbook.md`](../docs/import-runbook.md), section 1, "Move bootstrap's own state into the
bucket, encrypted". They write the git-ignored `bootstrap/override.tf` (the backend and the encryption
block). The backend needs the literal bucket name, so the commands read it from the `state_bucket` output.
Keep `override.tf`: it is the only record of the backend.

Other roots copy the final shape from `encryption.example.tf.txt`, with the key id in a variable.

## 4. Verify

```bash
BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket)"
gcloud storage buckets describe "gs://${BUCKET}" --project "${PROJECT_ID}" \
  --format='yaml(versioning,uniform_bucket_level_access,public_access_prevention,retention_policy)'
```

Expect `versioning.enabled: true`, uniform access enabled, `public_access_prevention: enforced` and
no `retention_policy`. An object under `bootstrap/` in the bucket should not be readable as plain text.

## Tests

`make test` runs `tofu test` here with a mock provider: no credentials, no API calls.
