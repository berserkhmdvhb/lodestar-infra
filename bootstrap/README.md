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

```bash
tofu init
tofu plan
tofu apply
```

The state is a plain local `terraform.tfstate` (git-ignored) until step 3.

## 3. Migrate the state into the bucket, encrypted

Create `override.tf` next to the code (git-ignored). Backends cannot use variables, so write the
bucket name in; the key id is the `kms_key_id` output.

```bash
BUCKET="$(tofu output -raw state_bucket)"
KEY="$(tofu output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"
```

```hcl
terraform {
  backend "gcs" {
    bucket = "<the bucket>"
    prefix = "bootstrap"
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = "<the key id>"
      key_length         = 32
    }
    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }
    method "unencrypted" "migrate" {}
    state {
      method   = method.aes_gcm.state
      enforced = false
      fallback {
        method = method.unencrypted.migrate
      }
    }
    plan {
      method   = method.aes_gcm.state
      enforced = false
      fallback {
        method = method.unencrypted.migrate
      }
    }
  }
}
```

```bash
tofu init -migrate-state
tofu plan    # should show no changes
```

Then, in `override.tf`, delete both `fallback` blocks and the `unencrypted` method and set
`enforced = true` in `state` and `plan`. Run `tofu plan` once more; the state in the bucket is
now rewritten encrypted. Delete the old local `terraform.tfstate*` files.

Other roots copy the final shape from `encryption.example.tf.txt`, with the key id in a variable.

## 4. Verify

```bash
gcloud storage buckets describe "gs://${BUCKET}" \
  --format='yaml(versioning,uniform_bucket_level_access,public_access_prevention,retention_policy)'
```

Expect `versioning.enabled: true`, uniform access enabled, `public_access_prevention: enforced` and
no `retention_policy`. An object under `bootstrap/` in the bucket should not be readable as plain text.

## Tests

`make test` runs `tofu test` here with a mock provider: no credentials, no API calls.
