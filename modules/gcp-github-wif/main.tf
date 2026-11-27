locals {
  issuer_uri = "https://token.actions.githubusercontent.com"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.job_workflow_ref"    = "assertion.job_workflow_ref"
    "attribute.ref"                 = "assertion.ref"
  }

  # The stored conditions carry two backslashes before each literal dot (a CEL string), as Google keeps them.
  base_condition = "assertion.repository_owner_id=='${var.github_owner_id}' && assertion.repository_id=='${var.github_repo_id}'"

  cluster_role = var.create_custom_connect_role ? "projects/${var.project_id}/roles/${google_project_iam_custom_role.connect[0].role_id}" : var.deployer_cluster_role

  pool_name  = "projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}"
  envs       = toset(var.environments)
  drift_envs = var.enable_drift ? local.envs : toset([])
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = var.pool_display_name
}

resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125:the condition pins the immutable owner ID and repository ID plus the workflow file, which is stricter than the repository-name check
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = var.provider_display_name
  attribute_mapping                  = local.attribute_mapping
  attribute_condition                = "${local.base_condition} && assertion.job_workflow_ref.matches('^${var.github_repository}/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"

  oidc {
    issuer_uri = local.issuer_uri
  }
}

resource "google_project_iam_custom_role" "connect" {
  count = var.create_custom_connect_role ? 1 : 0

  project     = var.project_id
  role_id     = "gkeDnsConnect"
  title       = "GKE DNS endpoint connect"
  permissions = ["container.clusters.get", "container.clusters.connect"]
  stage       = "GA"
}

resource "google_service_account" "deployer" {
  for_each = local.envs

  project      = var.project_id
  account_id   = "gh-deployer-${each.key}"
  display_name = "GitHub Actions deployer (${each.key})"
}

resource "google_service_account_iam_member" "wif" {
  for_each = local.envs

  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.pool_name}/subject/${var.sub_claim_prefix}:environment:${each.key}"
}

resource "google_project_iam_member" "cluster" {
  for_each = local.envs

  project = var.project_id
  role    = local.cluster_role
  member  = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# Optional: pull request previews (guide 12.5).
resource "google_iam_workload_identity_pool_provider" "preview" {
  count = var.enable_previews ? 1 : 0

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc-preview"
  display_name                       = "GitHub OIDC (previews)"
  attribute_mapping                  = local.attribute_mapping
  attribute_condition                = "${local.base_condition} && assertion.environment=='preview' && assertion.job_workflow_ref.matches('^${var.github_repository}/\\\\.github/workflows/preview\\\\.yml@refs/(pull/[0-9]+/merge|heads/main)$')"

  oidc {
    issuer_uri = local.issuer_uri
  }
}

resource "google_service_account" "preview" {
  count = var.enable_previews ? 1 : 0

  project      = var.project_id
  account_id   = "gh-deployer-preview"
  display_name = "GitHub Actions deployer (preview)"
}

resource "google_service_account_iam_member" "preview" {
  count = var.enable_previews ? 1 : 0

  service_account_id = google_service_account.preview[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.pool_name}/subject/${var.sub_claim_prefix}:environment:preview"
}

resource "google_project_iam_member" "preview" {
  count = var.enable_previews ? 1 : 0

  project = var.project_id
  role    = local.cluster_role
  member  = "serviceAccount:${google_service_account.preview[0].email}"
}

# Optional: live drift readers (guide 12.6), one provider and account per environment.
resource "google_iam_workload_identity_pool_provider" "drift" {
  # checkov:skip=CKV_GCP_125:the condition pins the immutable owner ID and repository ID plus the workflow file, which is stricter than the repository-name check
  for_each = local.drift_envs

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc-drift-${each.key}"
  display_name                       = "GitHub OIDC (drift ${each.key})"
  attribute_mapping                  = local.attribute_mapping
  attribute_condition                = "${local.base_condition} && assertion.environment=='drift-${each.key}' && assertion.job_workflow_ref.matches('^${var.github_repository}/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')"

  oidc {
    issuer_uri = local.issuer_uri
  }
}

resource "google_service_account" "drift" {
  for_each = local.drift_envs

  project      = var.project_id
  account_id   = "gh-drift-${each.key}"
  display_name = "GitHub Actions drift reader (${each.key})"
}

resource "google_service_account_iam_member" "drift" {
  for_each = local.drift_envs

  service_account_id = google_service_account.drift[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.pool_name}/subject/${var.sub_claim_prefix}:environment:drift-${each.key}"
}

resource "google_project_iam_member" "drift" {
  for_each = local.drift_envs

  project = var.project_id
  role    = local.cluster_role
  member  = "serviceAccount:${google_service_account.drift[each.key].email}"
}
