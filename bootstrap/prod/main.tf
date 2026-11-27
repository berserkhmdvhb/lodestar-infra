# Service Usage is required in the project by the production env root, whose provider bills requests to the project (user_project_override).
# The APIs belong to the project, not to the state module, so each bootstrap root enables its own.
resource "google_project_service" "apis" {
  for_each = toset(["cloudkms.googleapis.com", "storage.googleapis.com", "serviceusage.googleapis.com", "cloudresourcemanager.googleapis.com"])

  service            = each.key
  disable_on_destroy = false
}

module "state" {
  source = "../../modules/gcp-state-backend"

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
