locals {
  pool_name = "projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}"

  # Two backslashes before each literal dot (a CEL string), as Google stores it and as gcp-github-wif writes it.
  repository_regex = replace(var.github_repository, ".", "\\\\.")

  attribute_condition = "assertion.repository_owner_id=='${var.github_owner_id}' && assertion.repository_id=='${var.github_repo_id}' && assertion.event_name in ['pull_request', 'schedule', 'workflow_dispatch'] && assertion.job_workflow_ref.matches('^${local.repository_regex}/\\\\.github/workflows/(plan|drift)\\\\.yml@refs/(heads/main|pull/[0-9]+/merge)$')"

  # Read-only project roles. serviceUsageConsumer is for user_project_override: requests are billed to the project.
  project_roles = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  subjects = toset(["${var.sub_claim_prefix}:pull_request", "${var.sub_claim_prefix}:ref:refs/heads/main"])
}

resource "google_iam_workload_identity_pool" "ci" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = var.pool_display_name
}

resource "google_iam_workload_identity_pool_provider" "ci" {
  # checkov:skip=CKV_GCP_125:the condition pins the immutable owner ID and repository ID plus the workflow file, which is stricter than the repository-name check
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.ci.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = var.provider_display_name
  attribute_condition                = local.attribute_condition

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.job_workflow_ref"    = "assertion.job_workflow_ref"
    "attribute.ref"                 = "assertion.ref"
    "attribute.event_name"          = "assertion.event_name"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "planner" {
  project      = var.project_id
  account_id   = "tofu-planner"
  display_name = "OpenTofu planner (CI, read-only)"
}

# Pull request jobs and main-branch jobs (the weekly drift run) only; the jobs must not use GitHub environments.
resource "google_service_account_iam_member" "wif" {
  for_each = local.subjects

  service_account_id = google_service_account.planner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.pool_name}/subject/${each.value}"
}

resource "google_project_iam_member" "planner" {
  # checkov:skip=CKV_GCP_117:roles/viewer is the read-only role `tofu plan` needs to refresh every resource; the identity has no write role (the module test fails on one)
  for_each = local.project_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.planner.email}"
}

# The gcs backend only reads and lists objects with -lock=false (no bucket metadata call), so objectViewer on the bucket is enough.
resource "google_storage_bucket_iam_member" "state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.planner.email}"
}

# The gcp_kms key provider calls Encrypt (a new data key) on every Provide as well as Decrypt, so the decrypt-only role does not work.
resource "google_kms_crypto_key_iam_member" "state" {
  crypto_key_id = var.state_kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.planner.email}"
}

# Includes cost data (the budget and spend are readable). Custom billing roles need an organization.
resource "google_billing_account_iam_member" "viewer" {
  billing_account_id = var.billing_account
  role               = "roles/billing.viewer"
  member             = "serviceAccount:${google_service_account.planner.email}"
}
