output "repository_url" {
  description = "Docker host path, or null when disabled."
  value       = var.enabled ? "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_id}" : null
}
