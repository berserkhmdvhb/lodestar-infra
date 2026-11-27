# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/your-project-id/serviceAccounts/tofu-planner@your-project-id.iam.gserviceaccount.com"
      email = "tofu-planner@your-project-id.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id        = "your-project-id"
  project_number    = "123456789"
  github_repository = "example-owner/example.repo"
  github_owner_id   = "123"
  github_repo_id    = "456"
  sub_claim_prefix  = "repo:example-owner@123/example.repo@456"
  state_bucket      = "your-state-bucket"
  state_kms_key_id  = "projects/your-project-id/locations/europe-west1/keyRings/r/cryptoKeys/k"
  billing_account   = "000000-000000-000000"
}

run "condition_is_exact_and_escapes_the_repository_name" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.ci.attribute_condition == "assertion.repository_owner_id=='123' && assertion.repository_id=='456' && assertion.event_name in ['pull_request', 'schedule', 'workflow_dispatch'] && assertion.job_workflow_ref.matches('^example-owner/example\\\\.repo/\\\\.github/workflows/(plan|drift)\\\\.yml@refs/(heads/main|pull/[0-9]+/merge)$')"
    error_message = "attribute condition must be the exact stored text, with the dots of the repository name escaped"
  }
}

run "pool_provider_and_outputs" {
  command = plan

  assert {
    condition = (
      google_iam_workload_identity_pool.ci.workload_identity_pool_id == "github-infra"
      && google_iam_workload_identity_pool_provider.ci.workload_identity_pool_provider_id == "lodestar-infra"
      && one(google_iam_workload_identity_pool_provider.ci.oidc).issuer_uri == "https://token.actions.githubusercontent.com"
    )
    error_message = "default pool id, provider id and issuer"
  }
  assert {
    condition = google_iam_workload_identity_pool_provider.ci.attribute_mapping == tomap({
      "google.subject"                = "assertion.sub"
      "attribute.repository_id"       = "assertion.repository_id"
      "attribute.repository_owner_id" = "assertion.repository_owner_id"
      "attribute.job_workflow_ref"    = "assertion.job_workflow_ref"
      "attribute.ref"                 = "assertion.ref"
      "attribute.event_name"          = "assertion.event_name"
    })
    error_message = "attribute mapping"
  }
  assert {
    condition     = output.ci_workload_identity_provider == "projects/123456789/locations/global/workloadIdentityPools/github-infra/providers/lodestar-infra"
    error_message = "provider resource name output"
  }
  assert {
    condition     = output.ci_service_account == "tofu-planner@your-project-id.iam.gserviceaccount.com"
    error_message = "service account output"
  }
}

run "service_account_and_exactly_two_subjects" {
  command = plan

  assert {
    condition     = google_service_account.planner.account_id == "tofu-planner" && google_service_account.planner.display_name == "OpenTofu planner (CI, read-only)"
    error_message = "account id and display name"
  }
  assert {
    condition = (
      length(google_service_account_iam_member.wif) == 2
      && alltrue([for m in google_service_account_iam_member.wif : m.role == "roles/iam.workloadIdentityUser"])
      && toset([for m in google_service_account_iam_member.wif : m.member]) == toset([
        "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github-infra/subject/repo:example-owner@123/example.repo@456:pull_request",
        "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github-infra/subject/repo:example-owner@123/example.repo@456:ref:refs/heads/main",
      ])
    )
    error_message = "exactly the pull_request and main subjects"
  }
}

run "exact_role_sets_and_scopes" {
  command = plan

  assert {
    condition = (
      length(google_project_iam_member.planner) == 3
      && toset([for m in google_project_iam_member.planner : m.role]) == toset(["roles/viewer", "roles/iam.securityReviewer", "roles/serviceusage.serviceUsageConsumer"])
      && alltrue([for m in google_project_iam_member.planner : m.project == "your-project-id" && m.member == "serviceAccount:tofu-planner@your-project-id.iam.gserviceaccount.com"])
    )
    error_message = "exactly the three read-only project roles"
  }
  assert {
    condition = (
      google_storage_bucket_iam_member.state.bucket == "your-state-bucket"
      && google_storage_bucket_iam_member.state.role == "roles/storage.objectViewer"
      && google_storage_bucket_iam_member.state.member == "serviceAccount:tofu-planner@your-project-id.iam.gserviceaccount.com"
    )
    error_message = "objectViewer on the state bucket only"
  }
  assert {
    condition = (
      google_kms_crypto_key_iam_member.state.crypto_key_id == "projects/your-project-id/locations/europe-west1/keyRings/r/cryptoKeys/k"
      && google_kms_crypto_key_iam_member.state.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      && google_kms_crypto_key_iam_member.state.member == "serviceAccount:tofu-planner@your-project-id.iam.gserviceaccount.com"
    )
    error_message = "encrypter/decrypter on the state key only"
  }
  assert {
    condition = (
      google_billing_account_iam_member.viewer.billing_account_id == "000000-000000-000000"
      && google_billing_account_iam_member.viewer.role == "roles/billing.viewer"
      && google_billing_account_iam_member.viewer.member == "serviceAccount:tofu-planner@your-project-id.iam.gserviceaccount.com"
    )
    error_message = "billing.viewer on the billing account"
  }
}

run "cloud_billing_api_is_enabled_and_kept" {
  command = plan

  assert {
    condition = (
      google_project_service.cloudbilling.service == "cloudbilling.googleapis.com"
      && google_project_service.cloudbilling.project == "your-project-id"
      && google_project_service.cloudbilling.disable_on_destroy == false
      && google_project_service.cloudbilling.disable_dependent_services == false
    )
    error_message = "the Cloud Billing API is enabled in the project and left on at destroy"
  }
}

run "no_forbidden_roles_anywhere" {
  command = plan

  assert {
    condition = alltrue([for r in concat(
      [for m in google_project_iam_member.planner : m.role],
      [for m in google_service_account_iam_member.wif : m.role],
      [google_storage_bucket_iam_member.state.role, google_kms_crypto_key_iam_member.state.role, google_billing_account_iam_member.viewer.role],
      ) : !contains(["roles/editor", "roles/owner", "roles/storage.admin", "roles/storage.objectAdmin", "roles/storage.objectUser", "roles/iam.serviceAccountTokenCreator", "roles/iam.serviceAccountUser", "roles/billing.admin", "roles/billing.user", "roles/cloudkms.admin", "roles/resourcemanager.projectIamAdmin"], r)
      && !endswith(lower(r), "admin") && !strcontains(lower(r), "writer")
    ])
    error_message = "no write, admin, owner or editor role"
  }
}

run "sub_claim_prefix_rejects_environment_suffix" {
  command = plan

  variables {
    sub_claim_prefix = "repo:example-owner@123/example.repo@456:environment:dev"
  }

  expect_failures = [var.sub_claim_prefix]
}

run "repository_name_rejects_quote" {
  command = plan

  variables {
    github_repository = "example-owner/exa'mple"
  }

  expect_failures = [var.github_repository]
}
