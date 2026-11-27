# The same custom role gcp-github-wif creates with create_custom_connect_role, created once for a project that
# serves several deploy identities, independent of any of them.
resource "google_project_iam_custom_role" "connect" {
  project     = var.project_id
  role_id     = "gkeDnsConnect"
  title       = "GKE DNS endpoint connect"
  permissions = ["container.clusters.get", "container.clusters.connect"]
  stage       = "GA"
}
