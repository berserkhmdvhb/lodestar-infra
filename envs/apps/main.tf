# envs/apps: the one shared cluster that hosts the dev, qa and production namespaces.

locals {
  environments = ["dev", "qa", "production"]
  service_name = "your-service-name"

  # The module default, written out because imports.tf derives the import ids from it.
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "billingbudgets.googleapis.com",
    "secretmanager.googleapis.com",
  ]

  # The module default, written out because imports.tf derives the secret ids from it.
  secret_keys = {
    dev        = ["db-user", "db-password", "stats-pass"]
    qa         = ["db-user", "db-password", "stats-pass"]
    production = ["stats-pass"]
  }
}

module "project" {
  source = "../../modules/gcp-project"

  project_id = var.project_id
  services   = local.services
}

module "network" {
  source = "../../modules/gcp-network"

  project_id = var.project_id
  region     = var.region
}

module "node_sa" {
  source = "../../modules/gcp-node-sa"

  project_id = var.project_id
}

module "registry" {
  source = "../../modules/gcp-registry"

  project_id = var.project_id
  region     = var.region
  enabled    = false
}

module "github_wif" {
  source = "../../modules/gcp-github-wif"

  project_id                 = var.project_id
  project_number             = var.project_number
  github_repository          = var.github_repository
  github_owner_id            = var.github_owner_id
  github_repo_id             = var.github_repo_id
  sub_claim_prefix           = var.sub_claim_prefix
  environments               = local.environments
  create_custom_connect_role = false
  enable_previews            = false
  enable_drift               = false
}

module "secrets" {
  source = "../../modules/gcp-secrets"

  project_id     = var.project_id
  project_number = var.project_number
  region         = var.region
  service_name   = local.service_name
  secret_keys    = local.secret_keys
}

module "budget" {
  source = "../../modules/gcp-budget"

  enabled         = true
  billing_account = var.billing_account
  project_number  = var.project_number
  display_name    = var.budget_display_name
}

module "gke" {
  source = "../../modules/gcp-gke"

  project_id           = var.project_id
  location             = var.zone
  node_service_account = module.node_sa.email
  network              = module.network.network_name
  subnetwork           = module.network.subnet_name
  pods_range_name      = module.network.pods_range_name
  services_range_name  = module.network.services_range_name
}
