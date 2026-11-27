# One to one with the template's GitHub variables (platform-setup.md).

output "GCP_PROJECT_ID" {
  description = "Project ID, for the GCP_PROJECT_ID repository variable."
  value       = var.project_id
}

output "GKE_CLUSTER" {
  description = "Cluster name, for the GKE_CLUSTER repository variable."
  value       = module.gke.cluster_name
}

output "GKE_LOCATION" {
  description = "Cluster location, for the GKE_LOCATION repository variable."
  value       = module.gke.location
}

output "GCP_WIF_PROVIDER" {
  description = "Workload Identity provider full name."
  value       = module.github_wif.workload_identity_provider
}

output "GCP_DEPLOYER_SA" {
  description = "Map of environment to deployer service account e-mail (one per GitHub environment)."
  value       = module.github_wif.deployer_emails
}

# CI identity of this repository (docs/ci-identity-runbook.md): the secrets GCP_CI_WIF_PROVIDER and GCP_CI_SA.
output "CI_WIF_PROVIDER" {
  description = "Workload Identity provider full name for the plan and drift workflows."
  value       = module.ci_planner.ci_workload_identity_provider
}

output "CI_SERVICE_ACCOUNT" {
  description = "Read-only planner service account e-mail."
  value       = module.ci_planner.ci_service_account
}

output "dns_endpoint" {
  description = "DNS-based control-plane endpoint (host name)."
  value       = module.gke.dns_endpoint
}
