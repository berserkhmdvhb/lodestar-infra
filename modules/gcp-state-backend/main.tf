resource "google_kms_key_ring" "state" {
  name     = var.kms_key_ring_name
  location = var.region

  lifecycle {
    prevent_destroy = true
  }

}

resource "google_kms_crypto_key" "state" {
  name            = var.kms_key_name
  key_ring        = google_kms_key_ring.state.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.kms_rotation_period

  lifecycle {
    prevent_destroy = true
  }
}

data "google_storage_project_service_account" "gcs" {
  count = var.bucket_cmek_enabled ? 1 : 0
}

resource "google_kms_crypto_key_iam_member" "gcs_agent" {
  count = var.bucket_cmek_enabled ? 1 : 0

  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = data.google_storage_project_service_account.gcs[0].member
}

# Never add a retention_policy with is_locked = true: a locked policy cannot be undone.
resource "google_storage_bucket" "state" {
  # checkov:skip=CKV_GCP_62: access logs need a second bucket (more to protect and pay for); Cloud Audit Logs data access can be enabled on the project instead.
  name                        = var.state_bucket_name
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = {
    managed-by = "opentofu"
    purpose    = "tofu-state"
  }

  versioning {
    enabled = true
  }

  # A noncurrent version is deleted only when BOTH conditions hold.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions         = var.noncurrent_versions_kept
      days_since_noncurrent_time = var.noncurrent_days
    }
  }

  dynamic "encryption" {
    for_each = var.bucket_cmek_enabled ? [1] : []
    content {
      default_kms_key_name = google_kms_crypto_key.state.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_agent]
}

resource "google_storage_bucket_iam_member" "admins" {
  for_each = toset(var.state_admins)

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = each.key
}

resource "google_kms_crypto_key_iam_member" "admins" {
  for_each = toset(var.state_admins)

  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.key
}
