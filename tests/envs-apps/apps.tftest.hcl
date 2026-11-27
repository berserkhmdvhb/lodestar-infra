# Mock-provider test of the envs/apps composition: no credentials, no API calls.
# Run by tests/envs-apps.bats on a copy of envs/apps without imports.tf and backend.tf (the mock
# provider cannot import, and tofu test would panic on the import blocks).
mock_provider "google" {}

variables {
  project_id          = "your-project-id"
  project_number      = "123456789012"
  github_repository   = "example-owner/example-repo"
  github_owner_id     = "111111111"
  github_repo_id      = "222222222"
  sub_claim_prefix    = "repo:example-owner/example-repo"
  billing_account     = "000000-000000-000000"
  budget_display_name = "Monthly budget"
  budget_id           = "00000000-0000-0000-0000-000000000000"
  state_bucket        = "your-unique-tofu-state-bucket"
  state_kms_key_id    = "projects/your-project-id/locations/europe-west1/keyRings/r/cryptoKeys/k"
}

override_resource {
  target = module.github_wif.google_service_account.deployer["dev"]
  values = {
    name  = "projects/your-project-id/serviceAccounts/gh-deployer-dev@your-project-id.iam.gserviceaccount.com"
    email = "gh-deployer-dev@your-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif.google_service_account.deployer["qa"]
  values = {
    name  = "projects/your-project-id/serviceAccounts/gh-deployer-qa@your-project-id.iam.gserviceaccount.com"
    email = "gh-deployer-qa@your-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif.google_service_account.deployer["production"]
  values = {
    name  = "projects/your-project-id/serviceAccounts/gh-deployer-production@your-project-id.iam.gserviceaccount.com"
    email = "gh-deployer-production@your-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.gke.google_container_cluster.this
  values = {
    control_plane_endpoints_config = {
      dns_endpoint_config = { endpoint = "gke-example.europe-west1-b.gke.goog" }
    }
  }
}

run "outputs_map_onto_the_template_variables" {
  command = plan

  assert {
    condition     = output.GCP_PROJECT_ID == "your-project-id" && output.GKE_CLUSTER == "apps" && output.GKE_LOCATION == "europe-west1-b"
    error_message = "GCP_PROJECT_ID, GKE_CLUSTER and GKE_LOCATION"
  }
  assert {
    condition     = output.GCP_WIF_PROVIDER == "projects/123456789012/locations/global/workloadIdentityPools/github/providers/github-oidc"
    error_message = "GCP_WIF_PROVIDER is the provider full name"
  }
  assert {
    condition = output.GCP_DEPLOYER_SA == {
      dev        = "gh-deployer-dev@your-project-id.iam.gserviceaccount.com"
      qa         = "gh-deployer-qa@your-project-id.iam.gserviceaccount.com"
      production = "gh-deployer-production@your-project-id.iam.gserviceaccount.com"
    }
    error_message = "one deployer per environment"
  }
}

run "dns_endpoint_is_exposed" {
  command = apply

  assert {
    condition     = output.dns_endpoint != null
    error_message = "dns_endpoint must not be null"
  }
}

run "registry_off_budget_on_no_previews_no_drift" {
  command = plan

  assert {
    condition     = module.registry.repository_url == null
    error_message = "registry must be off"
  }
  assert {
    condition     = module.budget.budget_name != null
    error_message = "budget must be on"
  }
  assert {
    condition     = module.github_wif.preview_workload_identity_provider == null && length(module.github_wif.drift_workload_identity_providers) == 0
    error_message = "previews and drift must be off"
  }
}
