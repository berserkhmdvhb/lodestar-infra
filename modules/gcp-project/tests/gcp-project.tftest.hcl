# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id = "your-project-id"
}

run "every_default_service_is_enabled" {
  command = plan

  assert {
    condition = toset(keys(google_project_service.this)) == toset([
      "compute.googleapis.com",
      "container.googleapis.com",
      "artifactregistry.googleapis.com",
      "iam.googleapis.com",
      "iamcredentials.googleapis.com",
      "sts.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "billingbudgets.googleapis.com",
      "secretmanager.googleapis.com",
    ])
    error_message = "the default services must be exactly the nine from the guide"
  }
}

run "nothing_is_disabled_on_destroy" {
  command = plan

  assert {
    condition     = alltrue([for s in google_project_service.this : s.disable_on_destroy == false && s.disable_dependent_services == false])
    error_message = "disable_on_destroy and disable_dependent_services must be false on every service"
  }
}

run "services_can_be_overridden" {
  command = plan

  variables {
    services = ["compute.googleapis.com"]
  }

  assert {
    condition     = length(google_project_service.this) == 1
    error_message = "one resource per service"
  }
}
