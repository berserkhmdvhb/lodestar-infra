output "ci_workload_identity_provider" {
  description = "Full provider resource name, for google-github-actions/auth."
  value       = "${local.pool_name}/providers/${var.provider_id}"
}

output "ci_service_account" {
  description = "E-mail of the read-only planner service account."
  value       = google_service_account.planner.email
}
