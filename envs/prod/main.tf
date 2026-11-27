# envs/prod: the production project. A regional cluster that hosts the production of every service in
# var.services. Everything is created, never imported, so the creation order is explicit (depends_on).

locals {
  # The production API set: no artifactregistry (images are on GHCR) and no cloudkms (bootstrap/prod owns it).
  project_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "billingbudgets.googleapis.com",
    "secretmanager.googleapis.com",
  ]

}

module "project" {
  source = "../../modules/gcp-project"

  project_id = var.project_id
  services   = local.project_services
}

module "gke_secrets_key" {
  source = "../../modules/gcp-gke-secrets-key"

  project_id     = var.project_id
  project_number = var.project_number
  region         = var.region
  key_ring_name  = "prod-gke"
  key_name       = "prod-secrets"

  # The GKE service agent exists only once the container API is enabled; the key's grant to it waits for that.
  depends_on = [module.project]
}

module "network" {
  source = "../../modules/gcp-network"

  project_id    = var.project_id
  region        = var.region
  network_name  = "prod-vpc"
  subnet_name   = "prod-subnet"
  subnet_cidr   = "10.40.0.0/20"
  pods_cidr     = "10.50.0.0/16"
  services_cidr = "10.60.0.0/20"
  router_name   = "prod-router"
  nat_name      = "prod-nat"

  # Off (no previews here); the range is set so that turning it on cannot overlap the node subnet.
  proxy_only_subnet_name = "prod-proxy-only"
  proxy_only_cidr        = "10.40.16.0/23"

  depends_on = [module.project]
}

module "node_sa" {
  source = "../../modules/gcp-node-sa"

  project_id   = var.project_id
  display_name = "GKE nodes (prod)"

  depends_on = [module.project]
}

module "gke" {
  source = "../../modules/gcp-gke"

  project_id           = var.project_id
  cluster_name         = "prod"
  labels               = { cluster = "prod" }
  location             = var.region
  node_locations       = var.node_locations
  node_service_account = module.node_sa.email
  network              = module.network.network_name
  subnetwork           = module.network.subnet_name
  pods_range_name      = module.network.pods_range_name
  services_range_name  = module.network.services_range_name

  spot            = false
  location_policy = "BALANCED"
  min_node_count  = 1
  max_node_count  = 2 # per zone: a cap of 4 across two zones, and a node guaranteed in each

  # Tuesday and Wednesday, 8 h each, so the non-production cluster (weekend window) upgrades first.
  maintenance_start_time = "2026-12-01T00:00:00Z"
  maintenance_end_time   = "2026-12-01T08:00:00Z"
  maintenance_recurrence = "FREQ=WEEKLY;BYDAY=TU,WE"

  # A newly created cluster would get an internet-reachable IP endpoint; production uses the DNS endpoint only.
  enable_public_endpoint = false
  deletion_protection    = true

  enable_insecure_binding_system_unauthenticated = false
  enable_insecure_binding_system_authenticated   = false

  database_encryption_key = module.gke_secrets_key.key_id

  depends_on = [module.project]
}

# The custom role is created once, independent of the services, so adding or removing a service never moves it.
module "connect_role" {
  source = "../../modules/gcp-gke-connect-role"

  project_id = var.project_id

  depends_on = [module.project]
}

# One Workload Identity pool per service, all holding the one connect role.
module "github_wif" {
  source   = "../../modules/gcp-github-wif"
  for_each = var.services

  project_id                 = var.project_id
  project_number             = var.project_number
  github_repository          = each.value.github_repository
  github_owner_id            = each.value.github_owner_id
  github_repo_id             = each.value.github_repo_id
  sub_claim_prefix           = each.value.sub_claim_prefix
  pool_id                    = "gh-${each.key}"
  environments               = ["production"]
  allowed_environment        = "production"
  deployer_account_ids       = { production = each.value.deployer_account_id }
  deployer_cluster_role      = module.connect_role.role_name
  create_custom_connect_role = false
  enable_previews            = false
  enable_drift               = true
  drift_environments         = ["production"]
  drift_account_ids          = { production = "gh-drift-${each.key}" } # 12 to 29 characters for a 3 to 20 character key

  depends_on = [module.project]
}

module "ci_planner" {
  source = "../../modules/gcp-ci-planner"

  project_id        = var.project_id
  project_number    = var.project_number
  github_repository = var.ci_github_repository
  github_owner_id   = var.ci_github_owner_id
  github_repo_id    = var.ci_github_repo_id
  sub_claim_prefix  = var.ci_sub_claim_prefix
  state_bucket      = var.state_bucket
  state_kms_key_id  = var.state_kms_key_id
  billing_account   = var.billing_account

  depends_on = [module.project]
}

# The <project>.svc.id.goog pool exists only once the first Workload Identity cluster does; IAM rejects the
# External Secrets bindings before then, so these wait for the cluster.
module "secrets" {
  source   = "../../modules/gcp-secrets"
  for_each = var.services

  project_id       = var.project_id
  project_number   = var.project_number
  region           = var.region
  service_name     = each.value.service_name
  app_environments = ["production"]
  db_environments  = []
  secret_keys      = { production = each.value.secret_keys }

  depends_on = [module.project, module.gke]
}

module "platform_secrets" {
  source = "../../modules/gcp-platform-secret"

  project_id     = var.project_id
  project_number = var.project_number
  region         = var.region
  secrets = {
    "cloudflared-tunnel-token" = { namespace = "cloudflared" }
  }

  depends_on = [module.project, module.gke]
}

module "budget" {
  source = "../../modules/gcp-budget"

  enabled            = true
  billing_account    = var.billing_account
  project_number     = var.project_number
  display_name       = var.budget_display_name
  currency_code      = "EUR"
  amount_units       = "250"
  threshold_percents = [0.5, 0.9, 1.0, 1.5]

  depends_on = [module.project]
}
