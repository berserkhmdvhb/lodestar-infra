# Mock-provider tests: no credentials, no API calls. The state resources and their values are tested in
# modules/gcp-state-backend; here only what this root owns and how it wires the module.
mock_provider "google" {
  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-0@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id        = "my-project-id"
  state_bucket_name = "my-tofu-state-bucket"
}

run "apis_include_serviceusage" {
  command = plan

  assert {
    condition     = contains(keys(google_project_service.apis), "serviceusage.googleapis.com")
    error_message = "Service Usage must be enabled (envs/apps bills requests to the project)"
  }
  assert {
    condition     = length(google_project_service.apis) == 3
    error_message = "cloudkms, storage and serviceusage"
  }
}

run "bucket_name_reaches_the_module" {
  command = plan

  assert {
    condition     = module.state.state_bucket == "my-tofu-state-bucket"
    error_message = "the bucket name must pass through"
  }
}

run "rotation_default_is_90_days" {
  command = plan

  assert {
    condition     = var.kms_rotation_period == "7776000s" && module.state.kms_key_id != ""
    error_message = "the root passes 7776000s (90 days) to the module by default"
  }
}

run "bad_bucket_name_rejected" {
  command = plan

  variables {
    state_bucket_name = "Bad_Name"
  }

  expect_failures = [var.state_bucket_name]
}
