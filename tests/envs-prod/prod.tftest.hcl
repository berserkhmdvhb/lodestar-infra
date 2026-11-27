# Mock-provider test of the envs/prod composition: no credentials, no API calls.
# Run by tests/envs-prod.bats on a copy of envs/prod without backend.tf.
mock_provider "google" {}

variables {
  project_id           = "your-production-project-id"
  project_number       = "123456789012"
  billing_account      = "000000-000000-000000"
  state_bucket         = "your-unique-production-tofu-state-bucket"
  state_kms_key_id     = "projects/your-production-project-id/locations/europe-west1/keyRings/r/cryptoKeys/k"
  ci_github_repository = "example-owner/example-infra-repo"
  ci_github_owner_id   = "111111111"
  ci_github_repo_id    = "333333333"
  ci_sub_claim_prefix  = "repo:example-owner@111111111/example-infra-repo@333333333"
  services = {
    web = {
      service_name        = "your-service-name"
      github_repository   = "example-owner/example-repo"
      github_owner_id     = "111111111"
      github_repo_id      = "222222222"
      sub_claim_prefix    = "repo:example-owner@111111111/example-repo@222222222"
      deployer_account_id = "gh-deployer-web"
      secret_keys         = ["stats-pass"]
    }
    site = {
      service_name        = "your-site-name"
      github_repository   = "example-owner/example.site"
      github_owner_id     = "111111111"
      github_repo_id      = "444444444"
      sub_claim_prefix    = "repo:example-owner@111111111/example.site@444444444"
      deployer_account_id = "gh-deployer-site"
      secret_keys         = ["stats-pass", "api-key"]
    }
  }
}

override_resource {
  target = module.ci_planner.google_service_account.planner
  values = {
    name  = "projects/your-production-project-id/serviceAccounts/tofu-planner@your-production-project-id.iam.gserviceaccount.com"
    email = "tofu-planner@your-production-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif_primary["site"].google_service_account.deployer["production"]
  values = {
    name  = "projects/your-production-project-id/serviceAccounts/gh-deployer-site@your-production-project-id.iam.gserviceaccount.com"
    email = "gh-deployer-site@your-production-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif["web"].google_service_account.deployer["production"]
  values = {
    name  = "projects/your-production-project-id/serviceAccounts/gh-deployer-web@your-production-project-id.iam.gserviceaccount.com"
    email = "gh-deployer-web@your-production-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.gke.google_container_cluster.this
  values = {
    control_plane_endpoints_config = {
      dns_endpoint_config = { endpoint = "gke-example.europe-west1.gke.goog" }
    }
  }
}

run "outputs_map_onto_the_template_variables" {
  command = plan

  assert {
    condition     = output.GCP_PROJECT_ID == "your-production-project-id" && output.GKE_CLUSTER == "prod" && output.GKE_LOCATION == "europe-west1"
    error_message = "GCP_PROJECT_ID, GKE_CLUSTER and GKE_LOCATION"
  }
  assert {
    condition = output.GCP_WIF_PROVIDER == {
      site = "projects/123456789012/locations/global/workloadIdentityPools/gh-site/providers/github-oidc"
      web  = "projects/123456789012/locations/global/workloadIdentityPools/gh-web/providers/github-oidc"
    }
    error_message = "one provider per service, in its own pool"
  }
  assert {
    condition = output.GCP_DEPLOYER_SA == {
      site = "gh-deployer-site@your-production-project-id.iam.gserviceaccount.com"
      web  = "gh-deployer-web@your-production-project-id.iam.gserviceaccount.com"
    }
    error_message = "one deployer per service"
  }
  assert {
    condition     = output.CI_WIF_PROVIDER == "projects/123456789012/locations/global/workloadIdentityPools/github-infra/providers/lodestar-infra" && output.CI_SERVICE_ACCOUNT == "tofu-planner@your-production-project-id.iam.gserviceaccount.com"
    error_message = "the planner identity outputs"
  }
  assert {
    condition     = output.CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID == "cloudflared-tunnel-token"
    error_message = "the tunnel token secret id"
  }
}

# The resolved resource attributes of the modules are covered by each module's own tests; outputs are all a
# root test can reach, and tests/envs-prod.bats checks the arguments the root passes.
run "two_services_two_pools_one_custom_role_owner" {
  command = plan

  assert {
    condition     = keys(module.github_wif_primary) == ["site"] && keys(module.github_wif) == ["web"]
    error_message = "the first key in sorted order is the one call that creates the custom role; the other follows"
  }
  assert {
    condition     = module.github_wif_primary["site"].workload_identity_provider != module.github_wif["web"].workload_identity_provider
    error_message = "each service has its own pool"
  }
  assert {
    condition     = module.github_wif["web"].preview_workload_identity_provider == null && length(module.github_wif["web"].drift_workload_identity_providers) == 0 && module.github_wif_primary["site"].preview_workload_identity_provider == null && length(module.github_wif_primary["site"].drift_workload_identity_providers) == 0
    error_message = "previews and drift are off"
  }
  assert {
    condition     = keys(module.github_wif_primary["site"].deployer_emails) == ["production"] && keys(module.github_wif["web"].deployer_emails) == ["production"]
    error_message = "production is the only environment"
  }
}

run "secrets_per_service_production_only" {
  command = plan

  assert {
    condition     = module.secrets["web"].secret_ids == { "production-stats-pass" = "your-service-name-production-stats-pass" }
    error_message = "web: one production secret"
  }
  assert {
    condition     = module.secrets["site"].secret_ids == { "production-stats-pass" = "your-site-name-production-stats-pass", "production-api-key" = "your-site-name-production-api-key" }
    error_message = "site: its own production secrets"
  }
  assert {
    condition     = length(module.secrets["web"].binding_titles) == 1 && length(module.secrets["site"].binding_titles) == 1
    error_message = "one app binding per service, no db binding"
  }
  assert {
    condition     = keys(module.platform_secrets.secret_ids) == ["cloudflared-tunnel-token"]
    error_message = "exactly the one platform secret"
  }
}

run "project_apis" {
  command = plan

  assert {
    condition     = module.project.services == sort(["billingbudgets.googleapis.com", "cloudresourcemanager.googleapis.com", "compute.googleapis.com", "container.googleapis.com", "iam.googleapis.com", "iamcredentials.googleapis.com", "secretmanager.googleapis.com", "sts.googleapis.com"])
    error_message = "the apps APIs minus artifactregistry; cloudkms is the bootstrap's"
  }
}

run "network_names" {
  command = plan

  assert {
    condition     = module.network.network_name == "prod-vpc" && module.network.subnet_name == "prod-subnet"
    error_message = "prod network and subnet"
  }
}

run "secrets_key_is_wired_to_the_cluster" {
  command = plan

  assert {
    condition     = module.gke_secrets_key.key_id == "projects/your-production-project-id/locations/europe-west1/keyRings/prod-gke/cryptoKeys/prod-secrets"
    error_message = "production's own ring and key"
  }
}

run "one_service_has_no_second_call" {
  command = plan

  variables {
    services = {
      site = {
        service_name        = "your-site-name"
        github_repository   = "example-owner/example.site"
        github_owner_id     = "111111111"
        github_repo_id      = "444444444"
        sub_claim_prefix    = "repo:example-owner@111111111/example.site@444444444"
        deployer_account_id = "gh-deployer-site"
        secret_keys         = ["stats-pass"]
      }
    }
  }

  assert {
    condition     = keys(module.github_wif_primary) == ["site"] && length(module.github_wif) == 0
    error_message = "a single service owns the role"
  }
}

run "empty_services_rejected" {
  command = plan
  variables {
    services = {}
  }
  expect_failures = [var.services]
}

run "duplicate_deployer_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o/a", deployer_account_id = "gh-deployer-x", secret_keys = [] }
      b-svc = { service_name = "two-name", github_repository = "o/b", github_owner_id = "1", github_repo_id = "3", sub_claim_prefix = "repo:o/b", deployer_account_id = "gh-deployer-x", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "duplicate_service_name_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "same-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o/a", deployer_account_id = "gh-deployer-a", secret_keys = [] }
      b-svc = { service_name = "same-name", github_repository = "o/b", github_owner_id = "1", github_repo_id = "3", sub_claim_prefix = "repo:o/b", deployer_account_id = "gh-deployer-b", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "short_deployer_id_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o/a", deployer_account_id = "ab", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}
