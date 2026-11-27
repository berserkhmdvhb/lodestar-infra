# One to one with the template's GitHub variables (platform-setup.md).

output "GCP_PROJECT_ID" {
  value = var.project_id
}

output "GKE_CLUSTER" {
  value = module.gke.cluster_name
}

output "GKE_LOCATION" {
  value = module.gke.location
}

output "GCP_WIF_PROVIDER" {
  description = "Workload Identity provider full name."
  value       = module.github_wif.workload_identity_provider
}

output "GCP_DEPLOYER_SA" {
  description = "Map of environment to deployer service account e-mail (one per GitHub environment)."
  value       = module.github_wif.deployer_emails
}

output "dns_endpoint" {
  description = "DNS-based control-plane endpoint (host name)."
  value       = module.gke.dns_endpoint
}
