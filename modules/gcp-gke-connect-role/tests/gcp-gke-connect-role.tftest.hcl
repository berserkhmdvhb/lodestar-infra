mock_provider "google" {}

variables {
  project_id = "your-project-id"
}

run "exact_role" {
  command = plan

  assert {
    condition     = google_project_iam_custom_role.connect.role_id == "gkeDnsConnect" && google_project_iam_custom_role.connect.title == "GKE DNS endpoint connect" && google_project_iam_custom_role.connect.stage == "GA"
    error_message = "role id, title and stage"
  }
  assert {
    condition     = toset(google_project_iam_custom_role.connect.permissions) == toset(["container.clusters.get", "container.clusters.connect"])
    error_message = "get and connect only"
  }
}

run "role_name_output" {
  command = plan

  assert {
    condition     = output.role_name == "projects/your-project-id/roles/gkeDnsConnect"
    error_message = "the full role name"
  }
}
