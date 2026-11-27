output "services" {
  description = "The enabled APIs."
  value       = sort([for s in google_project_service.this : s.service])
}
