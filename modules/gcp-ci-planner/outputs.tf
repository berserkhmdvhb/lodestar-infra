output "ci_workload_identity_provider" {
  description = "Full provider resource name, for google-github-actions/auth."
  value       = "${local.pool_name}/providers/${var.provider_id}"
}

output "ci_service_account" {
  description = "E-mail of the read-only planner service account."
  value       = google_service_account.planner.email
}

output "ci_attribute_condition" {
  description = "Attribute condition of the planner provider."
  value       = google_iam_workload_identity_pool_provider.ci.attribute_condition
}

output "ci_wif_members" {
  description = "The principals that may impersonate the planner."
  value       = sort([for m in google_service_account_iam_member.wif : m.member])
}
