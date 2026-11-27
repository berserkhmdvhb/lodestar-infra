# Mock-provider tests: no credentials, no API calls. The state values are tested in modules/gcp-state-backend.
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
    error_message = "Service Usage must be enabled (the production env root bills requests to the project)"
  }
  assert {
    condition     = length(google_project_service.apis) == 4
    error_message = "cloudkms, storage, serviceusage and cloudresourcemanager"
  }
}

run "bucket_name_reaches_the_module" {
  command = plan

  assert {
    condition     = module.state.state_bucket == "my-tofu-state-bucket"
    error_message = "the bucket name must pass through"
  }
}

run "bad_bucket_name_rejected" {
  command = plan

  variables {
    state_bucket_name = "Bad_Name"
  }

  expect_failures = [var.state_bucket_name]
}

# A fresh project: the GCS agent data source has no known member at plan time (no mocked member here).
run "cmek_on_a_fresh_project" {
  command = plan

  variables {
    bucket_cmek_enabled = true
  }

  assert {
    condition     = module.state.state_bucket == "my-tofu-state-bucket"
    error_message = "the plan must succeed with the agent grant deferred"
  }
}
