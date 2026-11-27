locals {
  pool_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns"

  app_namespaces = { for e in var.app_environments : e => "${var.service_name}-${e}" }
  db_namespaces  = { for e in var.db_environments : e => "${var.service_name}-${e}-db" }

  secrets = merge([for e, keys in var.secret_keys : { for k in keys : "${e}-${k}" => "${var.service_name}-${e}-${k}" }]...)
}

# External Secrets may read only the secrets of its own namespace; never an unconditioned binding.
resource "google_project_iam_member" "app" {
  for_each = local.app_namespaces

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "${local.pool_principal}/${each.value}/sa/external-secrets"

  condition {
    title      = "eso-${each.value}"
    expression = "resource.name.startsWith(\"projects/${var.project_number}/secrets/${each.value}-\")"
  }
}

# The database namespace may read only the one database password secret.
resource "google_project_iam_member" "db" {
  for_each = local.db_namespaces

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "${local.pool_principal}/${each.value}/sa/external-secrets"

  condition {
    title      = "eso-${each.value}"
    expression = "resource.name.startsWith(\"projects/${var.project_number}/secrets/${each.value}-password\")"
  }
}

# Empty containers only. Values are added by hand and never go through OpenTofu (they would land in state),
# so this module has no secret version resource.
resource "google_secret_manager_secret" "this" {
  # checkov:skip=CKV_GCP_82:deletion protection is not part of the hand-built secrets the import must match
  # checkov:skip=CKV_GCP_83:Google-managed encryption matches the hand-built secrets
  # checkov:skip=CKV2_GCP_20:rotation is not configured on the hand-built secrets
  for_each = local.secrets

  project   = var.project_id
  secret_id = each.value

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
