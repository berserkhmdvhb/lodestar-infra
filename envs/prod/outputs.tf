# What the template's GitHub "production" environment needs, per service key.

output "GCP_PROJECT_ID" {
  description = "Project ID, for the GCP_PROJECT_ID environment variable."
  value       = var.project_id
}

output "GKE_CLUSTER" {
  description = "Cluster name, for the GKE_CLUSTER environment variable."
  value       = module.gke.cluster_name
}

output "GKE_LOCATION" {
  description = "Cluster location, for the GKE_LOCATION environment variable."
  value       = module.gke.location
}

output "GCP_WIF_PROVIDER" {
  description = "Map of service key to its Workload Identity provider full name."
  value       = { for k, m in module.github_wif : k => m.workload_identity_provider }
}

output "GCP_DEPLOYER_SA" {
  description = "Map of service key to its production deployer service account e-mail."
  value       = { for k, m in module.github_wif : k => m.deployer_emails["production"] }
}

# CI identity of this repository for envs/prod: the secrets TF_PROD_CI_WIF_PROVIDER and TF_PROD_CI_SA.
output "CI_WIF_PROVIDER" {
  description = "Workload Identity provider full name for the production plan and drift jobs."
  value       = module.ci_planner.ci_workload_identity_provider
}

output "CI_SERVICE_ACCOUNT" {
  description = "Read-only planner service account e-mail."
  value       = module.ci_planner.ci_service_account
}

output "CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID" {
  description = "Secret Manager id of the production Cloudflare tunnel token (the value is added by hand)."
  value       = module.platform_secrets.secret_ids["cloudflared-tunnel-token"]
}

output "dns_endpoint" {
  description = "DNS-based control-plane endpoint (host name)."
  value       = module.gke.dns_endpoint
}
