resource "google_project_service" "this" {
  for_each = var.services

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Authoritative for container.googleapis.com only. Writes to Kubernetes objects are already in the
# always-on Admin Activity logs; the read data type is left out on purpose (every get, list and watch would be logged).
resource "google_project_iam_audit_config" "container" {
  count = var.enable_container_audit_logs ? 1 : 0

  project = var.project_id
  service = "container.googleapis.com"

  # The IAM policy call needs the Resource Manager API, which a new project does not have until services are enabled.
  depends_on = [google_project_service.this]

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
