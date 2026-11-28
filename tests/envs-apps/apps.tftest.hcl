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
  ci_github_repository = "example-owner/example-infra-repo"
  ci_github_repo_id    = "333333333"
  ci_sub_claim_prefix  = "repo:example-owner@111111111/example-infra-repo@333333333"
}

override_resource {
  target = module.ci_planner.google_service_account.planner
  values = {
    name  = "projects/your-project-id/serviceAccounts/tofu-planner@your-project-id.iam.gserviceaccount.com"
    email = "tofu-planner@your-project-id.iam.gserviceaccount.com"
  }
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
  target = module.github_wif.google_service_account.drift["dev"]
  values = {
    name  = "projects/your-project-id/serviceAccounts/gh-drift-dev@your-project-id.iam.gserviceaccount.com"
    email = "gh-drift-dev@your-project-id.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.github_wif.google_service_account.drift["qa"]
  values = {
    name  = "projects/your-project-id/serviceAccounts/gh-drift-qa@your-project-id.iam.gserviceaccount.com"
    email = "gh-drift-qa@your-project-id.iam.gserviceaccount.com"
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

run "ci_identity_outputs" {
  command = plan

  assert {
    condition     = output.CI_WIF_PROVIDER == "projects/123456789012/locations/global/workloadIdentityPools/github-infra/providers/lodestar-infra"
    error_message = "CI_WIF_PROVIDER is the CI provider full name"
  }
  assert {
    condition     = output.CI_SERVICE_ACCOUNT == "tofu-planner@your-project-id.iam.gserviceaccount.com"
    error_message = "CI_SERVICE_ACCOUNT is the planner e-mail"
  }
}

run "dns_endpoint_is_exposed" {
  command = apply

  assert {
    condition     = output.dns_endpoint != null
    error_message = "dns_endpoint must not be null"
  }
}

# L4.8: dev and qa get a read-only drift reader; production moves to envs/prod. Nothing else changes.
run "drift_readers_for_dev_and_qa_only" {
  command = plan

  assert {
    condition = output.DRIFT_WIF_PROVIDER == {
      dev = "projects/123456789012/locations/global/workloadIdentityPools/github/providers/github-oidc-drift-dev"
      qa  = "projects/123456789012/locations/global/workloadIdentityPools/github/providers/github-oidc-drift-qa"
    }
    error_message = "DRIFT_WIF_PROVIDER: dev and qa only"
  }
  assert {
    condition = output.DRIFT_SA == {
      dev = "gh-drift-dev@your-project-id.iam.gserviceaccount.com"
      qa  = "gh-drift-qa@your-project-id.iam.gserviceaccount.com"
    }
    error_message = "DRIFT_SA: dev and qa only"
  }
  assert {
    condition     = module.github_wif.drift_cluster_roles == { dev = "roles/container.clusterViewer", qa = "roles/container.clusterViewer" } && module.github_wif.drift_cluster_roles == { for e in ["dev", "qa"] : e => module.github_wif.deployer_cluster_roles[e] }
    error_message = "drift readers hold the deployer's connect role and nothing else"
  }
  assert {
    condition     = module.github_wif.drift_wif_members["qa"] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github/subject/repo:example-owner/example-repo:environment:drift-qa"
    error_message = "the exact drift-qa subject"
  }
  assert {
    condition     = module.github_wif.drift_condition["dev"] == "assertion.repository_owner_id=='111111111' && assertion.repository_id=='222222222' && assertion.environment=='drift-dev' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')"
    error_message = "the exact dev drift condition"
  }
}

run "registry_off_budget_on_no_previews_drift_dev_qa" {
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
    condition     = module.github_wif.preview_workload_identity_provider == null && keys(module.github_wif.drift_workload_identity_providers) == ["dev", "qa"]
    error_message = "previews off; drift on for dev and qa only"
  }
}

# key_id is built from inputs, so it is known at plan and the cluster's ENCRYPTED state is reviewable.
run "secrets_key_is_wired_to_the_cluster" {
  command = plan

  assert {
    condition     = module.gke_secrets_key.key_id == "projects/your-project-id/locations/europe-west1/keyRings/gke/cryptoKeys/secrets"
    error_message = "the cluster must get the secrets key id"
  }
}

# The tunnel token container and its one conditional grant are new (2 adds); the gcp-secrets addresses and
# keys, which imports.tf targets, stay as they were.
run "cloudflared_tunnel_token_secret_and_grant" {
  command = plan

  assert {
    condition     = output.CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID == "cloudflared-tunnel-token"
    error_message = "the guide needs the secret id"
  }
  assert {
    condition     = keys(module.platform_secrets.secret_ids) == ["cloudflared-tunnel-token"]
    error_message = "exactly the one platform secret"
  }
  assert {
    condition     = length(module.secrets.secret_ids) == 7 && length(module.secrets.binding_titles) == 5
    error_message = "the seven app secrets and five bindings are unchanged"
  }
}

# The import list in imports.tf is derived from these locals; they must equal the module defaults.
run "import_lists_equal_the_module_defaults" {
  command = plan

  assert {
    condition     = sort(local.services) == module.defaults_project.services
    error_message = "local.services must equal the gcp-project default services"
  }
  assert {
    condition     = module.secrets.secret_ids == module.defaults_secrets.secret_ids
    error_message = "local.secret_keys must equal the gcp-secrets default secret_keys"
  }
  assert {
    condition     = local.service_name == "your-service-name"
    error_message = "local.service_name must stay the gcp-secrets default"
  }
}
