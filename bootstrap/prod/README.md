# bootstrap/prod

The state bootstrap of the PRODUCTION project: the same `modules/gcp-state-backend` as [`../`](../README.md), in its
own project, with its own bucket and its own KMS key, so production state never depends on the non-production
project. It also enables the Cloud KMS, Cloud Storage, Service Usage and Cloud Resource Manager APIs there
(4 `google_project_service` resources; the production env root bills requests to the project).

What the bucket and key are (versioned, uniform access, public access prevention enforced, no retention policy, the
key ring, key and bucket have `prevent_destroy`, `state_admins` get `roles/storage.objectAdmin` plus the key role) is
described in the module's [README](../../modules/gcp-state-backend/README.md). Readers such as a CI planner are not
granted here: the production env root grants its own planner access to the bucket and the key.

Nothing in this repository applies anything automatically. You run every command below yourself, from the
repository root.

## Prerequisites

- OpenTofu 1.13.9 (`make tools` installs it into `./.tools/bin`).
- Your own credentials: `gcloud auth application-default login`.
- The production project, with billing on. Export `PROJECT_ID` as the production project id.

## 1. Variables

```bash
cp bootstrap/prod/terraform.tfvars.example bootstrap/prod/terraform.tfvars
```

The copy is git-ignored; never commit it. Set `project_id` to the production project and a globally unique
`state_bucket_name` (not the one of `bootstrap/`).

## 2. First apply (local state)

```bash
tofu -chdir=bootstrap/prod init
tofu -chdir=bootstrap/prod plan -out=bootstrap-prod.tfplan
tofu -chdir=bootstrap/prod apply bootstrap-prod.tfplan
rm -f bootstrap/prod/bootstrap-prod.tfplan
```

The state is a plain local `terraform.tfstate` (git-ignored) until step 3. If the apply fails with
`SERVICE_DISABLED` right after the Cloud KMS API was enabled, wait a minute and plan and apply again.

## 3. Migrate the state into the bucket, encrypted

Same proof steps as `bootstrap/`, with the object under the `bootstrap-prod/` prefix.

```bash
BUCKET="$(tofu -chdir=bootstrap/prod output -raw state_bucket)"
KEY="$(tofu -chdir=bootstrap/prod output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"
```

Both must print a value. Write the migration form (it can still read the plain state):

```bash
cat > bootstrap/prod/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap-prod"
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
tofu -chdir=bootstrap/prod init -migrate-state
```

Answer `yes` to copying the state to the new backend. Proof that the object in the bucket is encrypted:

```bash
gcloud storage cat "gs://${BUCKET}/bootstrap-prod/default.tfstate" --project "${PROJECT_ID}" | grep -c encrypted_data
gcloud storage cat "gs://${BUCKET}/bootstrap-prod/default.tfstate" --project "${PROJECT_ID}" | grep -c '"resources"'
```

The first count must be `1` or more and the second `0`. If it shows plain JSON: keep the fallback, run
`tofu -chdir=bootstrap/prod apply` (expect `No changes`; it saves the state again with the new method), and check again.

Now write the final form (no fallback, no `unencrypted` method, encryption enforced):

```bash
cat > bootstrap/prod/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap-prod"
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
tofu -chdir=bootstrap/prod plan
```

It must say `No changes`. Without the fallback OpenTofu refuses plain state, so this is a second proof. Only then
delete the old local copies:

```bash
rm -f bootstrap/prod/terraform.tfstate bootstrap/prod/terraform.tfstate.backup
```

`bootstrap/prod/override.tf` is now the only record of the backend. It is git-ignored, so keep it (or back it up
to `~/platform-config`).

## 4. Verify

```bash
BUCKET="$(tofu -chdir=bootstrap/prod output -raw state_bucket)"
gcloud storage buckets describe "gs://${BUCKET}" --project "${PROJECT_ID}" \
  --format='yaml(versioning,uniform_bucket_level_access,public_access_prevention,retention_policy)'
```

Expect `versioning.enabled: true`, uniform access enabled, `public_access_prevention: enforced` and no
`retention_policy`.

## Tests

`make test` runs `tofu test` here with a mock provider: no credentials, no API calls.
