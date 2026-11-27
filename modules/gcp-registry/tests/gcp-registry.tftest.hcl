# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id = "your-project-id"
}

run "disabled_by_default_creates_nothing" {
  command = plan

  variables {
    reader_members = ["serviceAccount:nodes@your-project-id.iam.gserviceaccount.com"]
  }

  assert {
    condition     = length(google_artifact_registry_repository.this) == 0 && length(google_artifact_registry_repository_iam_member.reader) == 0
    error_message = "nothing may be created while enabled = false"
  }
}

run "enabled_has_immutable_tags_and_cleanup" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition = (
      google_artifact_registry_repository.this[0].repository_id == "apps"
      && google_artifact_registry_repository.this[0].format == "DOCKER"
      && google_artifact_registry_repository.this[0].location == "europe-west1"
    )
    error_message = "docker repository apps in the region"
  }
  assert {
    condition     = one(google_artifact_registry_repository.this[0].docker_config).immutable_tags == true
    error_message = "tags must be immutable"
  }
  assert {
    condition     = google_artifact_registry_repository.this[0].cleanup_policy_dry_run == false
    error_message = "cleanup is live, not a dry run"
  }
  assert {
    condition     = length(google_artifact_registry_repository.this[0].cleanup_policies) == 2
    error_message = "two cleanup policies"
  }
  assert {
    condition = anytrue([for p in google_artifact_registry_repository.this[0].cleanup_policies :
      p.action == "DELETE" && one(p.condition).tag_state == "UNTAGGED" && one(p.condition).older_than == "2592000s"
    ])
    error_message = "delete untagged older than 30 days"
  }
  assert {
    condition = anytrue([for p in google_artifact_registry_repository.this[0].cleanup_policies :
      p.action == "KEEP" && one(p.most_recent_versions).keep_count == 10
    ])
    error_message = "keep the 10 most recent versions"
  }
  assert {
    condition     = length(google_artifact_registry_repository_iam_member.reader) == 0
    error_message = "no bindings without reader_members"
  }
}

run "readers_only_get_reader_role" {
  command = plan

  variables {
    enabled        = true
    reader_members = ["serviceAccount:a@your-project-id.iam.gserviceaccount.com", "serviceAccount:b@your-project-id.iam.gserviceaccount.com"]
  }

  assert {
    condition     = length(google_artifact_registry_repository_iam_member.reader) == 2
    error_message = "one binding per reader"
  }
  assert {
    condition     = alltrue([for b in google_artifact_registry_repository_iam_member.reader : b.role == "roles/artifactregistry.reader"])
    error_message = "reader role only; no writer"
  }
}
