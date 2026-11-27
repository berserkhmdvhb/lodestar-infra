# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id     = "your-project-id"
  project_number = "123456789012"
}

run "five_conditional_bindings_by_default" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.app) == 3 && length(google_project_iam_member.db) == 2
    error_message = "three app bindings and two db bindings"
  }
  assert {
    condition = alltrue([for m in concat(values(google_project_iam_member.app), values(google_project_iam_member.db)) :
      m.role == "roles/secretmanager.secretAccessor" && length(m.condition) == 1
    ])
    error_message = "every binding is secretAccessor and conditional"
  }
}

run "app_binding_member_and_condition_are_exact" {
  command = plan

  assert {
    condition = alltrue([for e in ["dev", "qa", "production"] :
      google_project_iam_member.app[e].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/your-project-id.svc.id.goog/subject/ns/your-service-name-${e}/sa/external-secrets"
      && one(google_project_iam_member.app[e].condition).title == "eso-your-service-name-${e}"
      && one(google_project_iam_member.app[e].condition).expression == "resource.name.startsWith(\"projects/123456789012/secrets/your-service-name-${e}-\")"
      && one(google_project_iam_member.app[e].condition).description == null
      && endswith(one(google_project_iam_member.app[e].condition).expression, "-\")")
    ])
    error_message = "app binding strings"
  }
}

run "db_binding_member_and_condition_are_exact" {
  command = plan

  assert {
    condition = alltrue([for e in ["dev", "qa"] :
      google_project_iam_member.db[e].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/your-project-id.svc.id.goog/subject/ns/your-service-name-${e}-db/sa/external-secrets"
      && one(google_project_iam_member.db[e].condition).title == "eso-your-service-name-${e}-db"
      && one(google_project_iam_member.db[e].condition).expression == "resource.name.startsWith(\"projects/123456789012/secrets/your-service-name-${e}-db-password\")"
      && endswith(one(google_project_iam_member.db[e].condition).expression, "db-password\")")
    ])
    error_message = "db binding strings"
  }
}

run "seven_secrets_user_managed_in_region" {
  command = plan

  assert {
    condition = toset(keys(google_secret_manager_secret.this)) == toset([
      "dev-db-user", "dev-db-password", "dev-stats-pass",
      "qa-db-user", "qa-db-password", "qa-stats-pass",
      "production-stats-pass",
    ])
    error_message = "seven secrets"
  }
  assert {
    condition = alltrue([for k, s in google_secret_manager_secret.this :
      s.secret_id == "your-service-name-${k}"
      && length(one(s.replication).user_managed) == 1
      && one(one(one(s.replication).user_managed).replicas).location == "europe-west1"
      && length(one(s.replication).auto) == 0
      && try(length(s.labels), 0) == 0
      && try(length(s.annotations), 0) == 0
    ])
    error_message = "secret ids and user-managed replication"
  }
  assert {
    condition     = output.secret_ids["qa-db-password"] == "your-service-name-qa-db-password" && length(output.secret_ids) == 7
    error_message = "secret id output"
  }
  assert {
    condition     = length(output.binding_titles) == 5 && contains(output.binding_titles, "eso-your-service-name-qa-db") && contains(output.binding_titles, "eso-your-service-name-production")
    error_message = "binding titles output"
  }
}

run "production_db_secrets_appear_when_added" {
  command = plan

  variables {
    secret_keys = {
      dev        = ["db-user", "db-password", "stats-pass"]
      qa         = ["db-user", "db-password", "stats-pass"]
      production = ["stats-pass", "db-user", "db-password"]
    }
  }

  assert {
    condition     = length(google_secret_manager_secret.this) == 9 && google_secret_manager_secret.this["production-db-password"].secret_id == "your-service-name-production-db-password"
    error_message = "production db secrets"
  }
}

run "project_number_must_be_digits" {
  command = plan

  variables {
    project_number = "abc"
  }

  expect_failures = [var.project_number]
}
