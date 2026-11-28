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
  target = module.github_wif["site"].google_service_account.deployer["production"]
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
  target = module.github_wif["site"].google_service_account.drift["production"]
  values = {
    name  = "projects/your-production-project-id/serviceAccounts/gh-drift-site@your-production-project-id.iam.gserviceaccount.com"
    email = "gh-drift-site@your-production-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif["web"].google_service_account.drift["production"]
  values = {
    name  = "projects/your-production-project-id/serviceAccounts/gh-drift-web@your-production-project-id.iam.gserviceaccount.com"
    email = "gh-drift-web@your-production-project-id.iam.gserviceaccount.com"
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
run "two_services_two_pools_one_role" {
  command = plan

  assert {
    condition     = keys(module.github_wif) == ["site", "web"]
    error_message = "one call per service"
  }
  assert {
    condition     = module.github_wif["site"].workload_identity_provider != module.github_wif["web"].workload_identity_provider
    error_message = "each service has its own pool"
  }
  assert {
    condition     = alltrue([for m in values(module.github_wif) : m.preview_workload_identity_provider == null && keys(m.drift_workload_identity_providers) == ["production"] && keys(m.deployer_emails) == ["production"]])
    error_message = "previews are off, drift is production only; production is the only environment"
  }
  assert {
    condition     = module.connect_role.role_name == "projects/your-production-project-id/roles/gkeDnsConnect"
    error_message = "the one custom role"
  }
  assert {
    condition     = module.github_wif["site"].deployer_cluster_roles == { production = "projects/your-production-project-id/roles/gkeDnsConnect" } && module.github_wif["web"].deployer_cluster_roles == { production = "projects/your-production-project-id/roles/gkeDnsConnect" }
    error_message = "every deployer holds the one connect role and nothing else"
  }
}

# Each pool admits only its own repository (owner and repo IDs, workflow files) and the production environment;
# each deployer is bound to its own immutable production subject.
run "identity_wiring_per_service" {
  command = plan

  assert {
    condition     = module.github_wif["web"].provider_attribute_condition == "assertion.repository_owner_id=='111111111' && assertion.repository_id=='222222222' && assertion.environment=='production' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"
    error_message = "web pool condition"
  }
  assert {
    condition     = module.github_wif["site"].provider_attribute_condition == "assertion.repository_owner_id=='111111111' && assertion.repository_id=='444444444' && assertion.environment=='production' && assertion.job_workflow_ref.matches('^example-owner/example\\\\.site/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"
    error_message = "site pool condition"
  }
  assert {
    condition     = module.github_wif["web"].deployer_wif_members == { production = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/gh-web/subject/repo:example-owner@111111111/example-repo@222222222:environment:production" }
    error_message = "web deployer member"
  }
  assert {
    condition     = module.github_wif["site"].deployer_wif_members == { production = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/gh-site/subject/repo:example-owner@111111111/example.site@444444444:environment:production" }
    error_message = "site deployer member"
  }
  assert {
    condition     = output.GCP_WIF_PROVIDER["web"] == "projects/123456789012/locations/global/workloadIdentityPools/gh-web/providers/github-oidc"
    error_message = "provider belongs to the web pool"
  }
}

# L4.8: one drift-production reader per service, in the service's own pool, read-only.
run "drift_identity_per_service" {
  command = plan

  assert {
    condition = output.DRIFT_WIF_PROVIDER == {
      site = "projects/123456789012/locations/global/workloadIdentityPools/gh-site/providers/github-oidc-drift-production"
      web  = "projects/123456789012/locations/global/workloadIdentityPools/gh-web/providers/github-oidc-drift-production"
    }
    error_message = "exactly one drift provider per service, in its own pool"
  }
  assert {
    condition = output.DRIFT_SA == {
      site = "gh-drift-site@your-production-project-id.iam.gserviceaccount.com"
      web  = "gh-drift-web@your-production-project-id.iam.gserviceaccount.com"
    }
    error_message = "one drift reader per service"
  }
  assert {
    condition     = module.github_wif["web"].drift_condition == { production = "assertion.repository_owner_id=='111111111' && assertion.repository_id=='222222222' && assertion.environment=='drift-production' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')" }
    error_message = "web drift condition admits only its repository, drift-production and drift.yml on main"
  }
  assert {
    condition     = module.github_wif["site"].drift_condition == { production = "assertion.repository_owner_id=='111111111' && assertion.repository_id=='444444444' && assertion.environment=='drift-production' && assertion.job_workflow_ref.matches('^example-owner/example\\\\.site/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')" }
    error_message = "site drift condition"
  }
  assert {
    condition     = module.github_wif["web"].drift_wif_members == { production = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/gh-web/subject/repo:example-owner@111111111/example-repo@222222222:environment:drift-production" }
    error_message = "web drift member"
  }
  assert {
    condition     = module.github_wif["site"].drift_wif_members == { production = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/gh-site/subject/repo:example-owner@111111111/example.site@444444444:environment:drift-production" }
    error_message = "site drift member"
  }
  assert {
    condition     = alltrue([for m in values(module.github_wif) : m.drift_cluster_roles == { production = "projects/your-production-project-id/roles/gkeDnsConnect" }])
    error_message = "the drift reader holds only the custom connect role (get and connect)"
  }
}

run "planner_uses_the_ci_inputs" {
  command = plan

  assert {
    condition     = module.ci_planner.ci_attribute_condition == "assertion.repository_owner_id=='111111111' && assertion.repository_id=='333333333' && assertion.event_name in ['pull_request', 'schedule', 'workflow_dispatch'] && assertion.job_workflow_ref.matches('^example-owner/example-infra-repo/\\\\.github/workflows/(plan|drift)\\\\.yml@refs/(heads/main|pull/[0-9]+/merge)$')"
    error_message = "planner condition from the ci_* inputs"
  }
  assert {
    condition = module.ci_planner.ci_wif_members == sort([
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-infra/subject/repo:example-owner@111111111/example-infra-repo@333333333:pull_request",
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-infra/subject/repo:example-owner@111111111/example-infra-repo@333333333:ref:refs/heads/main",
    ])
    error_message = "planner members from the ci_* inputs"
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
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o@1/a@2", deployer_account_id = "gh-deployer-x", secret_keys = [] }
      b-svc = { service_name = "two-name", github_repository = "o/b", github_owner_id = "1", github_repo_id = "3", sub_claim_prefix = "repo:o@1/b@3", deployer_account_id = "gh-deployer-x", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "duplicate_service_name_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "same-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o@1/a@2", deployer_account_id = "gh-deployer-a", secret_keys = [] }
      b-svc = { service_name = "same-name", github_repository = "o/b", github_owner_id = "1", github_repo_id = "3", sub_claim_prefix = "repo:o@1/b@3", deployer_account_id = "gh-deployer-b", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "deployer_id_with_the_drift_prefix_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o@1/a@2", deployer_account_id = "gh-drift-a-svc", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "short_deployer_id_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o@1/a@2", deployer_account_id = "ab", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "mismatched_prefix_rejected" {
  command = plan
  variables {
    services = {
      a-svc = { service_name = "one-name", github_repository = "o/a", github_owner_id = "1", github_repo_id = "2", sub_claim_prefix = "repo:o@1/a@3", deployer_account_id = "gh-deployer-a", secret_keys = [] }
    }
  }
  expect_failures = [var.services]
}

run "mismatched_ci_prefix_rejected" {
  command = plan
  variables {
    ci_sub_claim_prefix = "repo:example-owner@111111111/example-infra-repo@999"
  }
  expect_failures = [var.ci_sub_claim_prefix]
}
