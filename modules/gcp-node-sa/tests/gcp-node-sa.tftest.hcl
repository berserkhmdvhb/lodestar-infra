# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id = "your-project-id"
}

run "default_is_one_default_node_role" {
  command = plan

  assert {
    condition     = google_service_account.nodes.account_id == "gke-nodes" && google_service_account.nodes.display_name == "GKE nodes (apps)"
    error_message = "service account defaults"
  }
  assert {
    condition     = toset([for b in google_project_iam_member.nodes : b.role]) == toset(["roles/container.defaultNodeServiceAccount"]) && length(google_project_iam_member.nodes) == 1
    error_message = "exactly the default node role"
  }
  assert {
    condition     = alltrue([for b in google_project_iam_member.nodes : startswith(b.member, "serviceAccount:")])
    error_message = "members are service accounts"
  }
}

run "classic_roles_when_default_role_off" {
  command = plan

  variables {
    use_default_node_role = false
  }

  assert {
    condition = (
      length(google_project_iam_member.nodes) == 4
      && toset([for b in google_project_iam_member.nodes : b.role]) == toset([
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/monitoring.viewer",
        "roles/stackdriver.resourceMetadata.writer",
      ])
    )
    error_message = "exactly the four classic roles"
  }
}

run "no_privileged_roles_by_default" {
  command = plan

  assert {
    condition = alltrue([for b in google_project_iam_member.nodes :
      b.role != "roles/editor" && b.role != "roles/owner" && !can(regex("^roles/container\\..*[aA]dmin$", b.role))
    ])
    error_message = "no editor, owner or container admin role"
  }
}

run "no_privileged_roles_with_classic_roles" {
  command = plan

  variables {
    use_default_node_role = false
  }

  assert {
    condition = alltrue([for b in google_project_iam_member.nodes :
      b.role != "roles/editor" && b.role != "roles/owner" && !can(regex("^roles/container\\..*[aA]dmin$", b.role))
    ])
    error_message = "no editor, owner or container admin role"
  }
}
