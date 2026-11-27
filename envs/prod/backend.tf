terraform {
  # OpenTofu >= 1.8 evaluates variables early in the backend and encryption blocks, so the bucket and the
  # key come from terraform.tfvars (or TF_VAR_*) and nothing identifying is written here.
  backend "gcs" {
    bucket = var.state_bucket
    prefix = var.state_prefix
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = var.state_kms_key_id
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
