resource "google_artifact_registry_repository" "this" {
  count = var.enabled ? 1 : 0

  project                = var.project_id
  location               = var.region
  repository_id          = var.repository_id
  format                 = "DOCKER"
  cleanup_policy_dry_run = false

  docker_config {
    immutable_tags = true
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = var.enabled ? toset(var.reader_members) : toset([])

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.this[0].name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
