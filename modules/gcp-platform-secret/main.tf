locals {
  pool_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns"
}

# The trailing slash after the secret id stops "<id>-other" from matching; the version resource name is
# projects/<number>/secrets/<id>/versions/<v>.
resource "google_project_iam_member" "this" {
  for_each = var.secrets

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "${local.pool_principal}/${each.value.namespace}/sa/external-secrets"

  condition {
    title      = "eso-${each.value.namespace}"
    expression = "resource.name.startsWith(\"projects/${var.project_number}/secrets/${each.key}/\")"
  }
}

# Empty containers only. The value is added by hand and never goes through OpenTofu (it would land in
# state), so this module has no secret version resource.
resource "google_secret_manager_secret" "this" {
  # checkov:skip=CKV_GCP_82:deletion protection is not part of the hand-built secrets pattern
  # checkov:skip=CKV_GCP_83:Google-managed encryption, as the app secrets
  # checkov:skip=CKV2_GCP_20:rotation is done by hand by adding a version
  for_each = var.secrets

  project   = var.project_id
  secret_id = each.key

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
