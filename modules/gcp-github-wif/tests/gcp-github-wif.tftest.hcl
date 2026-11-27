# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/your-project-id/serviceAccounts/mock@your-project-id.iam.gserviceaccount.com"
      email = "mock@your-project-id.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id        = "your-project-id"
  project_number    = "123456789"
  github_repository = "example-owner/example-repo"
  github_owner_id   = "123"
  github_repo_id    = "456"
  sub_claim_prefix  = "repo:example-owner@123/example-repo@456"
}

run "condition_is_exact_and_has_both_ids" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"
    error_message = "attribute condition must be the exact stored text"
  }
  assert {
    condition     = google_iam_workload_identity_pool.github.workload_identity_pool_id == "github" && google_iam_workload_identity_pool.github.display_name == "GitHub Actions"
    error_message = "pool id and display name"
  }
  assert {
    condition = (
      google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id == "github-oidc"
      && google_iam_workload_identity_pool_provider.github.display_name == "GitHub OIDC"
      && one(google_iam_workload_identity_pool_provider.github.oidc).issuer_uri == "https://token.actions.githubusercontent.com"
    )
    error_message = "provider id, display name, issuer"
  }
  assert {
    condition = google_iam_workload_identity_pool_provider.github.attribute_mapping == tomap({
      "google.subject"                = "assertion.sub"
      "attribute.repository"          = "assertion.repository"
      "attribute.repository_owner_id" = "assertion.repository_owner_id"
      "attribute.repository_id"       = "assertion.repository_id"
      "attribute.job_workflow_ref"    = "assertion.job_workflow_ref"
      "attribute.ref"                 = "assertion.ref"
    })
    error_message = "attribute mapping"
  }
  assert {
    condition     = output.workload_identity_provider == "projects/123456789/locations/global/workloadIdentityPools/github/providers/github-oidc"
    error_message = "provider resource name output"
  }
}

run "one_service_account_per_environment_with_exact_members" {
  command = plan

  assert {
    condition     = length(google_service_account.deployer) == 3 && toset(keys(google_service_account.deployer)) == toset(["dev", "qa", "production"])
    error_message = "one service account per environment"
  }
  assert {
    condition = alltrue([for e, s in google_service_account.deployer :
      s.account_id == "gh-deployer-${e}" && s.display_name == "GitHub Actions deployer (${e})"
    ])
    error_message = "account ids and display names"
  }
  assert {
    condition = alltrue([for e, m in google_service_account_iam_member.wif :
      m.role == "roles/iam.workloadIdentityUser"
      && m.member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github/subject/repo:example-owner@123/example-repo@456:environment:${e}"
    ])
    error_message = "workloadIdentityUser member per environment"
  }
  assert {
    condition     = length(google_service_account_iam_member.wif) == 3
    error_message = "one binding per environment"
  }
}

run "cluster_role_default_is_cluster_viewer" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.cluster) == 3 && alltrue([for m in google_project_iam_member.cluster : m.role == "roles/container.clusterViewer"])
    error_message = "clusterViewer for each deployer"
  }
  assert {
    condition     = length(google_project_iam_custom_role.connect) == 0
    error_message = "no custom role by default"
  }
}

run "custom_connect_role_replaces_cluster_viewer" {
  command = plan

  variables {
    create_custom_connect_role = true
  }

  assert {
    condition = (
      google_project_iam_custom_role.connect[0].role_id == "gkeDnsConnect"
      && google_project_iam_custom_role.connect[0].title == "GKE DNS endpoint connect"
      && google_project_iam_custom_role.connect[0].stage == "GA"
      && toset(google_project_iam_custom_role.connect[0].permissions) == toset(["container.clusters.get", "container.clusters.connect"])
      && length(google_project_iam_custom_role.connect[0].permissions) == 2
    )
    error_message = "custom role with exactly the two permissions"
  }
  assert {
    condition     = alltrue([for m in google_project_iam_member.cluster : m.role == "projects/your-project-id/roles/gkeDnsConnect"])
    error_message = "deployers use the custom role"
  }
}

run "previews_and_drift_off_by_default" {
  command = plan

  assert {
    condition = (
      length(google_iam_workload_identity_pool_provider.preview) == 0
      && length(google_service_account.preview) == 0
      && length(google_iam_workload_identity_pool_provider.drift) == 0
      && length(google_service_account.drift) == 0
      && output.preview_workload_identity_provider == null
      && length(output.drift_workload_identity_providers) == 0
    )
    error_message = "optional parts create nothing by default"
  }
}

run "previews_enabled" {
  command = plan

  variables {
    enable_previews = true
  }

  assert {
    condition = (
      google_iam_workload_identity_pool_provider.preview[0].workload_identity_pool_provider_id == "github-oidc-preview"
      && google_iam_workload_identity_pool_provider.preview[0].display_name == "GitHub OIDC (previews)"
      && google_iam_workload_identity_pool_provider.preview[0].attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.environment=='preview' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/preview\\\\.yml@refs/(pull/[0-9]+/merge|heads/main)$')"
    )
    error_message = "preview provider and exact condition"
  }
  assert {
    condition     = google_service_account.preview[0].account_id == "gh-deployer-preview" && google_service_account.preview[0].display_name == "GitHub Actions deployer (preview)"
    error_message = "preview deployer"
  }
  assert {
    condition = (
      google_service_account_iam_member.preview[0].role == "roles/iam.workloadIdentityUser"
      && google_service_account_iam_member.preview[0].member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github/subject/repo:example-owner@123/example-repo@456:environment:preview"
      && google_project_iam_member.preview[0].role == "roles/container.clusterViewer"
    )
    error_message = "preview binding uses the immutable-aware prefix and the cluster role"
  }
  assert {
    condition     = output.preview_workload_identity_provider == "projects/123456789/locations/global/workloadIdentityPools/github/providers/github-oidc-preview"
    error_message = "preview provider output"
  }
}

run "drift_enabled" {
  command = plan

  variables {
    enable_drift = true
  }

  assert {
    condition     = length(google_iam_workload_identity_pool_provider.drift) == 3 && length(google_service_account.drift) == 3
    error_message = "one drift provider and reader per environment"
  }
  assert {
    condition = alltrue([for e, p in google_iam_workload_identity_pool_provider.drift :
      p.workload_identity_pool_provider_id == "github-oidc-drift-${e}"
      && p.display_name == "GitHub OIDC (drift ${e})"
      && p.attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.environment=='drift-${e}' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')"
    ])
    error_message = "drift providers and exact conditions"
  }
  assert {
    condition = alltrue([for e, s in google_service_account.drift :
      s.account_id == "gh-drift-${e}" && s.display_name == "GitHub Actions drift reader (${e})"
    ])
    error_message = "drift reader accounts"
  }
  assert {
    condition = alltrue([for e, m in google_service_account_iam_member.drift :
      m.role == "roles/iam.workloadIdentityUser"
      && m.member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github/subject/repo:example-owner@123/example-repo@456:environment:drift-${e}"
    ]) && alltrue([for m in google_project_iam_member.drift : m.role == "roles/container.clusterViewer"])
    error_message = "drift bindings: own subject, connect role only"
  }
  assert {
    condition     = output.drift_workload_identity_providers["dev"] == "projects/123456789/locations/global/workloadIdentityPools/github/providers/github-oidc-drift-dev"
    error_message = "drift provider output"
  }
}

run "no_forbidden_roles_anywhere" {
  command = plan

  variables {
    enable_previews            = true
    enable_drift               = true
    create_custom_connect_role = true
  }

  assert {
    condition = alltrue([for r in concat(
      [for m in google_project_iam_member.cluster : m.role],
      [for m in google_project_iam_member.preview : m.role],
      [for m in google_project_iam_member.drift : m.role],
      [for m in google_service_account_iam_member.wif : m.role],
      [for m in google_service_account_iam_member.preview : m.role],
      [for m in google_service_account_iam_member.drift : m.role],
      ) : !contains(["roles/editor", "roles/owner", "roles/artifactregistry.writer", "roles/container.developer", "roles/container.viewer"], r)
    ])
    error_message = "no editor, owner, registry writer, container developer or viewer"
  }
}

run "sub_claim_prefix_rejects_environment_suffix" {
  command = plan

  variables {
    sub_claim_prefix = "repo:x/y:environment:dev"
  }

  expect_failures = [var.sub_claim_prefix]
}

run "sub_claim_prefix_rejects_missing_repo_prefix" {
  command = plan

  variables {
    sub_claim_prefix = "example-owner/example-repo"
  }

  expect_failures = [var.sub_claim_prefix]
}

run "sub_claim_prefix_rejects_trailing_colon" {
  command = plan

  variables {
    sub_claim_prefix = "repo:x/y:"
  }

  expect_failures = [var.sub_claim_prefix]
}

run "ids_must_be_digits" {
  command = plan

  variables {
    project_number  = "abc"
    github_owner_id = "12x"
  }

  expect_failures = [var.project_number, var.github_owner_id]
}

run "repository_must_look_like_owner_repo" {
  command = plan

  variables {
    github_repository = "no-slash"
  }

  expect_failures = [var.github_repository]
}

run "repository_with_extra_slash_rejected" {
  command = plan

  variables {
    github_repository = "a/b/c"
  }

  expect_failures = [var.github_repository]
}

run "underscore_repository_renders_unescaped" {
  command = plan

  variables {
    github_repository = "example_owner/name_with_underscores"
    enable_previews   = true
    enable_drift      = true
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.job_workflow_ref.matches('^example_owner/name_with_underscores/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"
    error_message = "main condition must be byte-identical for a name without regex metacharacters"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.preview[0].attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.environment=='preview' && assertion.job_workflow_ref.matches('^example_owner/name_with_underscores/\\\\.github/workflows/preview\\\\.yml@refs/(pull/[0-9]+/merge|heads/main)$')"
    error_message = "preview condition must be byte-identical for a name without regex metacharacters"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.drift["dev"].attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.environment=='drift-dev' && assertion.job_workflow_ref.matches('^example_owner/name_with_underscores/\\\\.github/workflows/drift\\\\.yml@refs/heads/main$')"
    error_message = "drift condition must be byte-identical for a name without regex metacharacters"
  }
}

run "dot_in_repository_is_regex_escaped" {
  command = plan

  variables {
    github_repository = "example-owner/example.repo"
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "matches('^example-owner/example\\\\.repo/")
    error_message = "a dot in the repository name must be escaped like in gcp-ci-planner"
  }
}

# L4.1: allowed_environment and deployer IDs. Defaults render today's exact values (also asserted above).
run "defaults_have_no_environment_term_and_todays_deployer_ids" {
  command = plan

  assert {
    condition     = !strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.environment")
    error_message = "no environment term by default"
  }
  assert {
    condition     = alltrue([for e, s in google_service_account.deployer : s.account_id == "gh-deployer-${e}"])
    error_message = "default deployer ids are gh-deployer-<env>"
  }
}

run "production_provider_admits_only_the_production_environment" {
  command = plan

  variables {
    environments         = ["production"]
    allowed_environment  = "production"
    pool_id              = "github-example-repo"
    deployer_account_ids = { production = "gh-example-repo-prod" }
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.environment=='production' && assertion.job_workflow_ref.matches('^example-owner/example-repo/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)$')"
    error_message = "exact condition with the environment term"
  }
  assert {
    condition = (
      keys(google_service_account.deployer) == ["production"]
      && google_service_account.deployer["production"].account_id == "gh-example-repo-prod"
      && google_iam_workload_identity_pool.github.workload_identity_pool_id == "github-example-repo"
      && google_service_account_iam_member.wif["production"].member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github-example-repo/subject/repo:example-owner@123/example-repo@456:environment:production"
    )
    error_message = "one production deployer bound to the immutable production subject in its own pool"
  }
}

# Several repositories: one module call per repository, each with its own pool, provider and deployer
# (a pool per repository is at least as isolated as a shared pool). This is the second repository.
run "second_repository_gets_its_own_pool_and_condition" {
  command = plan

  variables {
    github_repository    = "example-owner/other-repo"
    github_repo_id       = "789"
    sub_claim_prefix     = "repo:example-owner@123/other-repo@789"
    environments         = ["production"]
    allowed_environment  = "production"
    pool_id              = "github-other-repo"
    deployer_account_ids = { production = "gh-other-repo-prod" }
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository_id=='789' && assertion.environment=='production'") && strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "'^example-owner/other-repo/")
    error_message = "the second repository's provider pins its own repository ID"
  }
  assert {
    condition     = !strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "'456'") && !strcontains(google_service_account_iam_member.wif["production"].member, "example-repo")
    error_message = "a foreign repository (the first one) is not admitted"
  }
  assert {
    condition     = google_service_account.deployer["production"].account_id == "gh-other-repo-prod" && output.workload_identity_provider == "projects/123456789/locations/global/workloadIdentityPools/github-other-repo/providers/github-oidc"
    error_message = "own deployer and own pool"
  }
}

run "environment_term_sits_between_repository_and_workflow_terms" {
  command = plan

  variables {
    allowed_environment = "staging"
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository_id=='456' && assertion.environment=='staging' && assertion.job_workflow_ref")
    error_message = "environment term position and value"
  }
}

run "allowed_environment_rejects_quote_injection" {
  command = plan

  variables {
    allowed_environment = "production' || true || '"
  }

  expect_failures = [var.allowed_environment]
}

run "deployer_id_over_30_characters_is_refused" {
  command = plan

  variables {
    environments         = ["production"]
    deployer_account_ids = { production = "gh-deployer-example-repository-production" }
  }

  expect_failures = [var.deployer_account_ids]
}

run "deployer_id_badly_shaped_is_refused" {
  command = plan

  variables {
    environments         = ["production"]
    deployer_account_ids = { production = "Gh_Deployer" }
  }

  expect_failures = [var.deployer_account_ids]
}

run "deployer_id_for_an_unknown_environment_is_refused" {
  command = plan

  variables {
    deployer_account_ids = { nonsense = "gh-deployer-nonsense" }
  }

  expect_failures = [var.deployer_account_ids]
}
