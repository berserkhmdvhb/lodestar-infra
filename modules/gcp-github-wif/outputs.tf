output "workload_identity_provider" {
  description = "Full provider resource name, for google-github-actions/auth."
  value       = "${local.pool_name}/providers/${var.provider_id}"
}

output "deployer_emails" {
  description = "Map of environment to deployer service account email."
  value       = { for e, s in google_service_account.deployer : e => s.email }
}

output "preview_workload_identity_provider" {
  description = "Preview provider resource name, or null when previews are off."
  value       = var.enable_previews ? "${local.pool_name}/providers/github-oidc-preview" : null
}

output "drift_workload_identity_providers" {
  description = "Map of environment to drift provider resource name (empty when drift is off)."
  value       = { for e in local.drift_envs : e => "${local.pool_name}/providers/github-oidc-drift-${e}" }
}

output "provider_attribute_condition" {
  description = "Attribute condition of the main (deployer) provider."
  value       = google_iam_workload_identity_pool_provider.github.attribute_condition
}

output "deployer_wif_members" {
  description = "Map of environment to the principal that may impersonate its deployer."
  value       = { for e, m in google_service_account_iam_member.wif : e => m.member }
}

output "deployer_cluster_roles" {
  description = "Map of environment to the project role its deployer holds."
  value       = { for e, m in google_project_iam_member.cluster : e => m.role }
}

output "drift_service_accounts" {
  description = "Map of environment to the drift reader service account email (empty when drift is off)."
  value       = { for e, s in google_service_account.drift : e => s.email }
}

output "drift_condition" {
  description = "Map of environment to the attribute condition of its drift provider."
  value       = { for e, p in google_iam_workload_identity_pool_provider.drift : e => p.attribute_condition }
}

output "drift_cluster_roles" {
  description = "Map of environment to the project role its drift reader holds."
  value       = { for e, m in google_project_iam_member.drift : e => m.role }
}

output "drift_wif_members" {
  description = "Map of environment to the principal that may impersonate its drift reader."
  value       = { for e, m in google_service_account_iam_member.drift : e => m.member }
}
