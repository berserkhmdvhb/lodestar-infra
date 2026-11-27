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

  # Two backslashes before each literal dot (a CEL string), as Google stores it and as gcp-ci-planner writes it.
  repository_regex = replace(var.github_repository, ".", "\\\\.")

  base_condition = "assertion.repository_owner_id=='${var.github_owner_id}' && assertion.repository_id=='${var.github_repo_id}'"

  # Only the main (deployer) provider takes the optional environment term; preview and drift pin their own.
  environment_term = var.allowed_environment == null ? "" : " && assertion.environment=='${var.allowed_environment}'"

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

# The conditions carry two backslashes (four in HCL source) before each literal dot: a CEL string, as Google keeps it.
resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125:the condition pins the immutable owner ID and repository ID plus the workflow file, which is stricter than the repository-name check
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = var.provider_display_name
  attribute_mapping                  = local.attribute_mapping
  attribute_condition                = "${local.base_condition}${local.environment_term} && assertion.job_workflow_ref.matches('^${local.repository_regex}/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"

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
  account_id   = lookup(var.deployer_account_ids, each.key, "gh-deployer-${each.key}")
  display_name = "GitHub Actions deployer (${each.key})"
}

resource "google_service_account_iam_member" "wif" {
  for_each = local.envs

  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.pool_name}/subject/${var.sub_claim_prefix}:environment:${each.key}"

  # A principal:// member is rejected until its pool exists.
  depends_on = [google_iam_workload_identity_pool.github]
}

resource "google_project_iam_member" "cluster" {
  for_each = local.envs

  project = var.project_id
  role    = local.cluster_role
  member  = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# Optional: pull request previews (guide 12.5).
resource "google_iam_workload_identity_pool_provider" "preview" {
  # checkov:skip=CKV_GCP_125:the condition pins the immutable owner ID and repository ID plus the workflow file, which is stricter than the repository-name check
  count = var.enable_previews ? 1 : 0

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc-preview"
  display_name                       = "GitHub OIDC (previews)"
  attribute_mapping                  = local.attribute_mapping
  attribute_condition                = "${local.base_condition} && assertion.environment=='preview' && assertion.job_workflow_ref.matches('^${local.repository_regex}/\\\\.github/workflows/preview\\\\.yml@refs/(pull/[0-9]+/merge|heads/main)$')"

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
  attribute_condition                = "${local.base_condition} && assertion.environment=='drift-${each.key}' && assertion.job_workflow_ref.matches('^${local.repository_regex}/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')"

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
