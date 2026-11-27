# Service Usage is required in the project by envs/apps, whose provider bills requests to the project (user_project_override).
# The APIs stay here, not in the module: they are a property of the project, and keeping them keeps their live address.
resource "google_project_service" "apis" {
  for_each = toset(["cloudkms.googleapis.com", "storage.googleapis.com", "serviceusage.googleapis.com"])

  service            = each.key
  disable_on_destroy = false
}

module "state" {
  source = "../modules/gcp-state-backend"

  state_bucket_name        = var.state_bucket_name
  region                   = var.region
  kms_key_ring_name        = var.kms_key_ring_name
  kms_key_name             = var.kms_key_name
  kms_rotation_period      = var.kms_rotation_period
  bucket_cmek_enabled      = var.bucket_cmek_enabled
  state_admins             = var.state_admins
  noncurrent_versions_kept = var.noncurrent_versions_kept
  noncurrent_days          = var.noncurrent_days

  depends_on = [google_project_service.apis]
}

# The state resources moved into the module. The first plan after the refactor must show these moves and
# nothing else: 0 to add, 0 to change, 0 to destroy.
moved {
  from = google_kms_key_ring.state
  to   = module.state.google_kms_key_ring.state
}

moved {
  from = google_kms_crypto_key.state
  to   = module.state.google_kms_crypto_key.state
}

moved {
  from = google_kms_crypto_key_iam_member.gcs_agent
  to   = module.state.google_kms_crypto_key_iam_member.gcs_agent
}

moved {
  from = google_storage_bucket.state
  to   = module.state.google_storage_bucket.state
}

moved {
  from = google_storage_bucket_iam_member.admins
  to   = module.state.google_storage_bucket_iam_member.admins
}

moved {
  from = google_kms_crypto_key_iam_member.admins
  to   = module.state.google_kms_crypto_key_iam_member.admins
}
