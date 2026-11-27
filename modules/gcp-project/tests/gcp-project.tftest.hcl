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

run "container_audit_logs_are_admin_read_and_data_write_only" {
  command = plan

  assert {
    condition     = google_project_iam_audit_config.container[0].service == "container.googleapis.com"
    error_message = "the audit config is for the container API"
  }
  assert {
    condition     = toset([for c in google_project_iam_audit_config.container[0].audit_log_config : c.log_type]) == toset(["ADMIN_READ", "DATA_WRITE"])
    error_message = "exactly ADMIN_READ and DATA_WRITE; DATA_READ would flood Logging"
  }
  assert {
    condition     = length(google_project_iam_audit_config.container[0].audit_log_config) == 2
    error_message = "two audit_log_config entries"
  }
}

run "container_audit_config_can_be_disabled" {
  command = plan

  variables {
    enable_container_audit_logs = false
  }

  assert {
    condition     = length(google_project_iam_audit_config.container) == 0
    error_message = "nothing when disabled"
  }
}
