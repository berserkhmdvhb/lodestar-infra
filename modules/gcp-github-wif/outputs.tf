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
