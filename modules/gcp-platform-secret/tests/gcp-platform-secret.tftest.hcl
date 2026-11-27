# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id     = "your-project-id"
  project_number = "123456789012"
  secrets = {
    "cloudflared-tunnel-token" = { namespace = "cloudflared" }
  }
}

run "secret_name_and_replication" {
  command = plan

  assert {
    condition     = keys(google_secret_manager_secret.this) == ["cloudflared-tunnel-token"]
    error_message = "one secret keyed by its id"
  }
  assert {
    condition = alltrue([for k, s in google_secret_manager_secret.this :
      s.secret_id == k
      && length(one(s.replication).user_managed) == 1
      && one(one(one(s.replication).user_managed).replicas).location == "europe-west1"
      && length(one(s.replication).auto) == 0
    ])
    error_message = "secret id and user-managed replication in the region"
  }
  assert {
    condition     = output.secret_ids == { "cloudflared-tunnel-token" = "cloudflared-tunnel-token" }
    error_message = "secret id output"
  }
}

run "exactly_one_exact_conditional_member" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.this) == 1
    error_message = "exactly one member"
  }
  assert {
    condition     = google_project_iam_member.this["cloudflared-tunnel-token"].role == "roles/secretmanager.secretAccessor"
    error_message = "role"
  }
  assert {
    condition     = google_project_iam_member.this["cloudflared-tunnel-token"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/your-project-id.svc.id.goog/subject/ns/cloudflared/sa/external-secrets"
    error_message = "member principal"
  }
  assert {
    condition = length(google_project_iam_member.this["cloudflared-tunnel-token"].condition) == 1 && (
      one(google_project_iam_member.this["cloudflared-tunnel-token"].condition).title == "eso-cloudflared"
      && one(google_project_iam_member.this["cloudflared-tunnel-token"].condition).expression == "resource.name.startsWith(\"projects/123456789012/secrets/cloudflared-tunnel-token/\")"
    )
    error_message = "condition title and expression, with the trailing slash"
  }
}

run "the_condition_does_not_admit_a_sibling_secret" {
  command = plan

  assert {
    condition = (
      startswith("projects/123456789012/secrets/cloudflared-tunnel-token/versions/1", trimsuffix(trimprefix(one(google_project_iam_member.this["cloudflared-tunnel-token"].condition).expression, "resource.name.startsWith(\""), "\")"))
      && !startswith("projects/123456789012/secrets/cloudflared-tunnel-token-other/versions/1", trimsuffix(trimprefix(one(google_project_iam_member.this["cloudflared-tunnel-token"].condition).expression, "resource.name.startsWith(\""), "\")"))
    )
    error_message = "the prefix matches its own versions and not a sibling secret"
  }
}

run "a_64_character_namespace_is_rejected" {
  command = plan

  variables {
    secrets = { "x" = { namespace = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } }
  }

  expect_failures = [var.secrets]
}

run "region_is_configurable" {
  command = plan

  variables {
    region = "europe-west4"
  }

  assert {
    condition     = one(one(one(google_secret_manager_secret.this["cloudflared-tunnel-token"].replication).user_managed).replicas).location == "europe-west4"
    error_message = "region input"
  }
}

run "a_namespace_must_be_a_dns_label" {
  command = plan

  variables {
    secrets = { "x" = { namespace = "Bad_NS" } }
  }

  expect_failures = [var.secrets]
}
