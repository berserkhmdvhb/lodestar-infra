output "role_name" {
  description = "Full name of the role (projects/<project>/roles/gkeDnsConnect), for gcp-github-wif's deployer_cluster_role."
  value       = "projects/${var.project_id}/roles/${google_project_iam_custom_role.connect.role_id}"
}
